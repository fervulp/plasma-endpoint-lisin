"""Process entities + program classifier for LiSin.

Two separate concerns over the state DB, both read-only + best-effort /proc:

  build(db)    — collapse the raw `processes` table into ENTITIES: one row per
                 running *thing* (a vendor suite like Kaspersky's 6 procs -> 1,
                 a browser's renderer swarm -> 1, kernel threads -> 1). Joins
                 ports / unix_sockets / persistence / config_files / services /
                 applications so an expanded entity shows full EDR context with
                 no second DB round-trip (open files stay lazy — files_for()).

  programs(db) — classify the `applications` (kind='rpm') inventory into
                 programs vs dependencies (scored additive classifier) and roll
                 dependencies up under the program that requires them. Answers
                 "what is installed" — distinct from build()'s "what is running".

Pure stdlib (os, re, sqlite3, subprocess, collections, pathlib, json, hashlib).
Everything returned is plain dict/list/str/int/float so it crosses the Qt slot
boundary untouched.

Grouping algorithm (STEP A–E, see module CLAUDE.md IMPLEMENTATION SPEC):
  A  resolve exe per process (readlink /proc/<pid>/exe, else first cmd token;
     `[...]` command -> kernel thread).
  B  interpreter unwrap (python/bash/node/... -> the script they run).
  C  tiered identity key on the resolved target, strongest first:
       vendor(/opt/<v>/) > product(install-root subdir / flatpak / vscode-ext)
       > package(app path or rpm name) > script(basename) > exe(basename).
  D  weak-subtree absorption: interpreter/helper singletons adopt the key of a
     packaged ancestor; un-absorbed bare interpreters are split per-pid so a
     global python3/bash blob never forms.
  E  group rows by final key, sort (kind rank, -count, title), kernel last.
"""
import hashlib
import json
import os
import re
import sqlite3
import subprocess
from collections import defaultdict, deque
from pathlib import Path

# ---- tier ranks (STEP C) -------------------------------------------------
KERNEL, EXE, SCRIPT, PKG, PRODUCT, VENDOR = -1, 0, 1, 2, 3, 4
_TIER_KIND = {VENDOR: "vendor", PRODUCT: "product", PKG: "package",
              SCRIPT: "script", EXE: "exe", KERNEL: "kernel"}
_KIND_RANK = {"vendor": 0, "product": 1, "package": 2, "script": 3,
              "exe": 4, "kernel": 5}

# interpreters whose real identity is the script they run, not argv0
_INTERP = re.compile(r"^(python[0-9.]*|perl|ruby|node|nodejs|bash|sh|dash|"
                     r"zsh|java|php|Rscript|pwsh|mono|deno|env)$")
_SCRIPT_EXT = (".py", ".sh", ".pl", ".rb", ".js", ".jar", ".mjs")

# product-tier install roots (target under one of these + a subdir)
_PRODUCT_ROOTS = ("/usr/lib/", "/usr/lib64/", "/usr/libexec/", "/usr/share/",
                  "/usr/local/lib/", "/usr/local/libexec/", "/usr/local/share/")

# install dirs too generic to attach persistence/config by prefix
_GENERIC_DIRS = {"", "/", "/usr", "/usr/bin", "/usr/sbin", "/bin", "/sbin",
                 "/usr/lib", "/usr/lib64", "/usr/libexec", "/usr/local",
                 "/usr/local/bin", "/usr/local/sbin", "/usr/share", "/etc",
                 "/opt", "/var", "/var/opt", "/home"}

_PID_RE = re.compile(r"\((\d+)\)\s*$")


# ==========================================================================
# small helpers
# ==========================================================================
def _ro_con(path):
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def _rows(con, table):
    try:
        return [dict(r) for r in con.execute(f'SELECT * FROM "{table}"')]
    except sqlite3.Error:
        return []


def _pidof(process_field):
    """PID parsed from a 'name (pid)' process-column string, or ''."""
    m = _PID_RE.search(process_field or "")
    return m.group(1) if m else ""


def _elapsed_secs(s):
    """Parse ps etime '[[DD-]HH:]MM:SS' to seconds; -1 if unparseable."""
    s = (s or "").strip()
    if not s:
        return -1
    try:
        days = 0
        if "-" in s:
            d, s = s.split("-", 1)
            days = int(d)
        parts = [int(x) for x in s.split(":")]
        while len(parts) < 3:
            parts.insert(0, 0)
        h, m, sec = parts[-3], parts[-2], parts[-1]
        return days * 86400 + h * 3600 + m * 60 + sec
    except (ValueError, IndexError):
        return -1


def _fnum(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def _readlink_exe(pid):
    """os.readlink(/proc/<pid>/exe); '' on EACCES/ESRCH (unprivileged daemon)."""
    try:
        t = os.readlink(f"/proc/{pid}/exe")
        if t.endswith(" (deleted)"):
            t = t[:-len(" (deleted)")]
        return t
    except OSError:
        return ""


def _basename(p):
    return p.rsplit("/", 1)[-1] if "/" in p else p


# ==========================================================================
# STEP A/B — resolve exe + interpreter unwrap
# ==========================================================================
def _resolve_exe(pid, cmd):
    """Return (exe, is_kernel). exe = readlink target, else first cmd token."""
    cmd = (cmd or "").strip()
    if cmd.startswith("["):
        return "", True
    exe = _readlink_exe(pid)
    if not exe:
        tok = cmd.split(None, 1)[0] if cmd else ""
        if tok.startswith("-"):        # login shell "-bash" -> "bash"
            tok = tok[1:]
        exe = tok
    return exe, False


def _unwrap(exe, cmd):
    """STEP B: if exe is an interpreter, target = the script it runs."""
    base = _basename(exe).split(":", 1)[0]
    target = exe
    if _INTERP.match(base):
        toks = (cmd or "").split()
        for t in toks[1:]:
            if t.startswith("-"):
                continue
            if "/" in t or t.endswith(_SCRIPT_EXT):
                target = t
                break
    return target, base


# ==========================================================================
# STEP C — tiered identity key
# ==========================================================================
def _identity(pid, cmd, app_by_path, resolve_name):
    """Return (tier, key_tuple, exe, target) for one process row."""
    exe, is_kernel = _resolve_exe(pid, cmd)
    if is_kernel:
        return KERNEL, ("kernel", "[kernel]"), "", ""
    target, base = _unwrap(exe, cmd)
    tbase = _basename(target).split(":", 1)[0]

    # t4 VENDOR — /opt/<v>/ anywhere in the path (incl. /var/opt, embedded)
    m = re.search(r"/opt/([^/]+)/", target)
    if m:
        return VENDOR, ("vendor", "/opt/" + m.group(1)), exe, target

    # t3 PRODUCT — install-root + first subdir, flatpak app, vscode extension
    m = re.search(r"/\.vscode/extensions/([^/]+)/", target)
    if m:
        return PRODUCT, ("root", "vscode-ext:" + m.group(1)), exe, target
    m = re.search(r"/(?:var/lib|\.local/share)/flatpak/app/([^/]+)/", target)
    if m:
        return PRODUCT, ("flatpak", m.group(1)), exe, target
    m = re.search(r"(/home/[^/]+/\.local/(?:share|opt)/[^/]+)/", target)
    if m:
        return PRODUCT, ("root", m.group(1)), exe, target
    for root in _PRODUCT_ROOTS:
        if target.startswith(root):
            rest = target[len(root):]
            if len(rest.split("/")) >= 2 and rest.split("/")[0]:
                return PRODUCT, ("root", root + rest.split("/")[0]), exe, target

    # t2 PACKAGE — exe path owned by an app, else rpm name by basename
    if target and target in app_by_path:
        return PKG, ("pkg", app_by_path[target]), exe, target
    if not _INTERP.match(tbase):
        nm = resolve_name(tbase)
        if nm:
            return PKG, ("pkg", nm), exe, target

    # t1 SCRIPT — interpreter carried a script but nothing above matched
    if target != exe:
        return SCRIPT, ("script", _basename(target)), exe, target

    # t0 EXE fallback
    return EXE, ("exe", base), exe, target


def _make_resolve_name(name_set):
    """exe basename -> nearest applications.name (prefix-tolerant, |dlen|<=4)."""
    names = sorted(name_set)

    def resolve(base):
        if not base:
            return ""
        if base in name_set:
            return base
        best, best_d = "", 99
        for n in names:
            if n.startswith(base) or base.startswith(n):
                d = abs(len(n) - len(base))
                if d <= 4 and (d < best_d or (d == best_d and n < best)):
                    best, best_d = n, d
        return best
    return resolve


# ==========================================================================
# build() — process entities
# ==========================================================================
def build(db):
    """Collapse the processes table into entities with full cross-table context.

    db is an agent.statedb.StateDB. Reads the state DB via a fresh read-only
    connection (NOT db.query — its 500-row cap would drop rpm/pip/process rows).
    Returns a list of entity dicts sorted (kind rank, -count, title); open_files
    is left [] (filled lazily by files_for()).
    """
    con = _ro_con(db.path)
    try:
        procs = _rows(con, "processes")
        apps = _rows(con, "applications")
        ports = _rows(con, "ports")
        unix = _rows(con, "unix_sockets")
        persistence = _rows(con, "persistence")
        configs = _rows(con, "config_files")
        services = _rows(con, "services")
    finally:
        con.close()

    by_pid = {str(r.get("pid", "")): r for r in procs}
    app_by_path = {r["path"]: r["name"] for r in apps
                   if r.get("path") and r.get("name")}
    name_set = {r["name"] for r in apps if r.get("name")}
    apps_by_name = defaultdict(list)
    for r in apps:
        if r.get("name"):
            apps_by_name[r["name"]].append(r)
    resolve_name = _make_resolve_name(name_set)

    # per-pid identity (STEP A–C), kept as the ORIGINAL identity for absorption
    ident = {}          # pid -> (tier, key_tuple, exe, target)
    for r in procs:
        pid = str(r.get("pid", ""))
        ident[pid] = _identity(pid, r.get("command", ""),
                               app_by_path, resolve_name)

    # STEP D — weak-subtree absorption
    final_key = {}      # pid -> key_tuple
    final_tier = {}     # pid -> tier (of the adopted identity)
    for r in procs:
        pid = str(r.get("pid", ""))
        tier, key, exe, target = ident[pid]
        if tier == KERNEL or tier > SCRIPT:
            final_key[pid] = key
            final_tier[pid] = tier
            continue
        adopted = None
        cur, seen = str(r.get("ppid", "")), set()
        for _ in range(40):
            if not cur or cur in ("0", "1") or cur in seen:
                break
            seen.add(cur)
            anc = ident.get(cur)
            if anc and anc[0] >= PKG:
                adopted = (anc[0], anc[1])
                break
            par = by_pid.get(cur)
            cur = str(par.get("ppid", "")) if par else ""
        if adopted:
            final_tier[pid], final_key[pid] = adopted
        elif key[0] == "exe" and _INTERP.match(key[1]):
            # un-absorbed bare interpreter -> unique, never a global blob
            final_key[pid] = ("exe", key[1] + "#" + pid)
            final_tier[pid] = EXE
        else:
            final_key[pid] = key
            final_tier[pid] = tier

    # STEP E — group rows by final key
    groups = defaultdict(list)          # key_tuple -> [proc rows]
    for r in procs:
        groups[final_key[str(r.get("pid", ""))]].append(r)

    # pre-index cross-table rows by pid for O(1) joins
    ports_by_pid = defaultdict(list)
    for r in ports:
        pid = _pidof(r.get("process", ""))
        if pid:
            ports_by_pid[pid].append(r)
    unix_by_pid = defaultdict(list)
    for r in unix:
        pid = _pidof(r.get("process", ""))
        if pid:
            unix_by_pid[pid].append(r)

    entities = []
    for key, members in groups.items():
        tag, value = key[0], key[1]
        tier = max(final_tier[str(m.get("pid", ""))] for m in members)
        kind = _TIER_KIND[tier]
        pidset = {str(m.get("pid", "")) for m in members}

        # representative program path = target of the highest-tier member
        rep = max(members, key=lambda m: ident[str(m.get("pid", ""))][0])
        rep_target = ident[str(rep.get("pid", ""))][3] or \
            ident[str(rep.get("pid", ""))][2]

        # package identity across members (path first, then rpm name)
        pkg_names, install_dirs = [], set()
        for m in members:
            _, _, mexe, mtarget = ident[str(m.get("pid", ""))]
            t = mtarget or mexe
            nm = app_by_path.get(t) or resolve_name(
                _basename(t).split(":", 1)[0])
            if nm and nm not in pkg_names:
                pkg_names.append(nm)
            d = t.rsplit("/", 1)[0] if "/" in t else ""
            if d and d not in _GENERIC_DIRS:
                install_dirs.add(d)
        pkg_names.sort()

        deps = set()
        for nm in pkg_names:
            for row in apps_by_name.get(nm, []):
                for tok in (row.get("depends") or "").split():
                    deps.add(tok)

        # ports / connections / unix
        e_ports, e_conn, e_unix = [], [], []
        for pid in pidset:
            for p in ports_by_pid.get(pid, []):
                e_ports.append({"proto": p.get("proto", ""),
                                "local": p.get("local", ""),
                                "remote": p.get("remote", ""),
                                "state": p.get("state", ""),
                                "exposure": p.get("exposure", "")})
                if p.get("remote"):
                    e_conn.append({"proto": p.get("proto", ""),
                                   "local": p.get("local", ""),
                                   "remote": p.get("remote", ""),
                                   "exposure": p.get("exposure", "")})
            for u in unix_by_pid.get(pid, []):
                e_unix.append({"path": u.get("path", ""),
                               "type": u.get("type", ""),
                               "state": u.get("state", "")})

        exposure = _worst_exposure(p["exposure"] for p in e_ports)

        # persistence / config / services by install-dir prefix + vendor token
        token = value.rsplit("/", 1)[-1] if kind in ("vendor", "product") else ""
        token = token if len(token) >= 4 else ""
        e_pers = []
        for pr in persistence:
            hay = (pr.get("path", "") or "") + " " + (pr.get("detail", "") or "")
            if _under(hay, install_dirs) or (token and token in hay):
                e_pers.append({"vector": pr.get("vector", ""),
                               "path": pr.get("path", ""),
                               "detail": pr.get("detail", "")})
        roots = set(install_dirs)
        if tag == "vendor":
            v = value[len("/opt/"):]
            roots |= {"/opt/" + v, "/var/opt/" + v, "/etc/opt/" + v}
        elif tag == "root" and value.startswith("/"):
            roots.add(value)
        e_conf = []
        for cf in configs:
            path = cf.get("path", "") or ""
            if any(path.startswith(r) for r in roots):
                e_conf.append({"path": path, "category": cf.get("category", "")})

        # oldest member (started_first) via etime
        first_s, first_secs = "", -1
        for m in members:
            s = _elapsed_secs(m.get("elapsed", ""))
            if s > first_secs:
                first_secs, first_s = s, (m.get("elapsed", "") or "")

        entry_points = [{"pid": str(m.get("pid", "")),
                         "ppid": str(m.get("ppid", "")),
                         "command": (m.get("command", "") or "")[:160]}
                        for m in members
                        if str(m.get("ppid", "")) not in pidset]

        users = sorted({m.get("user", "") for m in members if m.get("user")})
        flags = []
        if "root" in users:
            flags.append("root")
        if exposure == "OPEN":
            flags.append("OPEN")
        if not pkg_names:
            flags.append("unpackaged")

        title = value.rsplit("/", 1)[-1] if "/" in value else (
            value.rsplit(":", 1)[-1] if ":" in value else value)

        entities.append({
            "key": f"{tag}:{value}",
            "title": title,
            "kind": kind,
            "count": len(members),
            "pids": sorted(pidset, key=lambda x: int(x) if x.isdigit() else 0),
            "users": users,
            "rss_mb_total": round(sum(_fnum(m.get("rss_mb")) for m in members), 1),
            "cpu_total": round(sum(_fnum(m.get("cpu")) for m in members), 1),
            "exe": rep_target,
            "package": ", ".join(pkg_names),
            "deps_count": len(deps),
            "ports": e_ports,
            "connections": e_conn,
            "unix": e_unix,
            "open_files": [],
            "persistence": e_pers,
            "config": e_conf,
            "started_first": first_s,
            "exposure": exposure,
            "entry_points": entry_points,
            "flags": flags,
        })

    entities.sort(key=lambda e: (_KIND_RANK.get(e["kind"], 9),
                                 -e["count"], e["title"].lower()))
    return entities


def _worst_exposure(values):
    rank = {"OPEN": 3, "filtered": 2, "local-only": 1}
    best, name = 0, ""
    for v in values:
        v = v or ""
        if "OPEN" in v:
            r, n = 3, "OPEN"
        elif "filtered" in v:
            r, n = 2, "filtered"
        elif "local-only" in v:
            r, n = 1, "local-only"
        else:
            continue
        if r > best:
            best, name = r, n
    return name


def _under(hay, dirs):
    return any(d in hay for d in dirs)


def files_for(pids, cap=25):
    """LAZY open-files aggregation for an expanded entity.

    readlink each /proc/<pid>/fd/* for pids; keep real-file targets ('/'-
    rooted, not /proc/* or pipes/sockets), dedup+sort, truncate to cap.
    Best-effort — silently skips EACCES/ESRCH.
    """
    out = set()
    for pid in pids:
        d = f"/proc/{pid}/fd"
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            try:
                t = os.readlink(f"{d}/{n}")
            except OSError:
                continue
            if not t.startswith("/"):
                continue
            # skip anon/pseudo fds: /dmabuf:, /memfd:..., /[eventpoll], etc.
            if t.startswith("/proc/") or t.startswith("/dev/") or \
                    t.startswith("/sys/") or t.startswith("/[") or \
                    ":" in t or "(deleted)" in t:
                continue
            out.add(t)
    return sorted(out)[:cap]


# ==========================================================================
# programs() — installed programs vs dependencies
# ==========================================================================
_PROGCACHE = Path.home() / ".local/share/lisin/progclass.json"
_RPMDB = "/usr/lib/sysimage/rpm/rpmdb.sqlite"

# noise classes: names that are almost never a "program" a user cares about
_NOISE_PREFIX = re.compile(r"^(lib|glibc|gcc)")
_NOISE_SUFFIX = re.compile(
    r"-(libs?|devel|static|headers|doc|javadoc|debuginfo|debugsource|"
    r"fonts?|data|common|filesystem|langpack.*|selinux|icon-theme)$")
_NOISE_ECO = re.compile(r"^(python3?|perl|ruby|rust|golang|php|nodejs|texlive)-")
# core tools that reach the program threshold via B+R but are plumbing
_CORE_DENY = {"filesystem", "setup", "glibc", "bash", "coreutils", "systemd",
              "systemd-libs", "systemd-udev", "dbus", "dbus-broker", "util-linux",
              "shadow-utils", "rpm", "dnf", "sudo", "pam", "grep", "sed", "gawk",
              "findutils", "which", "kernel", "kernel-core", "glibc-common"}


def _is_noise(name):
    return bool(_NOISE_PREFIX.match(name) or _NOISE_SUFFIX.search(name)
                or _NOISE_ECO.match(name))


def _run(cmd, timeout=60):
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout).stdout
    except Exception:
        return ""


def _strip_ver(line):
    """A repoquery line 'name-1.2-3.fc.x86_64' -> 'name' (best effort)."""
    s = line.strip()
    if not s:
        return ""
    # drop arch, then two trailing -<...> version-release segments
    s = re.sub(r"\.(x86_64|noarch|i686|aarch64)$", "", s)
    s = re.sub(r"-[^-]*-[^-]*$", "", s)
    return s


def _rpmdb_mtime():
    try:
        return str(os.path.getmtime(_RPMDB))
    except OSError:
        return "0"


def _compute_signals():
    """User-installed (U), leaf (L), ships-PATH-bin (B), ships-desktop (D).

    U/L via dnf repoquery (local rpmdb queries); B/D via ONE rpm -qa pass over
    all filenames. Cached to progclass.json keyed by rpmdb mtime.
    """
    key = _rpmdb_mtime()
    try:
        cached = json.loads(_PROGCACHE.read_text())
        if cached.get("_rpmdb") == key:
            return (set(cached["U"]), set(cached["L"]),
                    set(cached["B"]), set(cached["D"]))
    except Exception:
        pass

    U = {_strip_ver(x) for x in
         _run(["dnf", "repoquery", "--userinstalled", "-q"]).splitlines()}
    U = {x for x in U if x}
    if not U:
        U = {_strip_ver(x) for x in
             _run(["dnf", "history", "userinstalled"]).splitlines() if x}
        U = {x for x in U if x}
    L = {_strip_ver(x) for x in
         _run(["dnf", "repoquery", "--leaves", "-q"]).splitlines()}
    L = {x for x in L if x}

    B, D = set(), set()
    out = _run(["rpm", "-qa", "--qf", "@@%{NAME}\n[%{FILENAMES}\n]"])
    cur = None
    for line in out.splitlines():
        if line.startswith("@@"):
            cur = line[2:]
            continue
        if not cur:
            continue
        if re.match(r"^/(usr/)?s?bin/", line):
            B.add(cur)
        elif re.match(r"^/usr/share/applications/.*\.desktop$", line):
            D.add(cur)

    try:
        _PROGCACHE.parent.mkdir(parents=True, exist_ok=True)
        _PROGCACHE.write_text(json.dumps(
            {"_rpmdb": key, "U": sorted(U), "L": sorted(L),
             "B": sorted(B), "D": sorted(D)}))
    except OSError:
        pass
    return U, L, B, D


def _running_names(con, name_set):
    """rpm names currently running (R) — cheap basename match, no rpm -qf."""
    R = set()
    for r in _rows(con, "processes"):
        cmd = (r.get("command", "") or "").strip()
        if not cmd or cmd.startswith("["):
            continue
        tok = cmd.split(None, 1)[0]
        base = _basename(tok).split(":", 1)[0]
        if base in name_set:
            R.add(base)
    return R


# INVENTORY CACHE. programs() walks the dependencies of all 3.5 thousand
# applications (~85 ms) and used to be called EVERY 2 seconds from the dashboard -
# that was the main contributor to the stutter. The inventory changes only when a
# package is installed or removed, so the cache key is a cheap signature of the
# applications table (row count + the maximum rowid). It is recomputed exactly
_PROG_CACHE = {"sig": None, "val": None}


def _apps_sig(db):
    try:
        con = _ro(db.path) if "_ro" in globals() else None
    except Exception:
        con = None
    import sqlite3
    try:
        c = sqlite3.connect("file:%s?mode=ro" % db.path, uri=True)
        r = c.execute("SELECT COUNT(*), COALESCE(MAX(_id),0) FROM applications").fetchone()
        c.close()
        return tuple(r)
    except Exception:
        return None


def programs(db):
    """Classifies the WHOLE applications inventory into PROGRAMS and DEPENDENCIES.

    It covers every kind: rpm, flatpak (+flatpak-runtime), bin, appimage,
    process-bin and the language ecosystems (pip/npm/cargo/gem/go). The links are
    built across ALL kinds at once - every one of them has a depends column (rpm
    REQUIRENAME, flatpak runtime+extensions, bin ldd, pip/npm dependencies).

    rpm uses additive scoring (userinstalled/desktop/path-bin/leaf/running).
    The other kinds use a general rule: a package is a DEPENDENCY if something
    else requires it, otherwise it is a PROGRAM. A flatpak-runtime is always a
    dependency (it is the platform under an application, not an application).
    """
    sig = _apps_sig(db)
    if sig is not None and _PROG_CACHE["sig"] == sig and _PROG_CACHE["val"] is not None:
        return _PROG_CACHE["val"]

    con = _ro_con(db.path)
    try:
        apps = [r for r in _rows(con, "applications") if r.get("name")]
        rpms = [r for r in apps if r.get("kind") == "rpm"]
        others = [r for r in apps if r.get("kind") != "rpm"]
        name_set = {r["name"] for r in rpms}
        U, L, B, D = _compute_signals()
        R = _running_names(con, name_set | {r["name"] for r in others})
    finally:
        con.close()

    recs = {}           # (kind, name) -> the record

    # --- rpm: additive scoring (as before) ---
    for r in rpms:
        name = r["name"]
        if ("rpm", name) in recs:
            continue
        fired = []
        if name in U:
            fired.append("user")
        if name in D:
            fired.append("desktop")
        if name in B:
            fired.append("path-bin")
        if name in L:
            fired.append("leaf")
        if name in R:
            fired.append("running")
        noise = _is_noise(name)
        score = (2 * (name in U) + 2 * (name in D) + 1 * (name in B)
                 + 1 * (name in L) + 1 * (name in R)
                 - 2 * (noise and name not in D))
        role = "program" if score >= 4 else "dependency"
        if name in _CORE_DENY:
            role = "dependency"
        recs[("rpm", name)] = {
            "name": name,
            "kind": "rpm",
            "version": r.get("version", "") or "",
            "role": role,
            "gui": name in D,
            "running": name in R,
            "reasons": ",".join(fired),
            "score": int(score),
            "components": 0,
            "program": "",
            "depends": r.get("depends", "") or "",
            "path": r.get("path", "") or "",
            "app_id": r.get("app_id", "") or "",
        }

    # --- the other kinds ---
    DEP_KINDS = {"flatpak-runtime"}
    GUI_KINDS = {"flatpak", "appimage"}
    for r in others:
        kind = r.get("kind") or "other"
        name = r["name"]
        if (kind, name) in recs:
            continue
        recs[(kind, name)] = {
            "name": name,
            "kind": kind,
            "version": r.get("version", "") or "",
            "role": "dependency" if kind in DEP_KINDS else "program",
            "gui": kind in GUI_KINDS,
            "running": name in R,
            "reasons": kind,
            "score": 0,
            "components": 0,
            "program": "",
            "depends": r.get("depends", "") or "",
            "path": r.get("path", "") or "",
            "app_id": r.get("app_id", "") or "",
        }

    # an index by NAME + ALIASES. Different ecosystems refer to things
    # differently: rpm by the package name, while a flatpak lists APP_IDs in
    # depends ('org.freedesktop.Platform.GL.default'), whereas the runtime row is
    # named for humans ('Mesa'). So we resolve both the name and the app_id.
    by_name = {}
    for rec in recs.values():
        by_name.setdefault(rec["name"], rec)
    alias = {}
    for rec in recs.values():
        alias.setdefault(rec["name"], rec["name"])
        if rec.get("app_id"):
            alias.setdefault(rec["app_id"], rec["name"])

    def dep_tokens(rec):
        # flatpak returns a comma separated list with a /arch/branch suffix
        raw = (rec.get("depends") or "").replace(",", " ")
        for tok in raw.split():
            # capability tokens rtld(GNU_HASH)/perl(x) - skipped
            if "(" in tok or ")" in tok:
                continue
            tok = tok.strip()
            if not tok:
                continue
            t = alias.get(tok)
            if t:
                yield t
            elif "/" in tok:
                t = alias.get(tok.split("/", 1)[0])
                if t:
                    yield t

    # something requires it -> it is a dependency (for the non-rpm kinds)
    required_by = defaultdict(set)
    for rec in recs.values():
        for tok in dep_tokens(rec):
            if tok != rec["name"]:
                required_by[tok].add(rec["name"])
    for rec in recs.values():
        if rec["kind"] == "rpm" or rec["kind"] in DEP_KINDS:
            continue
        if required_by.get(rec["name"]):
            rec["role"] = "dependency"

    # Language ecosystems: pip/npm/... usually have NO depends in the inventory,
    # so "nobody requires them" and everything would look like a program (176 pip
    # rows -> 159 "programs" - which is untrue: the vast majority are libraries).
    # We count something as a program only if it really runs: it is running or it
    # installs an executable of the same name (which lands in the inventory as bin).
    LANG_KINDS = {"pip", "pipx", "npm", "cargo", "gem", "go"}
    exe_names = {rec["name"] for rec in recs.values()
                 if rec["kind"] in ("bin", "appimage", "process-bin")}
    for rec in recs.values():
        if rec["kind"] in LANG_KINDS and rec["role"] == "program":
            if not (rec["running"] or rec["name"] in exe_names):
                rec["role"] = "dependency"
                rec["reasons"] = rec["kind"] + ",library"

    # --- rollup: attach every dependency to its program ---
    scored = by_name
    programs_set = {n for n, d in by_name.items() if d["role"] == "program"}
    requires = defaultdict(set)
    for name, d in by_name.items():
        for tok in dep_tokens(d):
            if tok in by_name and tok != name:
                requires[name].add(tok)

    # multi-source BFS from all programs; nearest program owns a dep, ties ->
    # alphabetically-first program (process queue in sorted order per level).
    owner, dist = {}, {}
    frontier = sorted(programs_set)
    for p in frontier:
        owner[p], dist[p] = p, 0
    d = 0
    while frontier:
        nxt = []
        for cur in sorted(frontier):
            for dep in requires.get(cur, ()):
                nd = d + 1
                if dep not in dist or nd < dist[dep] or \
                        (nd == dist[dep] and owner[cur] < owner.get(dep, "￿")):
                    if dep not in dist or nd <= dist[dep]:
                        dist[dep] = nd
                        owner[dep] = owner[cur]
                        nxt.append(dep)
        frontier = nxt
        d += 1
        if d > 64:
            break

    comp = defaultdict(int)
    for name, meta in by_name.items():
        if meta["role"] == "dependency":
            own = owner.get(name, "")
            meta["program"] = own
            if own:
                comp[own] += 1
    for p, c in comp.items():
        if p in by_name:
            by_name[p]["components"] = c

    # IMPORTANT: the counters are NOT carried over to same-named records of another
    # kind - rpm is inserted first and always takes the head position in by_name,
    # so pip:fedpkg does not inherit 83 dependencies from rpm:fedpkg (different packages).

    out = list(recs.values())
    out.sort(key=lambda x: (0 if x["role"] == "program" else 1,
                            -x["score"], x["name"].lower()))
    _PROG_CACHE["sig"] = sig
    _PROG_CACHE["val"] = out
    return out

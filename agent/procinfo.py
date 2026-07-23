"""EDR overview of one process: origin, network, package + dependencies, files."""
import subprocess


def _run(cmd) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=10).stdout.strip()
    except Exception:
        return ""


def _proc_line(pid: str) -> dict:
    """One process through ps: pid/ppid/user/started/command (or {} if absent)."""
    st = _run(["ps", "-o", "pid=,ppid=,user=,lstart=,args=", "-p", pid])
    if not st:
        return {}
    f = st.split(None, 3)
    if len(f) < 4:
        return {}
    rest = f[3].split(None, 5)
    return {"pid": f[0], "ppid": f[1], "user": f[2],
            "started": " ".join(rest[:5]),
            "command": (rest[5] if len(rest) > 5 else "")[:120]}


def _ancestry(pid: str) -> list:
    """The launch chain: from init (1) DOWN to the process itself - the "how it
    started" timeline. We walk up by ppid, then reverse."""
    chain, seen, cur = [], set(), pid
    for _ in range(24):
        if not cur or cur in seen or cur == "0":
            break
        seen.add(cur)
        p = _proc_line(cur)
        if not p:
            break
        chain.append(p)
        cur = p["ppid"]
    chain.reverse()      # init -> ... -> the process
    return chain


def _unit(pid: str) -> str:
    """The systemd unit/scope that started the process (from /proc/PID/cgroup)."""
    cg = _run(["cat", f"/proc/{pid}/cgroup"])
    if not cg:
        return ""
    segs = [s for s in cg.strip().replace("\n", "/").split("/") if s]
    for suf in (".service", ".scope"):
        for s in reversed(segs):
            if s.endswith(suf):
                return s
    for s in reversed(segs):
        if s.endswith(".slice"):
            return s
    return ""


def details(pid: str, proc_rows: list) -> dict:
    out = {"pid": pid, "alive": False}
    ps = _run(["ps", "-o", "pid=,ppid=,user=,lstart=,pcpu=,pmem=,args=",
               "-p", pid])
    if ps:
        f = ps.split(None, 3)
        out["alive"] = True
        out["ppid"] = f[1]
        out["user"] = f[2]
        rest = f[3].split(None, 5)
        out["started"] = " ".join(rest[:5])
        tail = rest[5].split(None, 2) if len(rest) > 5 else []
        out["cpu"] = tail[0] if tail else ""
        out["mem"] = tail[1] if len(tail) > 1 else ""
        out["command"] = tail[2] if len(tail) > 2 else ""
    exe = _run(["readlink", "-f", f"/proc/{pid}/exe"])
    out["exe"] = exe
    out["cwd"] = _run(["readlink", "-f", f"/proc/{pid}/cwd"])

    pkg = _run(["rpm", "-qf", exe]) if exe else ""
    out["package"] = "" if (not pkg or "not owned" in pkg
                            or "owner" in pkg) else pkg
    if out["package"]:
        deps = _run(["rpm", "-qR", out["package"].rsplit("-", 2)[0]])
        out["deps"] = sorted({d.split()[0] for d in deps.splitlines()
                              if d and not d.startswith("rpmlib")})[:20]
    else:
        out["deps"] = []

    ss = _run(["ss", "-tunap"])
    net = []
    for ln in ss.splitlines():
        if f"pid={pid}," in ln:
            f = ln.split()
            if len(f) >= 6:
                net.append({"proto": f[0], "state": f[1],
                            "local": f[4], "peer": f[5]})
    out["sockets"] = net[:30]

    out["children"] = [{"pid": r["pid"], "command": r["command"][:80]}
                       for r in proc_rows if r.get("ppid") == pid][:15]
    par = next((r for r in proc_rows if r.get("pid") == out.get("ppid")), None)
    out["parent"] = ({"pid": par["pid"], "command": par["command"][:80]}
                     if par else None)

    fds = _run(["bash", "-c",
                f"ls -l /proc/{pid}/fd 2>/dev/null | awk '{{print $NF}}' "
                f"| grep -v '^/proc' | sort -u | head -15"])
    out["files"] = [x for x in fds.splitlines() if x.startswith("/")]

    # --- launch context (the timeline is pinned at the top of the tab) ---
    out["lineage"] = _ancestry(pid)              # init -> ... -> the process
    out["unit"] = _unit(pid)                     # which systemd unit started it
    # environment flags of the live process (LD_PRELOAD etc. = a persistence signal)
    env = _run(["bash", "-c",
                f"tr '\\0' '\\n' < /proc/{pid}/environ 2>/dev/null | "
                f"grep -E '^(LD_PRELOAD|LD_LIBRARY_PATH|PROMPT_COMMAND)='"])
    out["env_flags"] = [x for x in env.splitlines() if x][:5]
    # listening/established unix sockets of the process (IPC)
    xs = _run(["ss", "-xap"])
    ux = []
    for ln in xs.splitlines():
        if f"pid={pid}," in ln:
            g = ln.split()
            if len(g) >= 5 and (g[4].startswith("/") or g[4].startswith("@")):
                ux.append(g[4])
    out["unix"] = sorted(set(ux))[:15]
    return out

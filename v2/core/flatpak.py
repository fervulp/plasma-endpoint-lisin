"""What a flatpak application IS, and what it is ALLOWED to do.

Three things are read, and keeping them apart is the whole point:

  REQUESTED  — what the application asked for when it was built (its metadata).
               The author decided this; it is not negotiable from outside, only
               overridable.
  OVERRIDE   — what this machine has said about it since, in
               ~/.local/share/flatpak/overrides/<id>. Plain INI, written with
               `flatpak override --user`, no root anywhere.
  EFFECTIVE  — what the sandbox will actually get: requested, with the override
               applied on top. This is the only one that answers "can it reach
               my files", and it is the one an operator has never been shown.

MEASURED ON THIS MACHINE, not assumed (flatpak 1.18):
  * `flatpak override --user` needs no root and writes that INI;
  * a denial is a `!` prefix — `shared=!network;`;
  * denying a directory INSIDE an allowed one works: with
    `filesystems=/tmp/x;!/tmp/x/secret` the secret directory does not exist from
    inside the sandbox at all. That is what makes a path tree with per-node
    denials possible rather than decorative;
  * an override takes effect on the NEXT launch, never on a running instance.

THE ONE PERMISSION THAT VOIDS THE REST: talking to org.freedesktop.Flatpak lets
an application run anything on the host, outside the sandbox entirely. Any
listing that shows it as one line item among forty is lying by arrangement, so it
is reported on its own.
"""
from __future__ import annotations

import configparser
import os
import shutil
import subprocess
from pathlib import Path

# The permission families flatpak actually has, in the order an operator asks
# about them: what it can reach, then what it can talk to, then what it can be.
# The names on the right are flatpak's own — nothing here is invented, and a
# family that flatpak does not have cannot be shown as if it did.
# key, title, why, icon. The icon is part of the description, not decoration:
# a family is recognised by its picture before its name is read — and every one
# of these was checked to exist in the icon theme, because a missing icon leaves
# a blank square that reads as a broken page.
CATEGORIES = [
    ("filesystems", "Files", "Paths the application can see. Everything else "
                             "does not exist from inside the sandbox.", "folder"),
    ("shared", "Network and IPC", "Whether it can reach the network at all, and "
                                  "whether it shares the host's IPC namespace.",
     "network-connect"),
    ("sockets", "Sockets", "The desktop's own channels: the display server, "
                           "sound, the buses, the ssh and gpg agents, printing.",
     "preferences-desktop-display"),
    ("devices", "Devices", "Hardware nodes: the GPU, virtualisation, shared "
                           "memory, or everything under /dev.",
     "drive-removable-media"),
    ("features", "Features", "Development tools, other architectures, "
                             "bluetooth, the vehicle bus.",
     "applications-development"),
    ("session bus", "Session bus", "Which services on your own bus it may talk "
                                   "to or own. This is where sandbox escape lives.",
     "preferences-system-network"),
    ("system bus", "System bus", "The same for the system bus, where the "
                                 "machine's own services are.", "system-run"),
]

# Sections of the override file, mapped to the category they belong to.
_SECTIONS = {
    "Context": ("filesystems", "shared", "sockets", "devices", "features"),
    "Session Bus Policy": ("session bus",),
    "System Bus Policy": ("system bus",),
}

ESCAPE_NAME = "org.freedesktop.Flatpak"


def available() -> bool:
    return shutil.which("flatpak") is not None


def _run(argv: list[str], timeout: int = 30) -> str:
    try:
        return subprocess.run(argv, capture_output=True, text=True,
                              timeout=timeout).stdout
    except Exception:  # noqa: BLE001 — a missing tool is an empty answer here
        return ""


def overrides_dir() -> Path:
    return Path(os.path.expanduser("~/.local/share/flatpak/overrides"))


# --------------------------------------------------------------- applications
def applications() -> list[dict]:
    """Installed applications, with what they cost on disk and what they run on."""
    if not available():
        return []
    out = []
    raw = _run(["flatpak", "list", "--app", "--columns=application,name,version,"
                "branch,origin,size,installation"], 60)
    for line in raw.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        app = {"id": parts[0], "name": parts[1],
               "version": parts[2] if len(parts) > 2 else "",
               "branch": parts[3] if len(parts) > 3 else "",
               "origin": parts[4] if len(parts) > 4 else "",
               "size": parts[5] if len(parts) > 5 else "",
               "installation": parts[6] if len(parts) > 6 else ""}
        out.append(app)
    return out


def runtimes() -> list[dict]:
    """The runtimes and extensions applications are built on. They are the bulk
    of what "an application weighs": a 40 MB program on a 2 GB platform."""
    out = []
    raw = _run(["flatpak", "list", "--runtime",
                "--columns=application,name,version,branch,size"], 60)
    for line in raw.splitlines():
        p = line.split("\t")
        if len(p) < 2:
            continue
        out.append({"id": p[0], "name": p[1], "version": p[2] if len(p) > 2 else "",
                    "branch": p[3] if len(p) > 3 else "",
                    "size": p[4] if len(p) > 4 else ""})
    return out


def dependencies(app_id: str) -> list[str]:
    """What this application runs ON: its runtime, its sdk if recorded, and the
    extensions the runtime pulls in. Read from the application's own metadata —
    not guessed from names."""
    meta = _run(["flatpak", "info", "--show-metadata", app_id], 30)
    deps = []
    cp = configparser.ConfigParser(strict=False, allow_no_value=True)
    try:
        cp.read_string(meta)
    except Exception:  # noqa: BLE001 — a metadata file we cannot parse is empty
        return deps
    if cp.has_section("Application"):
        for key in ("runtime", "sdk"):
            v = cp["Application"].get(key, "")
            if v:
                deps.append(v)
    for sect in cp.sections():
        if sect.startswith("Extension "):
            deps.append(sect.split(" ", 1)[1])
    return deps


# ------------------------------------------------------------- permissions
def _parse_context(text: str) -> dict:
    """A [Context]-shaped block into {category: [entries]}. Both the metadata and
    the override file use it, which is why one parser serves both."""
    out: dict[str, list[str]] = {c[0]: [] for c in CATEGORIES}
    cp = configparser.ConfigParser(strict=False, allow_no_value=True)
    try:
        cp.read_string(text)
    except Exception:  # noqa: BLE001
        return out
    if cp.has_section("Context"):
        for key in ("filesystems", "shared", "sockets", "devices", "features"):
            v = cp["Context"].get(key, "")
            out[key] = [x for x in v.split(";") if x]
    for section, cat in (("Session Bus Policy", "session bus"),
                         ("System Bus Policy", "system bus")):
        if cp.has_section(section):
            out[cat] = [f"{k}={v}" for k, v in cp[section].items()]
    return out


def requested(app_id: str) -> dict:
    """What the application asked for when it was built."""
    return _parse_context(_run(["flatpak", "info", "--show-permissions", app_id], 30))


def override(app_id: str) -> dict:
    """What this machine has said since. Empty when nothing was ever overridden —
    which is a different thing from "everything is denied"."""
    f = overrides_dir() / app_id
    try:
        return _parse_context(f.read_text())
    except OSError:
        return {c[0]: [] for c in CATEGORIES}


def effective(app_id: str) -> dict:
    """What the sandbox will get on the next launch: requested, with the override
    applied on top.

    The rule is flatpak's own: an entry prefixed with `!` REMOVES that permission,
    and an entry without one adds it. A denial wins over a grant of the same
    thing, because that is what the sandbox does — and showing it the other way
    round would tell an operator they are protected when they are not."""
    req, ovr = requested(app_id), override(app_id)
    out = {}
    for cat, _title, _why, _icon in CATEGORIES:
        granted = {e for e in req.get(cat, []) if not e.startswith("!")}
        denied = set()
        for e in ovr.get(cat, []):
            if e.startswith("!"):
                denied.add(e[1:])
            else:
                granted.add(e)
        # a denial removes the exact grant it names
        granted = {g for g in granted if g.split(":")[0] not in denied}
        out[cat] = {"granted": sorted(granted), "denied": sorted(denied)}
    return out


def can_escape(app_id: str) -> bool:
    """Whether the application may talk to flatpak itself — which means running
    anything on the host, outside the sandbox, and makes every other permission
    on this page a formality."""
    for cat in ("session bus", "system bus"):
        for e in effective(app_id).get(cat, {}).get("granted", []):
            if e.split("=")[0] == ESCAPE_NAME:
                return True
    return False


def describe(app_id: str) -> dict:
    """The application's own account of itself, plus what it costs and what it
    runs on. `flatpak info` opens with the summary line the author wrote; the
    rest is a labelled block, so both are read from the same call rather than
    from three."""
    raw = _run(["flatpak", "info", app_id], 30)
    lines = raw.splitlines()
    # THE FIRST NON-EMPTY LINE. Captured (non-tty) output starts with a blank
    # line, so taking lines[0] gave an empty summary for every application —
    # which reads as "this program does not say what it is".
    summary = next((l.strip() for l in lines if l.strip()), "")
    out = {"summary": summary, "id": app_id}
    for line in lines[1:]:
        if ":" not in line:
            continue
        k, _, v = line.partition(":")
        key = k.strip().lower().replace(" ", "_")
        if key:
            out[key] = v.strip()
    return out


def total_size(app_id: str) -> dict:
    """WHAT IT REALLY WEIGHS. The application's own size is the small part: a
    40 MB program sits on a 2 GB platform, and removing the program frees the
    platform only if nothing else runs on it. Both numbers are given, with the
    runtimes named, rather than one number that is wrong either way."""
    info = describe(app_id)
    own = info.get("installed_size", "")
    deps = dependencies(app_id)
    rt = {r["id"] + "/" + r.get("branch", ""): r for r in runtimes()}
    shared = []
    for d in deps:
        # a dependency is written as id/arch/branch; the runtime list keys on
        # id and branch, so the arch in the middle is dropped for the lookup
        parts = d.split("/")
        key = parts[0] + "/" + (parts[-1] if len(parts) > 2 else "")
        r = rt.get(key) or rt.get(parts[0] + "/")
        if r:
            shared.append({"id": r["id"], "size": r.get("size", ""),
                           "name": r.get("name", "")})
    return {"own": own, "shared": shared}


def portal_permissions(app_id: str = "") -> list[dict]:
    """What the PORTALS have granted at runtime — a file the user picked in a
    dialog, a notification, a device. This is a separate store from the
    overrides, and an application can hold access here that no override mentions,
    so a page that ignored it would be showing half the answer."""
    out = []
    for line in _run(["flatpak", "permission-list"], 30).splitlines():
        p = line.split("\t")
        if len(p) < 3:
            continue
        row = {"table": p[0], "object": p[1], "app": p[2],
               "permissions": "\t".join(p[3:]).strip()}
        if not app_id or row["app"] == app_id:
            out.append(row)
    return out

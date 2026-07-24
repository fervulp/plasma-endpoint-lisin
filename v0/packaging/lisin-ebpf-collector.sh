#!/usr/bin/env bash
# Collector wrapper (runs as root, from the lisin-ebpf systemd unit).
# Resolves the cgroup id of the LiSin scope (lisin.scope) for the target user and
# passes it to bpftrace as $1, so the collector skips the agent's own subprocess
# tree IN THE KERNEL. If LiSin is not running yet, id=0 (no self-skip); restart
# this unit once LiSin is up so it re-resolves.
#
#   usage: lisin-ebpf-collector.sh <uid> <path-to.bt>
set -uo pipefail

UID_N="${1:?uid required}"
BT="${2:?bt path required}"

# LiSin's cgroup lives under the user's subtree; find it by name, accepting every
# way it may be launched: lisin.service (the user service), lisin.scope (the
# scope launcher), or app-lisin@<hash>.service (KDE wraps a .desktop launch in a
# transient unit like this). Pick the one that actually has a live process, so a
# leftover empty cgroup dir is never chosen.
CGDIR=""
for d in $(find "/sys/fs/cgroup/user.slice/user-${UID_N}.slice" -type d \
                \( -name 'lisin.service' -o -name 'lisin.scope' \
                   -o -name 'app-lisin@*.service' \) 2>/dev/null); do
    # cgroup.procs is a kernfs file: its stat size is ALWAYS 0, so `[ -s ]`
    # would never match. Read it and check for a live pid instead.
    if [ -n "$(head -n1 "$d/cgroup.procs" 2>/dev/null)" ]; then
        CGDIR="$d"; break
    fi
done
CGID=0
if [ -n "${CGDIR:-}" ]; then
    CGID=$(stat -c '%i' "$CGDIR" 2>/dev/null || echo 0)
fi

if [ "$CGID" != 0 ]; then
    echo "# lisin-ebpf: skipping self cgroup id=$CGID ($CGDIR)" >&2
else
    echo "# lisin-ebpf: lisin.service/scope not found - self-skip OFF; start LiSin, then restart this unit" >&2
fi

exec stdbuf -oL -eL bpftrace -q -B line "$BT" "$CGID"

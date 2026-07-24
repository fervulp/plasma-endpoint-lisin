#!/usr/bin/env bash
# v1 bootstrap: install the two dependencies that are NOT in Fedora repos,
# without root. Re-run after a Python minor upgrade (the duckdb native module
# is tied to the interpreter ABI). The RPM build will carry these instead.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1) DuckDB vendored into v1/vendor (kept out of git). PYTHONNOUSERSITE=1 hides
#    the user site, so the app adds this dir to sys.path explicitly.
python3 -m pip install --quiet --upgrade --target "$here/vendor" duckdb
echo "duckdb   -> $here/vendor"

# 2) osquery binary into ~/.local/opt/osquery (extracted from the official RPM).
OSQ_VER="${OSQ_VER:-5.23.1}"
dest="$HOME/.local/opt/osquery"
if [ ! -x "$dest/bin/osqueryi" ]; then
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/osquery.rpm" \
    "https://github.com/osquery/osquery/releases/download/${OSQ_VER}/osquery-${OSQ_VER}-1.linux.x86_64.rpm"
  rm -rf "$dest"; mkdir -p "$dest"
  ( cd "$dest" && rpm2cpio "$tmp/osquery.rpm" | cpio -idm --quiet )
  mkdir -p "$dest/bin"
  ln -sf "$dest/opt/osquery/bin/osqueryd" "$dest/bin/osqueryi"
  rm -rf "$tmp"
fi
echo "osquery  -> $dest/bin/osqueryi"
"$dest/bin/osqueryi" --version

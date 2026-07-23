#!/usr/bin/env bash
# Building the rpm: packaging/build-rpm.sh (needs rpmdevtools/rpm-build).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOP="$HOME/rpmbuild"
mkdir -p "$TOP"/{SOURCES,SPECS}
rm -rf "$TOP/SOURCES/lisin"
cp -r "$ROOT" "$TOP/SOURCES/lisin"
cp "$ROOT/packaging/lisin.spec" "$TOP/SPECS/"
rpmbuild -bb "$TOP/SPECS/lisin.spec"
echo "rpm: $TOP/RPMS/noarch/"

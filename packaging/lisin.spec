Name:           lisin
Version:        0.1.0
Release:        1%{?dist}
Summary:        LiSin — endpoint detection and response for Fedora (Kirigami UI)
License:        GPL-3.0-or-later
URL:            https://example.invalid/lisin
BuildArch:      noarch

# GUI stack: the system PySide6 (built against the system Qt) + Kirigami
Requires:       python3 >= 3.12
Requires:       python3-pyside6
Requires:       python3-pyyaml
Requires:       kf6-kirigami
Requires:       zstd
Requires:       sqlite
Recommends:     usbutils
# the inputs rely on these utilities; without them the corresponding sources
# are simply empty, which is why this is Recommends and not Requires
Recommends:     iproute
Recommends:     procps-ng
Recommends:     util-linux
Recommends:     libcap
Recommends:     whois
Recommends:     bind-utils
Recommends:     firewalld

%description
LiSin is a lightweight local EDR/SIEM for a single Fedora laptop:
system state tables (ports, services, packages, devices, firewall,
kernel modules), YAML+Python expertise (normalize plugins),
data-flow pipelines and expertise-driven detection rules.

%install
mkdir -p %{buildroot}%{_datadir}/lisin
cp -r %{_sourcedir}/lisin/{lisin_app.py,agent,ui,expertise} %{buildroot}%{_datadir}/lisin/
# the map of the system ships with the package: without it an installed copy
# cannot be understood, and PRINCIPLES/HOWTO live inside expertise/
cp %{_sourcedir}/lisin/ARCHITECTURE.md %{buildroot}%{_datadir}/lisin/
# Byte code is built for a SPECIFIC Python version: on another Fedora such
# .pyc files are useless clutter. Pipeline drafts are not executed by the engine.
find %{buildroot}%{_datadir}/lisin -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || :
find %{buildroot}%{_datadir}/lisin -name '*.pyc' -delete
find %{buildroot}%{_datadir}/lisin -name '*.draft.yaml' -delete
install -Dm755 %{_sourcedir}/lisin/packaging/lisin.sh %{buildroot}%{_bindir}/lisin
# Access extension (auditd rules, reading /var/log/audit) is installed
# separately and ONLY by hand as root: the package enables nothing itself.
install -Dm755 %{_sourcedir}/lisin/packaging/lisin-grant-access %{buildroot}%{_bindir}/lisin-grant-access
install -Dm644 %{_sourcedir}/lisin/lisin.desktop %{buildroot}%{_datadir}/applications/lisin.desktop
# launching goes through the installed launcher (in the development tree Exec
# points at a local path, and such a shortcut does not work on another machine)
sed -i 's|^Exec=.*|Exec=%{_bindir}/lisin|' %{buildroot}%{_datadir}/applications/lisin.desktop

%files
%{_datadir}/lisin
%{_bindir}/lisin
%{_bindir}/lisin-grant-access
%{_datadir}/applications/lisin.desktop

%post
exit 0

%changelog
* Sat Jul 18 2026 LiSin <lisin@localhost> - 0.1.0-1
- Initial package

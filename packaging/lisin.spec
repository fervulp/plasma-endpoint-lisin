Name:           lisin
Version:        0.1.0
Release:        1%{?dist}
Summary:        LiSin — endpoint detection and response for Fedora (Kirigami UI)
License:        GPL-3.0-or-later
URL:            https://example.invalid/lisin
BuildArch:      noarch

# GUI-стек: системный PySide6 (собран под системный Qt) + Kirigami
Requires:       python3 >= 3.12
Requires:       python3-pyside6
Requires:       python3-pyyaml
Requires:       kf6-kirigami
Requires:       zstd
Requires:       sqlite
Recommends:     usbutils
# точки входа опираются на эти утилиты; без них соответствующие источники
# просто пусты, поэтому это Recommends, а не Requires
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
# карта системы едет вместе с пакетом: без неё установленную копию
# невозможно понять, а PRINCIPLES/HOWTO лежат внутри expertise/
cp %{_sourcedir}/lisin/ARCHITECTURE.md %{buildroot}%{_datadir}/lisin/
# Байт-код собирается под КОНКРЕТНУЮ версию Python: на другой Fedora такие
# .pyc бесполезны и только мусорят. Черновики конвейеров движок не исполняет.
find %{buildroot}%{_datadir}/lisin -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || :
find %{buildroot}%{_datadir}/lisin -name '*.pyc' -delete
find %{buildroot}%{_datadir}/lisin -name '*.draft.yaml' -delete
install -Dm755 %{_sourcedir}/lisin/packaging/lisin.sh %{buildroot}%{_bindir}/lisin
# Расширение доступа (правила auditd, чтение /var/log/audit) — ставится
# отдельно и ТОЛЬКО вручную от root: пакет сам ничего не включает.
install -Dm755 %{_sourcedir}/lisin/packaging/lisin-grant-access %{buildroot}%{_bindir}/lisin-grant-access
install -Dm644 %{_sourcedir}/lisin/lisin.desktop %{buildroot}%{_datadir}/applications/lisin.desktop
# запуск — через установленный лаунчер (в дереве разработки Exec указывает
# на локальный путь, и такой ярлык на другой машине не работает)
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

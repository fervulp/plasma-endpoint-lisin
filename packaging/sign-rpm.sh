#!/usr/bin/env bash
# ПОДПИСЬ ПАКЕТА LiSin.
#
# Пакет собирается неподписанным (packaging/build-rpm.sh). Подпись нужна,
# когда пакет ставят НЕ на этой машине: без неё dnf на целевой системе не
# может проверить, что пакет не подменили по дороге, и требует --nogpgcheck.
#
# Требуется один раз от root:
#     sudo dnf install rpm-sign
#
# Дальше всё делается под обычным пользователем.
#
#   ./packaging/sign-rpm.sh --make-key      # создать ключ подписи (один раз)
#   ./packaging/sign-rpm.sh                 # подписать свежий пакет
#   ./packaging/sign-rpm.sh --export        # выгрузить открытый ключ для целевой машины
#
# Переменные:
#   KEY_NAME  — имя владельца ключа (по умолчанию LiSin packaging)
#   KEY_MAIL  — адрес в ключе
#   RPM_FILE  — какой пакет подписывать (по умолчанию последний собранный)
set -euo pipefail

KEY_NAME="${KEY_NAME:-LiSin packaging}"
KEY_MAIL="${KEY_MAIL:-lisin@localhost}"
RPM_DIR="${RPM_DIR:-$HOME/rpmbuild/RPMS/noarch}"
RPM_FILE="${RPM_FILE:-$(ls -t "$RPM_DIR"/lisin-*.rpm 2>/dev/null | head -1 || true)}"

need_rpmsign() {
    command -v rpmsign >/dev/null || {
        echo "Нет rpmsign. Установите: sudo dnf install rpm-sign" >&2
        exit 1
    }
}

case "${1:-}" in
--make-key)
    # ПАРОЛЬНАЯ ФРАЗА СПРАШИВАЕТСЯ gpg: ключ без пароля подписывает молча,
    # то есть любой, кто получил доступ к ~/.gnupg, подпишет что угодно от
    # вашего имени. Осознанный выбор оставлен за вами.
    gpg --full-generate-key
    echo
    echo "Готово. Теперь пропишите ключ в макросы rpm:"
    echo "  echo '%_gpg_name $KEY_NAME' >> ~/.rpmmacros"
    ;;
--export)
    gpg --armor --export "$KEY_NAME" > RPM-GPG-KEY-lisin
    echo "Открытый ключ: $(pwd)/RPM-GPG-KEY-lisin"
    echo "На целевой машине:"
    echo "  sudo rpm --import RPM-GPG-KEY-lisin"
    ;;
*)
    need_rpmsign
    [ -n "$RPM_FILE" ] || { echo "Пакет не найден в $RPM_DIR" >&2; exit 1; }
    grep -q "_gpg_name" ~/.rpmmacros 2>/dev/null || {
        echo "В ~/.rpmmacros нет _gpg_name — укажите ключ:" >&2
        echo "  echo '%_gpg_name $KEY_NAME' >> ~/.rpmmacros" >&2
        exit 1
    }
    rpmsign --addsign "$RPM_FILE"
    echo
    # ПРОВЕРКА, А НЕ ВЕРА НА СЛОВО: подпись должна читаться из самого пакета
    rpm -qip "$RPM_FILE" | grep -i signature
    rpm --checksig "$RPM_FILE"
    ;;
esac

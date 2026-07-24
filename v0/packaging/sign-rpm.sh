#!/usr/bin/env bash
# SIGNING THE LiSin PACKAGE.
#
# The package is built unsigned (packaging/build-rpm.sh). A signature is needed
# when the package is installed on ANOTHER machine: without it dnf on the target
# system cannot verify that the package was not tampered with on the way, and
# demands --nogpgcheck.
#
# Needed once, as root:
#     sudo dnf install rpm-sign
#
# Everything else is done as a normal user.
#
#   ./packaging/sign-rpm.sh --make-key      # create the signing key (once)
#   ./packaging/sign-rpm.sh                 # sign the freshly built package
#   ./packaging/sign-rpm.sh --export        # export the public key for the target machine
#
# Variables:
#   KEY_NAME  - the name of the key owner (LiSin packaging by default)
#   KEY_MAIL  - the address inside the key
#   RPM_FILE  - which package to sign (the last built one by default)
set -euo pipefail

KEY_NAME="${KEY_NAME:-LiSin packaging}"
KEY_MAIL="${KEY_MAIL:-lisin@localhost}"
RPM_DIR="${RPM_DIR:-$HOME/rpmbuild/RPMS/noarch}"
RPM_FILE="${RPM_FILE:-$(ls -t "$RPM_DIR"/lisin-*.rpm 2>/dev/null | head -1 || true)}"

need_rpmsign() {
    command -v rpmsign >/dev/null || {
        echo "No rpmsign. Install it: sudo dnf install rpm-sign" >&2
        exit 1
    }
}

case "${1:-}" in
--make-key)
    # THE PASSPHRASE IS ASKED BY gpg: a key without one signs silently, which
    # means anyone who gets access to ~/.gnupg can sign anything in your name.
    # The choice is deliberately left to you.
    gpg --full-generate-key
    echo
    echo "Done. Now register the key in the rpm macros:"
    echo "  echo '%_gpg_name $KEY_NAME' >> ~/.rpmmacros"
    ;;
--export)
    gpg --armor --export "$KEY_NAME" > RPM-GPG-KEY-lisin
    echo "Public key: $(pwd)/RPM-GPG-KEY-lisin"
    echo "On the target machine:"
    echo "  sudo rpm --import RPM-GPG-KEY-lisin"
    ;;
*)
    need_rpmsign
    [ -n "$RPM_FILE" ] || { echo "No package found in $RPM_DIR" >&2; exit 1; }
    grep -q "_gpg_name" ~/.rpmmacros 2>/dev/null || {
        echo "There is no _gpg_name in ~/.rpmmacros - name the key:" >&2
        echo "  echo '%_gpg_name $KEY_NAME' >> ~/.rpmmacros" >&2
        exit 1
    }
    rpmsign --addsign "$RPM_FILE"
    echo
    # VERIFY, DO NOT TAKE IT ON TRUST: the signature must be readable from the package itself
    rpm -qip "$RPM_FILE" | grep -i signature
    rpm --checksig "$RPM_FILE"
    ;;
esac

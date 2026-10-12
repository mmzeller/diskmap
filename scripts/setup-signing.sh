#!/bin/bash
# One-time setup so DiskMap keeps Full Disk Access across updates.
#
# macOS remembers Full Disk Access for an app by its signature. DiskMap used to be signed
# "ad hoc" (without a key), so every new version looked like a different app. This makes a
# signing key for DiskMap; GitHub Actions then signs every release with it, and macOS
# recognizes each new version as the same app.
#
# The key is made on this Mac, copied to the clipboard for you to save as a GitHub secret,
# and then deleted from this Mac. Only GitHub's encrypted secret storage keeps it.
#
# Run:  bash <(curl -fsSL https://raw.githubusercontent.com/mmzeller/diskmap/main/scripts/setup-signing.sh)
set -euo pipefail

REPO="mmzeller/diskmap"
SECRET_NAME="SIGNING_CERTIFICATE"
# The GitHub secret is what protects the key. This password only satisfies the file format,
# and the release workflow uses the same one to open it.
P12_PASSWORD="diskmap"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<'CNF'
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = DiskMap Signing
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

# macOS's own openssl, so the result is a file macOS's keychain tools can read.
OPENSSL=/usr/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL=openssl
"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "DiskMap Signing" \
  -out "$WORK/signing.p12" -passout "pass:$P12_PASSWORD"
VALUE=$(base64 < "$WORK/signing.p12" | tr -d '\n')

# The automated test on GitHub uses this to get the key without the clipboard.
if [ -n "${DISKMAP_SIGNING_OUTPUT:-}" ]; then
  printf '%s' "$VALUE" > "$DISKMAP_SIGNING_OUTPUT"
  exit 0
fi

printf '%s' "$VALUE" | pbcopy
open "https://github.com/$REPO/settings/secrets/actions/new"

cat <<MSG

DiskMap's signing key is made and copied to your clipboard.

A GitHub page just opened (sign in if it asks). On it:
  1. Name:    $SECRET_NAME
  2. Secret:  press ⌘V to paste
  3. Click "Add secret"

MSG
read -r -p "Press Return here once the secret is saved… " _ < /dev/tty

# Don't leave the key sitting on the clipboard.
printf '' | pbcopy
cat <<'MSG'

Done. The key is saved on GitHub and has been removed from this Mac.
From the next DiskMap release on, each new version is signed with it. After you install
that first signed version, turn Full Disk Access on one last time; it stays on after that.
MSG

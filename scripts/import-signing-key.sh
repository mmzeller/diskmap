#!/bin/bash
# Used by GitHub Actions. Loads the signing key from the SIGNING_CERTIFICATE secret into a
# temporary keychain and tells build.sh to sign with it (SIGN_IDENTITY, SIGN_KEYCHAIN).
set -euo pipefail
: "${SIGNING_CERTIFICATE:?The SIGNING_CERTIFICATE secret is empty}"

KEYCHAIN="$RUNNER_TEMP/diskmap-signing.keychain-db"
KEYCHAIN_PASSWORD=$(uuidgen)
P12="$RUNNER_TEMP/diskmap-signing.p12"

printf '%s' "$SIGNING_CERTIFICATE" | base64 --decode > "$P12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P diskmap -f pkcs12 -T /usr/bin/codesign >/dev/null
rm -f "$P12"
# Let codesign use the key without asking.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# shellcheck disable=SC2046
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

IDENTITY=$(security find-identity -p codesigning "$KEYCHAIN" | awk '/"DiskMap Signing"/ { print $2; exit }')
if [ -z "$IDENTITY" ]; then
  echo "::error::The signing key in SIGNING_CERTIFICATE couldn't be loaded."
  security find-identity -p codesigning "$KEYCHAIN" || true
  exit 1
fi
echo "Signing identity: $IDENTITY"
{
  echo "SIGN_IDENTITY=$IDENTITY"
  echo "SIGN_KEYCHAIN=$KEYCHAIN"
} >> "$GITHUB_ENV"

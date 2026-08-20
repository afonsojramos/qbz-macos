#!/usr/bin/env bash
# Create a disposable signing keychain and import the Developer ID identity.
#
# Sourced (not executed) so the caller keeps $QBZ_KEYCHAIN and the cleanup trap:
#   source scripts/keychain.sh
#   keychain_setup
#
# Requires: APPLE_CERTIFICATE (base64 .p12), APPLE_CERTIFICATE_PASSWORD,
#           SIGNING_IDENTITY, EXPECTED_TEAM_ID, RUNNER_TEMP.

set -euo pipefail

QBZ_KEYCHAIN=""
QBZ_KEYCHAIN_ORIGINAL_LIST=""

keychain_cleanup() {
  if [[ -n "$QBZ_KEYCHAIN_ORIGINAL_LIST" ]]; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s $QBZ_KEYCHAIN_ORIGINAL_LIST || true
  fi
  if [[ -n "$QBZ_KEYCHAIN" && -f "$QBZ_KEYCHAIN" ]]; then
    security delete-keychain "$QBZ_KEYCHAIN" || true
  fi
  rm -f "${RUNNER_TEMP:-/tmp}/qbz-cert.p12" "${RUNNER_TEMP:-/tmp}/qbz-notary.p8"
}

keychain_setup() {
  local tmp="${RUNNER_TEMP:-/tmp}"
  local p12="$tmp/qbz-cert.p12"
  local password
  QBZ_KEYCHAIN="$tmp/qbz-signing-$$.keychain-db"
  password="$(openssl rand -base64 24)"

  # Trap BEFORE anything sensitive lands on disk, so a cancelled or failed run
  # still removes the keychain, the p12 and the notary key.
  trap keychain_cleanup EXIT INT TERM

  QBZ_KEYCHAIN_ORIGINAL_LIST="$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')"

  security create-keychain -p "$password" "$QBZ_KEYCHAIN"
  security set-keychain-settings -lut 1800 "$QBZ_KEYCHAIN"
  security unlock-keychain -p "$password" "$QBZ_KEYCHAIN"

  umask 077
  printf '%s' "$APPLE_CERTIFICATE" | base64 --decode > "$p12"
  security import "$p12" -k "$QBZ_KEYCHAIN" -P "$APPLE_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign -f pkcs12
  rm -f "$p12"

  # Non-interactive access for codesign; without this the sign call blocks on a
  # GUI prompt that never appears on a runner.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$password" "$QBZ_KEYCHAIN" >/dev/null

  # shellcheck disable=SC2086
  security list-keychains -d user -s "$QBZ_KEYCHAIN" $QBZ_KEYCHAIN_ORIGINAL_LIST

  keychain_assert_identity
}

# Fail loudly unless exactly the expected Developer ID Application identity was
# imported. Guards against a mis-pasted secret silently signing with the wrong key.
keychain_assert_identity() {
  local found
  found="$(security find-identity -v -p codesigning "$QBZ_KEYCHAIN")"
  echo "$found"

  if [[ "$(grep -c '^\s*[0-9]\+)' <<<"$found")" -ne 1 ]]; then
    echo "::error::expected exactly one codesigning identity in the temp keychain" >&2
    return 1
  fi
  if ! grep -qF "$SIGNING_IDENTITY" <<<"$found"; then
    echo "::error::imported identity does not match SIGNING_IDENTITY" >&2
    return 1
  fi
  if ! grep -qF "($EXPECTED_TEAM_ID)" <<<"$found"; then
    echo "::error::imported identity is not under team $EXPECTED_TEAM_ID" >&2
    return 1
  fi
  if ! grep -qF "Developer ID Application" <<<"$found"; then
    echo "::error::identity is not a Developer ID Application certificate" >&2
    return 1
  fi
}

#!/usr/bin/env bash
# Re-sign one upstream QBZ dmg with a Developer ID identity, then notarize and
# staple the dmg.
#
#   scripts/resign.sh <version> <arch> <source-dmg> <out-dir>
#
# Order matters: sign the app, build the dmg from the signed app, sign the dmg,
# then notarize the dmg once. A ticket on the outer dmg covers the nested app,
# so the app is not submitted separately.
#
# Requires a keychain from keychain.sh plus SIGNING_IDENTITY, NOTARY_KEY_ID,
# NOTARY_ISSUER_ID and NOTARY_KEY (base64 .p8).

set -euo pipefail

VERSION="${1:?usage: resign.sh <version> <arch> <source-dmg> <out-dir>}"
ARCH="${2:?missing arch}"
SRC_DMG="${3:?missing source dmg}"
OUT_DIR="${4:?missing out dir}"

APP_NAME="QBZ.app"
BUNDLE_ID="com.blitzfc.qbz"
OUT_DMG="$OUT_DIR/QBZ_${VERSION}_${ARCH}.dmg"

WORK="$(mktemp -d)"
MOUNT="$WORK/mnt"
STAGE="$WORK/stage"
MOUNTED=0

resign_cleanup() {
  if [[ "$MOUNTED" -eq 1 ]]; then
    hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet || true
  fi
  rm -rf "$WORK"
}
trap resign_cleanup EXIT INT TERM

mkdir -p "$MOUNT" "$STAGE" "$OUT_DIR"

echo "==> Extracting $APP_NAME from $(basename "$SRC_DMG")"
hdiutil attach "$SRC_DMG" -nobrowse -readonly -mountpoint "$MOUNT"
MOUNTED=1
ditto "$MOUNT/$APP_NAME" "$STAGE/$APP_NAME"
hdiutil detach "$MOUNT" -quiet
MOUNTED=0

echo "==> Inspecting extracted bundle"
APP="$STAGE/$APP_NAME"
EXE="$APP/Contents/MacOS/qbz"
[[ -x "$EXE" ]] || { echo "::error::missing executable $EXE" >&2; exit 1; }

got_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$got_id" == "$BUNDLE_ID" ]] || {
  echo "::error::bundle id $got_id != $BUNDLE_ID" >&2; exit 1;
}

# The upstream bundle is a single binary with no nested frameworks, helpers or
# symlinks. Anything else means the bundle shape changed and this pipeline's
# flat (non inside-out) signing is no longer correct.
if [[ -n "$(find "$APP" -type l)" ]]; then
  echo "::error::unexpected symlink in bundle:" >&2
  find "$APP" -type l >&2
  exit 1
fi
if [[ -d "$APP/Contents/Frameworks" || -d "$APP/Contents/PlugIns" || -d "$APP/Contents/XPCServices" ]]; then
  echo "::error::bundle now contains nested code; signing order must become inside-out" >&2
  exit 1
fi

case "$ARCH" in
  aarch64) want_arch="arm64" ;;
  x64)     want_arch="x86_64" ;;
  *) echo "::error::unknown arch $ARCH" >&2; exit 1 ;;
esac
got_arch="$(lipo -archs "$EXE")"
grep -qw "$want_arch" <<<"$got_arch" || {
  echo "::error::$ARCH dmg carries arch '$got_arch', expected $want_arch" >&2; exit 1;
}

echo "==> Signing app (hardened runtime)"
# Entitlements stay opt-in: only add one after a reproduced hardened-runtime
# failure names it. Array form so a path with spaces survives.
sign_extra=()
if [[ -n "${ENTITLEMENTS:-}" ]]; then
  sign_extra=(--entitlements "$ENTITLEMENTS")
fi

# --force replaces the upstream ad-hoc signature.
codesign --force --options runtime --timestamp \
  --keychain "$QBZ_KEYCHAIN" --sign "$SIGNING_IDENTITY" \
  "${sign_extra[@]+"${sign_extra[@]}"}" \
  "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

echo "==> Building dmg"
# Symlink so a manual (non-Homebrew) install is a drag-and-drop.
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT_DMG"
hdiutil create -volname "QBZ" -srcfolder "$STAGE" -ov -format UDZO "$OUT_DMG"

echo "==> Signing dmg"
codesign --force --timestamp \
  --keychain "$QBZ_KEYCHAIN" --sign "$SIGNING_IDENTITY" "$OUT_DMG"
codesign --verify --strict --verbose=2 "$OUT_DMG"

echo "==> Notarizing dmg"
NOTARY_P8="${RUNNER_TEMP:-/tmp}/qbz-notary.p8"
umask 077
printf '%s' "$NOTARY_KEY" | base64 --decode > "$NOTARY_P8"

set +e
SUBMIT_OUT="$(xcrun notarytool submit "$OUT_DMG" \
  --key "$NOTARY_P8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
  --wait --timeout 30m --output-format json 2>&1)"
SUBMIT_RC=$?
set -e
echo "$SUBMIT_OUT"

SUBMISSION_ID="$(jq -r '.id // empty' <<<"$SUBMIT_OUT" 2>/dev/null || true)"
STATUS="$(jq -r '.status // empty' <<<"$SUBMIT_OUT" 2>/dev/null || true)"

# Apple recommends reading the log even on success; it reports warnings that
# become hard failures in later macOS releases.
if [[ -n "$SUBMISSION_ID" ]]; then
  echo "==> Notary log for $SUBMISSION_ID"
  xcrun notarytool log "$SUBMISSION_ID" \
    --key "$NOTARY_P8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
    "$OUT_DIR/notary-${ARCH}.json" || true
  cat "$OUT_DIR/notary-${ARCH}.json" 2>/dev/null || true
fi

if [[ "$SUBMIT_RC" -ne 0 || "$STATUS" != "Accepted" ]]; then
  echo "::error::notarization did not succeed (status='${STATUS:-unknown}', id='${SUBMISSION_ID:-none}')" >&2
  exit 1
fi

echo "==> Stapling"
xcrun stapler staple "$OUT_DMG"
xcrun stapler validate "$OUT_DMG"

echo "==> Gatekeeper assessment"
# Assess the app as an executable and the dmg as an opened container; these are
# different assessment types and using one for the other silently proves nothing.
if command -v syspolicy_check >/dev/null 2>&1; then
  syspolicy_check distribution "$APP" || true
fi
spctl -a -t exec -vvv "$APP"
spctl -a -t open -vvv --context context:primary-signature "$OUT_DMG"

shasum -a 256 "$OUT_DMG" | tee "$OUT_DMG.sha256"
echo "==> Done: $OUT_DMG"

#!/usr/bin/env bash
# Re-sign one upstream QBZ dmg with a Developer ID identity, then notarize and
# staple the dmg.
#
#   scripts/resign.sh <version> <arch> <source-dmg> <out-dir>
#
# Order matters: sign nested code inside-out (plugins and frameworks before the
# app that loads them), build the dmg from the signed app, sign the dmg, then
# notarize the dmg once. A ticket on the outer dmg covers the nested app, so
# the app is not submitted separately.
#
# Requires a keychain from keychain.sh plus SIGNING_IDENTITY, NOTARY_KEY_ID,
# NOTARY_ISSUER_ID and NOTARY_KEY (base64 .p8). EXPECTED_TEAM_ID, when set,
# is enforced on every signed Mach-O.

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
APP_REAL="$(cd "$APP" && pwd -P)"
EXE="$APP/Contents/MacOS/qbz"
[[ -x "$EXE" ]] || { echo "::error::missing executable $EXE" >&2; exit 1; }

got_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$got_id" == "$BUNDLE_ID" ]] || {
  echo "::error::bundle id $got_id != $BUNDLE_ID" >&2; exit 1;
}

# Recorded so the cask's `depends_on macos:` follows what the app declares
# rather than whatever it was when the cask was written.
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$MIN_MACOS" =~ ^[0-9]+(\.[0-9]+)*$ ]] || {
  echo "::error::LSMinimumSystemVersion is '$MIN_MACOS', expected a version" >&2; exit 1;
}
echo "$MIN_MACOS" > "$OUT_DIR/min-macos-${ARCH}"
echo "minimum macOS: $MIN_MACOS"

# Paths are fed through line-oriented tools below; a newline in one would let
# a crafted bundle smuggle an extra path past the checks.
if [[ -n "$(find "$APP" -name "$(printf '*\n*')")" ]]; then
  echo "::error::bundle contains a path with a newline" >&2
  exit 1
fi

# Upstream ships a macdeployqt layout: Qt frameworks in Contents/Frameworks,
# Qt plugins in Contents/PlugIns, and Contents/Resources/qml full of symlinks
# back into PlugIns/quick. Symlinks are fine as long as they stay inside the
# bundle: a dangling one breaks the seal, and one that escapes would be
# resolved on the user's machine against whatever happens to live there.
link_target() {
  # Physical path a symlink points at; empty when the target directory is gone.
  local rel dir
  rel="$(readlink "$1")"
  dir="$(cd "$(dirname "$1")" && cd "$(dirname "$rel")" 2>/dev/null && pwd -P)" || return 0
  echo "$dir/$(basename "$rel")"
}
while IFS= read -r link; do
  [[ -n "$link" ]] || continue
  target="$(link_target "$link")"
  if [[ -z "$target" || ! -e "$target" ]]; then
    echo "::error::dangling symlink in bundle: $link" >&2
    exit 1
  fi
  if [[ "$target" != "$APP_REAL"/* ]]; then
    echo "::error::symlink escapes the bundle: $link -> $target" >&2
    exit 1
  fi
done <<<"$(find "$APP" -type l)"

if [[ -d "$APP/Contents/XPCServices" ]]; then
  echo "::error::bundle now contains XPC services; review their entitlements before signing" >&2
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

# Every regular Mach-O file in the bundle, by content rather than by name or
# location, so a plugin or helper in an unexpected place is still signed.
# `file` is batched: a Qt bundle holds thousands of QML and image files and a
# process per file would dominate the run time.
list_machos() {
  find "$APP" -type f -print0 \
    | xargs -0 file --mime-type -- \
    | sed -n 's/: *application\/x-mach-binary$//p'
}

# What codesign should be pointed at for a given Mach-O: the enclosing
# framework when the file is that framework's current binary, the enclosing
# bundle when the file is its CFBundleExecutable, otherwise the file itself.
# Anything that resolves to a directory gets a full bundle signature (seal
# plus _CodeSignature), which is what Gatekeeper expects for nested code.
signing_unit() {
  local f="$1" fw name bundle exe

  if [[ "$f" == *.framework/* ]]; then
    fw="${f%.framework/*}.framework"
    name="$(basename "$fw" .framework)"
    if [[ -e "$fw/$name" && "$fw/$name" -ef "$f" ]]; then
      echo "$fw"
      return
    fi
  fi

  if [[ "$f" == */Contents/MacOS/* ]]; then
    bundle="${f%/Contents/MacOS/*}"
    if [[ "$bundle" != "$APP" && -f "$bundle/Contents/Info.plist" ]]; then
      exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist" 2>/dev/null || true)"
      if [[ -n "$exe" && "$bundle/Contents/MacOS/$exe" -ef "$f" ]]; then
        echo "$bundle"
        return
      fi
    fi
  fi

  echo "$f"
}

MACHOS="$(list_machos)"
[[ -n "$MACHOS" ]] || { echo "::error::no Mach-O files found in bundle" >&2; exit 1; }
grep -qxF "$EXE" <<<"$MACHOS" || {
  echo "::error::$EXE is not a Mach-O file" >&2; exit 1;
}

# Deepest first, so a library nested inside a framework is signed before the
# framework seals it, and every framework or plugin is signed before the app.
NESTED="$(
  while IFS= read -r f; do
    [[ "$f" == "$EXE" ]] && continue
    signing_unit "$f"
  done <<<"$MACHOS" \
    | sort -u \
    | awk -F/ '{ print NF "\t" $0 }' \
    | sort -t "$(printf '\t')" -k1,1nr -k2,2 \
    | cut -f2-
)"
echo "$(grep -c . <<<"$MACHOS") Mach-O files, $(grep -c . <<<"$NESTED") nested code units"

sign() {
  # --force replaces the upstream ad-hoc signature.
  codesign --force --options runtime --timestamp \
    --keychain "$QBZ_KEYCHAIN" --sign "$SIGNING_IDENTITY" "$@"
}

echo "==> Signing nested code (hardened runtime)"
while IFS= read -r unit; do
  [[ -n "$unit" ]] || continue
  echo "  ${unit#"$APP"/}"
  sign "$unit"
done <<<"$NESTED"

echo "==> Signing app (hardened runtime)"
# Entitlements stay opt-in: only add one after a reproduced hardened-runtime
# failure names it. They apply to the app executable only; nested libraries
# do not carry entitlements. Array form so a path with spaces survives.
sign_extra=()
if [[ -n "${ENTITLEMENTS:-}" ]]; then
  sign_extra=(--entitlements "$ENTITLEMENTS")
fi
sign "${sign_extra[@]+"${sign_extra[@]}"}" "$APP"

echo "==> Verifying signatures"
codesign --verify --strict --deep --verbose=2 "$APP"

# --deep only follows the nested code the bundle structure declares. Check
# every Mach-O independently: notarization rejects the whole submission over a
# single binary without a hardened-runtime signature from the expected team.
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  info="$(codesign --display --verbose=2 "$f" 2>&1)"
  if ! grep -qE '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$info"; then
    echo "::error::not signed with the hardened runtime: ${f#"$APP"/}" >&2
    echo "$info" >&2
    exit 1
  fi
  if [[ -n "${EXPECTED_TEAM_ID:-}" ]] \
      && ! grep -qxF "TeamIdentifier=$EXPECTED_TEAM_ID" <<<"$info"; then
    echo "::error::not signed by team $EXPECTED_TEAM_ID: ${f#"$APP"/}" >&2
    echo "$info" >&2
    exit 1
  fi
done <<<"$MACHOS"

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

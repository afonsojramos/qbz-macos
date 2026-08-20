#!/usr/bin/env bash
# Point the Homebrew cask at a newly published signed release.
#
#   scripts/bump-cask.sh <version>
#
# Requires GH_TOKEN with write access to the tap repo only.

set -euo pipefail

VERSION="${1:?usage: bump-cask.sh <version>}"
TAP_REPO="${TAP_REPO:-afonsojramos/homebrew-qbz}"
RELEASE_REPO="${GITHUB_REPOSITORY:-afonsojramos/qbz-macos}"
CASK="Casks/qbz.rb"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

echo "==> Fetching published dmgs for v$VERSION"
gh release download "v$VERSION" --repo "$RELEASE_REPO" --pattern "*.dmg" --dir "$WORK"

sha_for() {
  shasum -a 256 "$WORK/QBZ_${VERSION}_$1.dmg" | awk '{print $1}'
}
ARM_SHA="$(sha_for aarch64)"
INTEL_SHA="$(sha_for x64)"

echo "==> Cloning tap"
git clone "https://x-access-token:${GH_TOKEN}@github.com/${TAP_REPO}.git" "$WORK/tap"
cd "$WORK/tap"

CURRENT="$(sed -n 's/^  version "\(.*\)"$/\1/p' "$CASK")"
if [[ -z "$CURRENT" ]]; then
  echo "::error::could not read current version from $CASK" >&2
  exit 1
fi

# Homebrew users can only move forward. A downgrade here would push everyone who
# runs `brew upgrade` back onto an older build.
if [[ "$CURRENT" == "$VERSION" ]]; then
  echo "cask already at $VERSION, nothing to do"
  exit 0
fi
NEWEST="$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)"
if [[ "$NEWEST" != "$VERSION" ]]; then
  echo "::error::refusing to downgrade cask from $CURRENT to $VERSION" >&2
  exit 1
fi

sed -i.bak \
  -e "s/^  version \".*\"$/  version \"$VERSION\"/" \
  -e "s/^  sha256 arm:   \".*\",$/  sha256 arm:   \"$ARM_SHA\",/" \
  -e "s/^         intel: \".*\"$/         intel: \"$INTEL_SHA\"/" \
  "$CASK"
rm -f "$CASK.bak"

git diff --exit-code "$CASK" && { echo "::error::cask unchanged after bump" >&2; exit 1; }

git -c user.name="qbz-macos bot" -c user.email="noreply@github.com" \
  commit -am "chore: bump qbz to $VERSION"
git push origin HEAD
echo "==> Tap updated to $VERSION"

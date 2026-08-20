# qbz-macos

Signed and notarized macOS builds of [qbz](https://github.com/vicrodh/qbz).

## Why

Upstream publishes macOS dmgs that are ad-hoc signed. macOS refuses to open them
without a trip through System Settings > Privacy & Security, and Macs under MDM or
org security policy often block them outright.

This repo takes those exact dmgs, re-signs them with a Developer ID certificate,
notarizes them with Apple and staples the ticket, so they open with a normal
double-click.

## Install

```sh
brew install --cask afonsojramos/qbz/qbz
```

Or download a dmg from [Releases](https://github.com/afonsojramos/qbz-macos/releases).

## What these builds are, exactly

- **Same bytes as upstream.** The application binary is the one upstream's CI
  compiled for the matching tag. Nothing is recompiled here. Every release records
  the upstream tag, its commit and the SHA-256 of both the upstream dmg and the
  published dmg.
- **Signed under a personal Apple Developer account,** not the qbz project's. macOS
  will name that account as the developer. These are not official qbz builds and are
  not endorsed by upstream.
- **Not an audit.** Re-signing attests that these bytes came from upstream's published
  release unmodified. It is not a review of what that code does.

Prefer upstream's own dmgs if you would rather trust only the project's own release
pipeline.

## Upgrading from an upstream (unsigned) install

The signature changes from ad-hoc to a real Developer ID, which changes the app's
designated requirement. macOS may therefore re-prompt for Keychain access on first
launch, since qbz stores credentials under the `qbz` Keychain service. Allow the
prompt. If a saved login is not picked up, sign in again once.

## How a release is made

1. `poll-upstream` notices a new upstream tag that has **both** architectures
   attached and opens a tracking issue.
2. A human dispatches `resign-release` for that tag. It pauses for approval in the
   protected `signing` environment before any certificate is used.
3. Per architecture: verify the upstream asset digest, sign the app with the
   hardened runtime, build the dmg, sign the dmg, notarize it once, staple it, then
   assess it with `spctl`.
4. Both architectures must succeed before anything is published. Partial releases
   are treated as failures, never as done.
5. The Homebrew cask is bumped only after the release is published.

## Setup

Repository **variables**:

| Name | Example |
| --- | --- |
| `SIGNING_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_TEAM_ID` | `TEAMID` |

Repository **secrets** (in the `signing` environment):

| Name | What |
| --- | --- |
| `APPLE_CERTIFICATE` | Developer ID Application .p12, base64 |
| `APPLE_CERTIFICATE_PASSWORD` | password for that .p12 |
| `NOTARY_KEY` | App Store Connect API .p8, base64 |
| `NOTARY_KEY_ID` | key id for that .p8 |
| `NOTARY_ISSUER_ID` | issuer id |
| `HOMEBREW_TAP_TOKEN` | fine-grained PAT, contents write on the tap only |

Configure the `signing` environment with required reviewers and restrict it to the
default branch. That approval gate is what keeps the certificate from signing an
upstream tag nobody looked at.

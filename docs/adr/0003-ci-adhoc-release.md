# 0003 — CI publishes an ad-hoc-signed downloadable app

Status: Accepted

## Context

The app is buildable from a terminal (`./build.sh`) but that still needs the Xcode Command
Line Tools. People who just want to walk should download an `.app`. There is no Apple
Developer Program membership, so the binary cannot be Developer ID-signed or notarized.

macOS Gatekeeper quarantines anything fetched from a browser. An ad-hoc-signed app from
GitHub will not double-click open until the user right-clicks → Open, or strips the
quarantine xattr. Bluetooth still requires a signed bundle with
`NSBluetoothAlwaysUsageDescription`; ad-hoc signing satisfies that, as it already does
for local builds.

## Decision

1. **GitHub Actions on `macos-latest`** runs `UNIVERSAL=1 ./build.sh --zip` on every push
   to `main` (and on `v*` tags / manual dispatch). The workflow is
   `.github/workflows/release.yml`.
2. **Publish `WalkingPad.zip` as a GitHub Release** tagged `latest`, overwritten in place
   so [Releases/latest](https://github.com/anativ/R1-Walkingpad-Controller/releases/latest)
   and the stable asset URL
   `…/releases/latest/download/WalkingPad.zip` always point at the current main build.
3. **Stay ad-hoc signed.** Do not add a Developer ID, notarization, or a provisioning
   profile. Document the Gatekeeper right-click in the README and on the release body.
4. **Stamp `CFBundleVersion` from `GITHUB_RUN_NUMBER`** so Get Info identifies the build.
   Marketing version stays `1.0` on the rolling release; a `v*` tag becomes
   `CFBundleShortVersionString`.

## Rationale

- A paid Apple Developer ID would make double-click work, but it is a $99/year account
  plus secrets in GitHub. The extra Gatekeeper click is the cost of not having that, and
  it is the same path every unsigned open-source Mac app already takes.
- A rolling `latest` release means there is always a download button without anyone
  remembering to cut a tag. Versioned `v*` tags still produce a proper release when wanted.
- `ditto -c -k --keepParent` is the Apple-recommended way to zip an `.app`; it keeps the
  ad-hoc signature intact. `zip -r` can break it.
- Universal (`arm64` + `x86_64`) is the right default for a download: GitHub's runner is
  Apple Silicon, but Intel Macs on macOS 14 still exist.

## Amendment (2026-09-03)

Decision 2 assumed the rolling `latest` release would carry GitHub's "Latest" badge. Once
numbered tags existed, a `main` push finishing after a tag build stole the badge back from the
numbered release, so `/releases/latest` pointed at whichever job ran last. The rolling release is
now published as a pre-release without the badge; numbered `v*` releases own it, and
`/releases/latest/download/WalkingPad.zip` resolves to the newest numbered version. The rolling
build is still there under the `latest` tag for anyone who wants the tip of `main`.

## Consequences

- First launch from a download always hits Gatekeeper. The README has to say so, or the
  app looks broken.
- The ad-hoc signature changes on every CI run, so replacing the app with a newer zip
  may re-prompt for Bluetooth — the same as a local rebuild (ADR 0001).
- macOS-hosted Actions minutes are spendy relative to Linux (10×). This job is one
  compile; it is acceptable for a small personal repo.
- Notarization can be added later by swapping the signing identity in `build.sh` and
  adding `notarytool` + staple in the workflow. The zip-and-release shape does not change.

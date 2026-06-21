# Releasing BonsAI

Releases are automated by the tag workflow
([`.github/workflows/release.yml`](../.github/workflows/release.yml)). Pushing a
`v*` tag (or running the workflow manually) builds `BonsAI.app.zip`, **Developer
ID-signs and notarizes** it, and publishes it with an EdDSA-signed `appcast.xml` that
installed copies read to **auto-update and relaunch** via Sparkle.

When the Apple signing secrets are present (see below) the app is signed + notarized, so
it opens with a plain double-click. If they're absent the workflow still produces an
unsigned build (and logs a warning), so the pipeline never hard-breaks. Sparkle's own
EdDSA signature — separate from Apple's — is what verifies each auto-update download.

> Contributors never deal with any of this. Local `./script/build_and_run.sh` builds
> are unsigned and run fine; CI (`ci.yml`) only does `swift build` / `swift test`.

## Cutting a release

1. Move the `## [Unreleased]` notes under a new `## [x.y.z] - DATE` heading in
   [CHANGELOG.md](../CHANGELOG.md) — the workflow lifts that section into both the
   GitHub release notes and the appcast `<description>`.
2. Push a matching `vx.y.z` tag, or run **Release** from the Actions tab against the
   tag.

## One-time owner setup — the Sparkle key

Auto-update needs one EdDSA key pair (Sparkle's update-integrity key — free, no Apple
account, no certificate, no notarization). Generate it once; the tools live in
`.build/artifacts` after a `swift build`:

```bash
BIN=.build/artifacts/sparkle/Sparkle/bin
"$BIN/generate_keys"                          # prints the PUBLIC key (idempotent — reuses an existing key)
rm -f sparkle_private_key                     # -x silently fails if the file already exists
"$BIN/generate_keys" -x sparkle_private_key   # exports the PRIVATE key to a file
```

- Paste the **public** key into `SPARKLE_PUBLIC_KEY` in
  [`script/build_and_run.sh`](../script/build_and_run.sh) — it's committed (not
  secret), and the updater stays idle until it's set.
- Put the **private** key (the contents of `sparkle_private_key`) in a repository
  secret named `SPARKLE_PRIVATE_KEY` (*Settings → Secrets and variables → Actions*),
  and keep that file out of git.

## One-time owner setup — Apple signing & notarization

Notarized releases need a paid **Apple Developer Program** membership and the repository
secrets below (*Settings → Secrets and variables → Actions*). None of the values are
committed; the signing/notarization logic lives in
[`script/notarize.sh`](../script/notarize.sh).

| Secret | What it is |
| --- | --- |
| `MACOS_CERT_P12_BASE64` | base64 of your *Developer ID Application* certificate exported as a `.p12` (certificate **and** private key) |
| `MACOS_CERT_PASSWORD` | the password you set when exporting that `.p12` |
| `APPLE_ID` | the Apple ID used for notarization |
| `APPLE_TEAM_ID` | your 10-character Apple Team ID |
| `APPLE_APP_PASSWORD` | an app-specific password for that Apple ID ([appleid.apple.com](https://appleid.apple.com) → App-Specific Passwords) |

In **Keychain Access → login → My Certificates**, export the `Developer ID
Application: …` identity as a `.p12` (this bundles the certificate **and** its private
key — not the bare cert), then:

```bash
base64 -i DeveloperID.p12 | gh secret set MACOS_CERT_P12_BASE64 --repo <owner>/<repo>
```

To sign + notarize locally, store notarytool credentials once
(`xcrun notarytool store-credentials "BonsAI-notary" --apple-id … --team-id … --password …`)
and run [`./script/notarize.sh`](../script/notarize.sh).

Without these, releases fall back to unsigned (Sparkle still updates fine). With them —
plus the Sparkle key above — every tagged release ships signed, notarized, and
auto-updating.

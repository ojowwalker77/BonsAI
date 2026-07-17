# Releasing BonsAI

Releases are automated by the tag workflow
([`.github/workflows/release.yml`](../.github/workflows/release.yml)). Pushing a
strict `vX.Y.Z` tag (or running the workflow manually for an existing tag) builds the
app, **Developer ID-signs and notarizes** it, and publishes two assets: a
drag-to-install `BonsAI.dmg` (the
recommended first install — open it and drag **BonsAI** onto **Applications**) and a
zipped `BonsAI.app`, alongside an EdDSA-signed `appcast.xml`. Installed copies read the
appcast (whose enclosure is the `.zip`) to **auto-update and relaunch** via Sparkle.

The release workflow fails closed: it publishes nothing unless the Developer ID
certificate, App Store Connect API key, and Sparkle signing key are all configured.
Sparkle's EdDSA signature is separate from Apple's signature and verifies each
auto-update download.

> Contributors never deal with release credentials. Local `./script/run` builds can
> remain unsigned, while `./script/check` and `./script/verify` match the two required
> CI lanes.

## Cutting a release

1. On `main`, move the `## [Unreleased]` notes under a new `## [x.y.z] - DATE`
   heading in
   [CHANGELOG.md](../CHANGELOG.md) — the workflow lifts that section into both the
   GitHub release notes and the appcast `<description>`.
2. Run `./script/release-preflight x.y.z`, then merge the changelog/version PR and
   wait for the required **Quality** check on `main`.
3. Create and push the immutable tag from that verified commit:

   ```bash
   git tag -s vx.y.z -m "BonsAI vx.y.z"
   git push origin vx.y.z
   ```

   The workflow also supports rerunning an existing tag through **Actions → Release
   → Run workflow**. It refuses tags whose commit is not contained in `main`.

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
| `MACOS_CERTIFICATE_P12_BASE64` | base64 of your *Developer ID Application* certificate exported as a `.p12` (certificate **and** private key) |
| `MACOS_CERTIFICATE_PASSWORD` | the password you set when exporting that `.p12` |
| `APPLE_API_KEY_P8` | contents of an App Store Connect API private key (`AuthKey_….p8`) with notarization access |
| `APPLE_API_KEY_ID` | the API key ID shown in App Store Connect |
| `APPLE_API_ISSUER_ID` | the App Store Connect API issuer ID |
| `APPLE_TEAM_ID` | your 10-character Apple Developer team ID |

In **Keychain Access → login → My Certificates**, export the `Developer ID
Application: …` identity as a `.p12` (this bundles the certificate **and** its private
key — not the bare cert), then:

```bash
base64 -i DeveloperID.p12 | gh secret set MACOS_CERTIFICATE_P12_BASE64 --repo <owner>/<repo>
```

To sign and notarize locally, either store a `BonsAI-notary` keychain profile or
provide `APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID`, and `APPLE_API_ISSUER_ID`, then run
[`./script/notarize.sh`](../script/notarize.sh).

Missing credentials are a release error. Unsigned builds are supported only for local
development and must never be uploaded as public releases.

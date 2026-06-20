# Releasing BonsAI

Releases are **fully automated by the tag workflow**
([`.github/workflows/release.yml`](../.github/workflows/release.yml)). Pushing a
`v*` tag (or running the workflow manually) builds, **Developer ID-signs,
notarizes**, and publishes `BonsAI.app.zip` plus an EdDSA-signed `appcast.xml` that
installed copies read to auto-update via Sparkle.

> Contributors never sign anything. Local `./script/build_and_run.sh` builds are
> unsigned and run fine, and CI (`ci.yml`) only does `swift build` / `swift test`.
> Signing happens **only in the tag workflow**, in CI, on a `v*` tag.

## Cutting a release

1. Move the `## [Unreleased]` notes under a new `## [x.y.z] - DATE` heading in
   [CHANGELOG.md](../CHANGELOG.md) — the workflow lifts that section into both the
   GitHub release notes and the appcast `<description>`.
2. Push a matching `vx.y.z` tag, or run **Release** from the Actions tab against the
   tag.

The workflow does the rest. (v1.0.0 just establishes the signed baseline + publishes
the feed; auto-update is exercised from the next release onward.)

## One-time owner setup

Done once by the repo owner — not by contributors. Add these repository secrets
under *Settings → Secrets and variables → Actions*:

| Secret | What it is |
| --- | --- |
| `MACOS_CERTIFICATE` | base64 of the **Developer ID Application** certificate (`.p12`) |
| `MACOS_CERTIFICATE_PWD` | the `.p12` export password |
| `KEYCHAIN_PASSWORD` | any string; unlocks the ephemeral CI keychain |
| `NOTARY_KEY` | base64 of an **App Store Connect API key** (`.p8`) |
| `NOTARY_KEY_ID` | that key's Key ID |
| `NOTARY_ISSUER_ID` | that key's Issuer ID |
| `SPARKLE_PRIVATE_KEY` | the Sparkle EdDSA private key (below) |

- **Developer ID cert** — create a *Developer ID Application* certificate in your
  Apple Developer account, export it as `.p12`, then `base64 -i cert.p12 | pbcopy`.
- **Notarization key** — *App Store Connect → Users and Access → Integrations →
  App Store Connect API*.
- **Sparkle keys** — after a `swift build` (or `swift package resolve`), the Sparkle
  tools sit in `.build/artifacts`. Generate the EdDSA pair once:

  ```bash
  BIN=.build/artifacts/sparkle/Sparkle/bin
  "$BIN/generate_keys"                         # prints the PUBLIC key
  "$BIN/generate_keys" -x sparkle_private_key  # exports the PRIVATE key to a file
  ```

  Paste the **public** key into `SPARKLE_PUBLIC_KEY` in
  [`script/build_and_run.sh`](../script/build_and_run.sh) — it's committed (not
  secret), and the updater stays idle until it's set. Put the **private** key (the
  contents of `sparkle_private_key`) in the `SPARKLE_PRIVATE_KEY` secret and keep
  that file out of git.

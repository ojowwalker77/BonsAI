# Releasing BonsAI

Releases are automated by the tag workflow
([`.github/workflows/release.yml`](../.github/workflows/release.yml)). Pushing a
`v*` tag (or running the workflow manually) builds `BonsAI.app.zip` and publishes it
with an EdDSA-signed `appcast.xml` that installed copies read to **auto-update and
relaunch** via Sparkle.

The app is **not** Apple code-signed or notarized — it's ad-hoc signed by the
toolchain, so on first launch users right-click → **Open** (or clear the quarantine
flag). Every update after that installs seamlessly, because Sparkle's own EdDSA
signature — not Apple's — is what verifies each download.

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

That's the only secret the release workflow needs.

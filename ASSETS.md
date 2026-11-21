# Assets manifest — oneh-releases v0.1.0

Real values computed locally on 2026-11-22. Re-check after upload:

```sh
shasum -a 256 <file>            # macOS
stat -f%z <file>                # macOS
```

## Release assets to upload (drag-and-drop into the GitHub Release)

| File | sha256 | bytes | Status |
|---|---|---|---|
| `oneh-web-0.1.0-macos-arm64.tar.gz` | `6a56046d3a13149f26af0425593ec82dab6a3bd8bb2d6a89438ee951b9b0dad8` | `79523381` | BUILT locally, awaiting upload |
| `oneh-web-0.1.0-macos-arm64.tar.gz.sha256` | (sidecar) | (sidecar) | BUILT, awaiting upload |
| `oneh-web-0.1.0-macos-arm64.json` | (metadata) | (metadata) | BUILT, optional upload |
| `OneH-0.1.0-arm64.zip` | `40ddf547d293c2601f64e0f0e72c4bcff9b92231230a73f1636ea` | `11982522` | BUILT, ad-hoc signed, awaiting upload |
| `OneH-0.1.0-arm64.zip.sha256` | (sidecar) | (sidecar) | BUILT, awaiting upload |
| `OneH-0.1.0-arm64.dmg` | `4fbfa03ab0d7ceabe9ab5986b77671db273a871e399bfc82e122b2fa7da78a50` | `14766258` | BUILT, optional manual DMG |
| `install.sh` | `deb9df74fb3255e81ba4a76bf41a7b5cf7e75944f4b1eeed9561831f8bda9683` | `53122` | committed to repo + upload to Release |
| `install.ps1` | `850b4a4616f9cae0a0e2c854cf551633fa318e0c7bcda805748a51ac9e77eb69` | `17146` | committed to repo + upload to Release |
| `native-app.sh` | (see repo) | (see repo) | committed to repo + upload to Release |
| `latest.json` | `680cf54c46fc115a64e13a221462fd5dbe8e6d1e9ceb8daf35f4f06ca8692431` | `579` | committed to repo with REAL sha/bytes — upload to Release |

## Honest state

- Assets are locally built and checksum-verified, but NOT published as a GitHub
  Release yet. Until they are uploaded, `curl ... | sh` fails with 404.
- Node runtime: official `v26.13.1` darwin-arm64 tarball from nodejs.org,
  SHA-256 verified against published SHASUMS256.txt; MIT license confirmed from
  the official nodejs/node LICENSE. No unverified runtime claim.
- Native app is AD-HOC signed only: no Developer ID, no notarization.
  Browser-downloaded DMG/zip is quarantined — Right-click > Open. The curl
  installer path clears quarantine for the extracted app.
- No CI/Actions, no deploy, no tokens, no paid service. macOS arm64 only.

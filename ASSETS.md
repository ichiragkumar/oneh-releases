# Assets manifest — oneh-releases v0.1.0

Fill the real values **before** uploading `latest.json`. Empty/`0` means
"not filled in", not a verified checksum. Recompute after any rebuild:

```sh
shasum -a 256 <file>            # sha256 (macOS); sha256sum <file> on Linux
stat -f%z <file>               # bytes (macOS); stat -c%s <file> on Linux
```

## Release assets to upload (drag-and-drop into the GitHub Release)

| File | sha256 | bytes | Status |
|---|---|---|---|
| `oneh-web-0.1.0-macos-arm64.tar.gz` | (fill) | (fill) | NOT BUILT — built by `scripts/package-web.sh` |
| `oneh-web-0.1.0-macos-arm64.tar.gz.sha256` | (sidecar) | (sidecar) | NOT BUILT |
| `OneH-0.1.0-arm64.zip` | (fill) | (fill) | NOT BUILT — built by `scripts/package-native.sh` |
| `OneH-0.1.0-arm64.zip.sha256` | (sidecar) | (sidecar) | NOT BUILT |
| `install.sh` | `deb9df74fb3255e81ba4a76bf41a7b5cf7e75944f4b1eeed9561831f8bda9683` | `53122` | staged (real local values) |
| `install.ps1` | `850b4a4616f9cae0a0e2c854cf551633fa318e0c7bcda805748a51ac9e77eb69` | `17146` | staged (real local values) |
| `latest.json` | (fill after editing) | (fill after editing) | template — placeholders unfilled |

The installer hashes above are real values computed locally from the files in
this staging directory at creation time. They are **not** a claim about any
published URL; re-check them after upload.

## Repo files (commit to the repository, not the Release)

- `README.md`
- `ASSETS.md` (this file)

## Rules

- No GitHub API calls, no `gh` CLI automation, no git push by agents.
- No workflow file, no deploy, no signing service, no secrets or tokens.
- First release: macOS arm64 only. Windows/Linux rows are not claimed here.

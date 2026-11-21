# oneh releases (public install assets)

This is the **public download host** for the `oneh` local installer. It holds
built/install files only. The application **source stays private**.

Nothing here calls GitHub APIs, runs CI/Actions, deploys, signs a binary, or
stores a token. The owner uploads every asset by hand through the GitHub web UI.

## What lives here

| File | Role |
|---|---|
| `install.sh` | macOS/Linux installer — attach to the Release as an asset. |
| `install.ps1` | Windows installer — attach to the Release as an asset. |
| `native-app.sh` | Opt-in native app install module, fetched by `ONEH_INSTALL_NATIVE=1`. |
| `latest.json` | Version + asset metadata (sha256/bytes) read by the updater. |
| `README.md` | This file (committed to the repo). |
| `ASSETS.md` | Expected asset names and real checksums/sizes (committed). |
| `oneh-web-0.1.0-macos-arm64.tar.gz` | Path A prebuilt web bundle (+ owner-supplied Node tarball). |
| `oneh-web-0.1.0-macos-arm64.tar.gz.sha256` | sha256 sidecar for the web bundle. |
| `OneH-0.1.0-arm64.zip` | Path B ad-hoc signed `.app` zip. |
| `OneH-0.1.0-arm64.zip.sha256` | sha256 sidecar for the native zip. |

Assets are downloaded from `https://github.com/ichiragkumar/oneh-releases/releases/latest/download/<file>` (override the base with the
`ONEH_RELEASES_URL` environment variable). That path serves **Release assets**,
so installers and `latest.json` must be attached to the published Release, not
just committed to the repo.

## Install — macOS / Linux

```sh
curl -fsSL https://github.com/ichiragkumar/oneh-releases/releases/latest/download/install.sh -o install.sh
# Inspect install.sh before running it; do not pipe an unread script to a shell.
sh install.sh
```

## Install — Windows (PowerShell)

```powershell
Invoke-WebRequest -Uri "https://github.com/ichiragkumar/oneh-releases/releases/latest/download/install.ps1" -OutFile install.ps1
# Inspect install.ps1 before running it.
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

## Honest status

- The first release is **macOS arm64 only**. No signed/notarized binary, no DMG,
  and no Apple Developer account are involved (Path C is out of scope).
- Source builds still work behind the installer flag `--from-source`.
- `latest.json` ships with **empty `sha256` and `bytes: 0` placeholders** until
  the owner fills in the real values. Zero/empty means "not filled in" — never
  treat it as a verified checksum.
- No auto-update feed, no paid service, no credentials in this repository.

## Asset naming convention (from the distribution plan)

| Kind | Exact name |
|---|---|
| Web bundle (version `X.Y.Z`) | `oneh-web-X.Y.Z-macos-arm64.tar.gz` |
| Web checksum sidecar | `oneh-web-X.Y.Z-macos-arm64.tar.gz.sha256` |
| Native zip (version `X.Y.Z`) | `OneH-X.Y.Z-arm64.zip` |
| Native checksum sidecar | `OneH-X.Y.Z-arm64.zip.sha256` |
| Metadata | `latest.json` |
| Installers | `install.sh`, `install.ps1` |

For release `v0.1.0` the concrete web/native names are `oneh-web-0.1.0-macos-arm64.tar.gz` and
`OneH-0.1.0-arm64.zip`.

## For the owner: publish by hand

See `ASSETS.md` and the checklist printed by `scripts/setup-releases-repo.sh`.
In short: create the public repo, draft a Release tagged `v0.1.0`, drag-and-drop
all assets (including both installers and `latest.json`), then publish. Never
put a token in a file, prompt, or log; use your own signed-in browser session.

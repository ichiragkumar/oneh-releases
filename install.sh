#!/bin/sh
# install.sh — oneh local-machine installer. POSIX sh, self-contained, no sudo.
#
#   curl -fsSL <raw>/install.sh | sh
#   sh install.sh --yes
#   sh install.sh --version            # print installed version
#   sh install.sh --uninstall
#   sh install.sh --from-source --yes  # OLD path: git clone + npm ci + build
#
# DEFAULT PATH (prebuilt, 2026-11-22): download the versioned web tarball from
# ONEH_RELEASES_URL, verify its SHA-256 BEFORE extracting, extract into
# ~/.oneh/app, then run it with the Node bundled inside the artifact. No git,
# npm or system Node is needed on the user's machine. Only curl/wget + tar +
# a SHA-256 tool (shasum/sha256sum/openssl) are required. The user's
# ~/.oneh/data directory is NEVER modified by install/update; on failure after
# swap the previously installed app is restored from ~/.oneh/app.prev.
#
# The OLD build-from-source installer is preserved behind --from-source.
#
# Writes ONLY inside $HOME: ~/.oneh/{app,data,VERSION,install.log}, the
# ~/.local/bin/oneh-app shim and a per-OS launcher. Never deploys, never runs
# GitHub Actions, never prompts for passwords. OQ-030: ships `oneh-app`, not
# `oneh` (the coding CLI is never touched).
#
# The embedded lib/shim blocks below are verbatim mirrors of
# scripts/lib/common.sh and scripts/oneh-app-shim.sh; scripts/test-install.sh
# drift-checks them so a curl-piped install stays in sync with the repo files.
# The prebuilt path adds a thin PATH-aware wrapper around the unmodified shim
# (see write_shim) so the drift check stays green.

set -eu

# --- defaults ---------------------------------------------------------------
ONEH_HOME="${ONEH_HOME:-$HOME/.oneh}"
DATA="$ONEH_HOME/data"
APP="$ONEH_HOME/app"
LOG_FILE="$ONEH_HOME/install.log"
PID_FILE="$DATA/server.pid"
CFG="$DATA/install-config"
SHIM_DIR="$HOME/.local/bin"
SHIM_FILE="$SHIM_DIR/oneh-app"

# Build-from-source repo (only used with --from-source).
REPO_URL="${ONEH_REPO:-${ONEH_REPO_URL:-https://github.com/ichiragkumar/OneHarnsess.git}}"
# Fixed, enumerated download base. Users/testers may override via env; every
# final URL is this fixed base + a strictly validated version/platform token.
RELEASES_URL="${ONEH_RELEASES_URL:-https://github.com/ichiragkumar/oneh-releases/releases/latest/download}"
CHANNEL=stable
VERBOSE=0
YES=0
UNINSTALL=0
PRINT_VERSION=0
PIN_VERSION=""
PURGE_DATA=0
FROM_SOURCE=0
# macOS default is NATIVE-ONLY (owner decision 2026-11-22): the one-click
# command installs the real OneH.app into ~/Applications, not a web bundle.
# --with-web restores the prebuilt web + bundled-Node path.
WITH_WEB="${ONEH_WITH_WEB:-0}"
MARKER='# oneh-app shim (added by oneh installer)'

TMP_APP=""
TMP_READY=""
DOWNLOAD_DIR=""
SWAPPED=0
BACKUP=0
SCRIPT_DIR=""
case ${0:-} in
  */*) _sd=$(dirname "$0"); SCRIPT_DIR=$(CDPATH= cd -- "$_sd" 2>/dev/null && pwd) || SCRIPT_DIR="" ;;
esac

# --- logging (available before the library is installed) --------------------
log() { printf '[oneh] %s\n' "$*"; printf '%s oneh[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date)" "$$" "$*" >> "$LOG_FILE" 2>/dev/null || :; }
progress() { log "==> $*"; }
logv() { if [ "$VERBOSE" -eq 1 ]; then log "$*"; fi; }
warn() { printf '[oneh] WARN: %s\n' "$*" >&2; printf '%s WARN[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date)" "$$" "$*" >> "$LOG_FILE" 2>/dev/null || :; }
die() { printf '[oneh] ERROR: %s\n' "$*" >&2; printf '%s ERROR[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date)" "$$" "$*" >> "$LOG_FILE" 2>/dev/null || :; exit 1; }

usage() {
  cat <<EOF
Usage: sh install.sh [options]

Default on macOS: NATIVE ONLY. Downloads OneH-<version>-arm64.zip + .sha256
  from ONEH_RELEASES_URL (default:
  https://github.com/ichiragkumar/oneh-releases/releases/latest/download),
  verifies SHA-256, installs the REAL app into ~/Applications/OneH.app with a
  backup, clears quarantine on that bundle only, and launches it. No web
  bundle, no Node, no oneh-app shim. Ad-hoc signed (not notarized).
  On non-macOS the prebuilt web path is kept (no native app exists there).

  --with-web               install the prebuilt web bundle + bundled Node
                           instead of the native-only macOS default.
  --from-source            use the OLD path (git clone + npm ci + build);
                           requires git, npm and Node >= 22.12
  --channel <stable|main>  channel label (default stable; informational on the
                           prebuilt path, selects git ref on --from-source)
  --version[=TAG]          print installed version, or pin to version/tag TAG
  --verbose                emit extra progress detail
  --uninstall              remove the app, shim and launcher (data kept)
  --purge-data             with --uninstall, also remove ~/.oneh/data
  --yes                    assume yes for interactive confirmations
  -h, --help               show this help

Only writes under \$HOME. No sudo, no deploy, no GitHub Actions.
EOF
}

# --- arguments --------------------------------------------------------------
while [ "$#" -gt 0 ]; do
  _arg=$1
  case $_arg in
    -h|--help) usage; exit 0 ;;
    --verbose|-v) VERBOSE=1 ;;
    --yes|-y) YES=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --purge-data) PURGE_DATA=1 ;;
    --from-source) FROM_SOURCE=1 ;;
    --with-web) WITH_WEB=1 ;;
    --version) PRINT_VERSION=1 ;;
    --version=*) PIN_VERSION=${_arg#--version=} ;;
    --channel) shift; [ "$#" -gt 0 ] || die "--channel needs a value (stable|main)"; CHANNEL=$1 ;;
    --channel=*) CHANNEL=${_arg#--channel=} ;;
    --) shift; break ;;
    *) die "Unknown option: $_arg" ;;
  esac
  shift
done

case $CHANNEL in
  stable|main) : ;;
  *) die "Invalid --channel '$CHANNEL' (expected stable or main)" ;;
esac

if [ "$PRINT_VERSION" -eq 1 ] && [ -z "$PIN_VERSION" ]; then
  if [ -f "$ONEH_HOME/VERSION" ]; then cat "$ONEH_HOME/VERSION"; else printf 'not installed\n'; fi
  exit 0
fi

# Refuse to write anywhere outside the user's home directory.
assert_home_path() {
  case $1 in
    "$HOME"|"$HOME"/*) : ;;
    *) die "Refusing to write outside HOME: $1" ;;
  esac
}
assert_home_path "$ONEH_HOME"
assert_home_path "$SHIM_FILE"
assert_home_path "$HOME/.local/share/applications/oneh-app.desktop"
assert_home_path "$HOME/Applications/OneH.app"

# --- cleanup / rollback -----------------------------------------------------
cleanup() {
  _cleanup_status=$?
  if [ -n "$TMP_APP" ] && [ -d "$TMP_APP" ]; then rm -rf "$TMP_APP"; fi
  if [ -n "$TMP_READY" ] && [ -d "$TMP_READY" ]; then rm -rf "$TMP_READY"; fi
  if [ -n "$DOWNLOAD_DIR" ] && [ -d "$DOWNLOAD_DIR" ]; then rm -rf "$DOWNLOAD_DIR"; fi
  if [ "$_cleanup_status" -ne 0 ] && [ "$SWAPPED" -eq 1 ]; then
    warn "Failure after swap — rolling back to previous app."
    rm -rf "$APP"
    if [ "$BACKUP" -eq 1 ] && [ -d "$APP.prev" ]; then
      mv "$APP.prev" "$APP"
      log "Rollback complete; prior app restored."
    fi
  fi
  if [ "$_cleanup_status" -eq 0 ] && [ -d "$APP.prev" ]; then
    rm -rf "$APP.prev"
  fi
}
trap cleanup EXIT

# --- embedded library (mirror of scripts/lib/common.sh) ---------------------
write_lib() {
  LIB_FILE="$DATA/lib.sh"
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
    cp "$SCRIPT_DIR/lib/common.sh" "$LIB_FILE"
  else
    cat > "$LIB_FILE" <<'ONEH_LIB_EOF'
# scripts/lib/common.sh — shared POSIX helpers for the oneh local installer/shim.
#
# Sourced by ~/.local/bin/oneh-app from ~/.oneh/data/lib.sh. POSIX sh only:
# no `local`, no `[[ ]]`, no arrays, no process substitution. Works under
# dash, bash --posix and macOS /bin/sh.
#
# MIRROR: this file is embedded verbatim inside scripts/install.sh between
# ONEH_LIB_BEGIN/ONEH_LIB_END markers so the curl-piped installer is
# self-contained. scripts/test-install.sh drift-checks the two copies.
# If you edit this file, regenerate install.sh's embedded block.

ONEH_LIB_VERSION=1

# --- paths -----------------------------------------------------------------

oneh_home() { printf '%s\n' "${ONEH_HOME:-$HOME/.oneh}"; }

oneh_log_file() { printf '%s\n' "${ONEH_LOG_FILE:-$(oneh_home)/install.log}"; }

# --- logging ----------------------------------------------------------------

oneh_log_line() {
  _olf_file=$(oneh_log_file)
  [ -n "$_olf_file" ] || return 0
  [ -d "$(dirname "$_olf_file")" ] 2>/dev/null || return 0
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date)" "$$" "$*" >> "$_olf_file" 2>/dev/null || :
}

oneh_log() {
  printf '[oneh] %s\n' "$*"
  oneh_log_line "$*"
}

oneh_logv() {
  if [ "${ONEH_VERBOSE:-0}" -eq 1 ]; then oneh_log "$*"; fi
}

oneh_progress() { oneh_log "==> $*"; }

oneh_warn() {
  printf '[oneh] WARN: %s\n' "$*" >&2
  oneh_log_line "WARN: $*"
}

oneh_die() {
  printf '[oneh] ERROR: %s\n' "$*" >&2
  oneh_log_line "ERROR: $*"
  exit 1
}

# --- platform ---------------------------------------------------------------

oneh_detect_platform() {
  _odp_u=$(uname -s 2>/dev/null || printf unknown)
  case $_odp_u in
    Darwin) ONEH_OS=darwin ;;
    Linux)  ONEH_OS=linux ;;
    *)      ONEH_OS=$(printf '%s' "$_odp_u" | tr '[:upper:]' '[:lower:]') ;;
  esac
  _odp_m=$(uname -m 2>/dev/null || printf unknown)
  case $_odp_m in
    arm64|aarch64)   ONEH_ARCH=arm64 ;;
    x86_64|amd64)    ONEH_ARCH=x64 ;;
    *)               ONEH_ARCH=$_odp_m ;;
  esac
  printf '[oneh] platform: %s/%s\n' "$ONEH_OS" "$ONEH_ARCH"
}

# Exact, copy-pasteable install hints. These are guidance only: this script
# never runs sudo and never asks for a password.
oneh_hint() {
  case ${ONEH_OS:-} in
    darwin)
      case $1 in
        git)  printf 'brew install git   (or: xcode-select --install)' ;;
        node) printf 'brew install node@22   (or: https://nodejs.org, LTS 22+)' ;;
        npm)  printf 'npm ships with Node — reinstall Node from https://nodejs.org' ;;
        *)    printf 'brew install %s' "$1" ;;
      esac
      ;;
    linux)
      case $1 in
        git)  printf 'sudo apt-get install git   (Debian/Ubuntu)  |  sudo dnf install git (Fedora)' ;;
        node) printf 'NodeSource 22.x, nvm install 22, or your distro package manager' ;;
        npm)  printf 'npm ships with Node — reinstall Node (NodeSource 22.x / nvm)' ;;
        *)    printf 'sudo apt-get install %s   (or your distro package manager)' "$1" ;;
      esac
      ;;
    *)
      printf 'install %s using your OS package manager' "$1"
      ;;
  esac
}

# Verify git, npm and node >= 22.12 (root engines.node). Dies with exact hints.
oneh_check_deps() {
  oneh_detect_platform
  _ohd_ok=1
  if command -v git >/dev/null 2>&1; then
    oneh_logv "git: $(git --version 2>/dev/null || printf '?')"
  else
    oneh_log "git is required but was not found. Hint: $(oneh_hint git)"
    _ohd_ok=0
  fi
  if command -v npm >/dev/null 2>&1; then
    oneh_logv "npm: $(npm --version 2>/dev/null || printf '?')"
  else
    oneh_log "npm is required but was not found. Hint: $(oneh_hint npm)"
    _ohd_ok=0
  fi
  if command -v node >/dev/null 2>&1; then
    _ohd_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || printf 0)
    _ohd_minor=$(node -p 'process.versions.node.split(".")[1]' 2>/dev/null || printf 0)
    case $_ohd_major in ''|*[!0-9]*) _ohd_major=0 ;; esac
    case $_ohd_minor in ''|*[!0-9]*) _ohd_minor=0 ;; esac
    if [ "$_ohd_major" -lt 22 ] || { [ "$_ohd_major" -eq 22 ] && [ "$_ohd_minor" -lt 12 ]; }; then
      oneh_log "Node >= 22.12 required; found $(node --version 2>/dev/null || printf '?'). Hint: $(oneh_hint node)"
      _ohd_ok=0
    else
      oneh_logv "node: $(node --version 2>/dev/null || printf '?')"
    fi
  else
    oneh_log "node is required but was not found. Hint: $(oneh_hint node)"
    _ohd_ok=0
  fi
  [ "$_ohd_ok" -eq 1 ] || oneh_die "Required tooling is missing; install it and re-run the installer."
}

# --- network / repo ---------------------------------------------------------

# Print guidance for private repositories. Never prompts for credentials.
oneh_auth_guidance() {
  oneh_log "Repository: ${ONEH_REPO_URL:-<default>}"
  if [ "${ONEH_REPO_PUBLIC:-0}" -ne 1 ]; then
    oneh_log "Private repo? Authenticate first — this script never asks for a password inline:"
    oneh_log "  gh auth login                         # GitHub CLI (recommended)"
    oneh_log "  export GITHUB_TOKEN=<your-token>      # PAT via environment only; never pasted into a prompt"
  fi
}

# --- ports / version --------------------------------------------------------

# First free loopback port from 4317 upward. Binds 127.0.0.1 only.
oneh_find_free_port() {
  node -e '
    const net = require("net");
    let p = 4317;
    (function attempt() {
      if (p > 65535) { process.stderr.write("no free loopback port\n"); process.exit(1); }
      const s = net.createServer();
      s.once("error", () => { p += 1; attempt(); });
      s.once("listening", () => { const found = p; s.close(() => process.stdout.write(found + "\n")); });
      s.listen(p, "127.0.0.1");
    })();
  '
}

# Resolve the installed version: VERSION file wins, else package.json.
oneh_read_version() {
  _ohrv_home=$(oneh_home)
  if [ -f "$_ohrv_home/VERSION" ]; then
    tr -d '\r\n' < "$_ohrv_home/VERSION"
  else
    ONEH_PKG="$_ohrv_home/app/package.json" node -p 'try { require(process.env.ONEH_PKG).version } catch (e) { "0.0.0" }' 2>/dev/null || printf '0.0.0\n'
  fi
}
ONEH_LIB_EOF
  fi
  chmod 644 "$LIB_FILE"
}

# --- embedded shim (mirror of scripts/oneh-app-shim.sh) ---------------------
write_shim() {
  mkdir -p "$SHIM_DIR"
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/oneh-app-shim.sh" ]; then
    cp "$SCRIPT_DIR/oneh-app-shim.sh" "$SHIM_FILE"
  else
    cat > "$SHIM_FILE" <<'ONEH_SHIM_EOF'
#!/bin/sh
# oneh-app — manage the locally installed oneh web app.
#
# OQ-030: this command is deliberately named `oneh-app`. It must NEVER
# overwrite `oneh`, the delivered coding CLI (apps/cli/bin/oneh.mjs).
#
# Commands: open | stop | status | update | version | doctor | uninstall | logs
# POSIX sh. Sources the installed library at ~/.oneh/data/lib.sh.
#
# MIRROR: embedded verbatim inside scripts/install.sh between
# ONEH_SHIM_BEGIN/ONEH_SHIM_END so the curl-piped installer can write it.
set -eu

ONEH_HOME="${ONEH_HOME:-$HOME/.oneh}"
LIB="$ONEH_HOME/data/lib.sh"
CFG="$ONEH_HOME/data/install-config"

if [ ! -f "$LIB" ]; then
  printf '[oneh] ERROR: missing %s — re-run the installer.\n' "$LIB" >&2
  exit 1
fi
. "$LIB"

APP="$ONEH_HOME/app"
DATA="$ONEH_HOME/data"
PID_FILE="$DATA/server.pid"
PORT_FILE="$DATA/server.port"
SERVER_LOG="$DATA/server.log"
MARKER='# oneh-app shim (added by oneh installer)'

read_cfg() {
  [ -f "$CFG" ] || { printf '%s' "${2:-}"; return 0; }
  sed -n "s/^$1=//p" "$CFG" | head -n 1
}

REPO_URL="$(read_cfg REPO_URL "${ONEH_REPO:-https://github.com/ichiragkumar/OneHarnsess.git}")"
CHANNEL="$(read_cfg CHANNEL stable)"

is_running() {
  [ -f "$PID_FILE" ] || return 1
  _ir_pid=$(cat "$PID_FILE" 2>/dev/null || printf '')
  [ -n "$_ir_pid" ] || return 1
  kill -0 "$_ir_pid" 2>/dev/null
}

server_url() {
  _su_port=$(cat "$PORT_FILE" 2>/dev/null || printf '')
  [ -n "$_su_port" ] || _su_port=3000
  printf 'http://127.0.0.1:%s/\n' "$_su_port"
}

cmd_version() {
  oneh_log "oneh-app $(oneh_read_version)"
  oneh_log "channel: $CHANNEL"
  if [ -d "$APP/.git" ]; then
    _cv_commit=$(git -C "$APP" rev-parse --short HEAD 2>/dev/null || printf 'unknown')
    oneh_log "commit:  $_cv_commit"
  fi
}

cmd_status() {
  if is_running; then
    oneh_log "status:  RUNNING (pid $(cat "$PID_FILE"))"
    oneh_log "URL:     $(server_url)"
  else
    oneh_log "status:  STOPPED"
  fi
  oneh_log "version: $(oneh_read_version)  channel: $CHANNEL"
  oneh_log "home:    $ONEH_HOME"
}

next_binary() {
  for _nb in "$APP/node_modules/next/dist/bin/next" "$APP/apps/web/node_modules/next/dist/bin/next"; do
    if [ -f "$_nb" ]; then printf '%s\n' "$_nb"; return 0; fi
  done
  return 1
}

cmd_open() {
  if is_running; then
    oneh_log "Already running: $(server_url)"
    return 0
  fi
  [ -d "$APP" ] || oneh_die "App is not installed at $APP — run the installer first."
  mkdir -p "$DATA"

  _co_port=$(oneh_find_free_port)
  printf '%s\n' "$_co_port" > "$PORT_FILE"

  _co_next=$(next_binary || printf '')
  if [ -n "$_co_next" ]; then
    nohup node "$_co_next" start -H 127.0.0.1 -p "$_co_port" >> "$SERVER_LOG" 2>&1 &
    printf '%s\n' "$!" > "$PID_FILE"
  else
    (cd "$APP/apps/web" && PORT="$_co_port" HOST=127.0.0.1 nohup npm run start >> "$SERVER_LOG" 2>&1 & printf '%s\n' "$!" > "$PID_FILE")
  fi
  oneh_log "Starting oneh on 127.0.0.1:$_co_port ..."

  # Best-effort readiness check. Never claims success it did not observe.
  if command -v curl >/dev/null 2>&1; then
    _co_i=0
    while [ "$_co_i" -lt 20 ]; do
      if curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:$_co_port/" 2>/dev/null; then
        oneh_log "Ready: $(server_url)"
        return 0
      fi
      _co_i=$((_co_i + 1))
      sleep 1
    done
    oneh_warn "Server did not answer within 20s. Check logs: oneh-app logs"
  else
    oneh_warn "curl not available; cannot confirm readiness. Check: oneh-app logs"
  fi
}

cmd_stop() {
  if ! is_running; then
    oneh_log "Not running."
    rm -f "$PID_FILE" "$PORT_FILE"
    return 0
  fi
  _cs_pid=$(cat "$PID_FILE")
  kill "$_cs_pid" 2>/dev/null || :
  _cs_i=0
  while [ "$_cs_i" -lt 10 ] && kill -0 "$_cs_pid" 2>/dev/null; do
    _cs_i=$((_cs_i + 1))
    sleep 1
  done
  if kill -0 "$_cs_pid" 2>/dev/null; then
    oneh_warn "Process $_cs_pid did not exit; stop it manually."
  else
    oneh_log "Stopped (pid $_cs_pid)."
  fi
  rm -f "$PID_FILE" "$PORT_FILE"
}

cmd_logs() {
  if [ -f "$SERVER_LOG" ]; then
    oneh_log "--- server log ($SERVER_LOG) ---"
    tail -n 40 "$SERVER_LOG" || :
  else
    oneh_log "No server log yet."
  fi
  if [ -f "$ONEH_HOME/install.log" ]; then
    oneh_log "--- install log ($ONEH_HOME/install.log) ---"
    tail -n 40 "$ONEH_HOME/install.log" || :
  fi
}

newest_stable_tag() {
  # Print the highest tag name, or nothing. Uses sort -V where available.
  git ls-remote --tags --refs "$REPO_URL" 2>/dev/null \
    | sed 's#.*refs/tags/##' \
    | grep -v '\^{}' \
    | grep -v '^$' \
    | sort -V \
    | tail -n 1
}

show_remote_changelog() {
  _src_ref=$1
  # Keep every write inside $HOME (no temp files outside the user's home).
  _ct=$(mktemp -d "$DATA/.changelog.XXXXXX" 2>/dev/null) || return 0
  if git init -q "$_ct/r" 2>/dev/null \
     && git -C "$_ct/r" fetch -q --depth 1 "$REPO_URL" "$_src_ref" 2>/dev/null; then
    git -C "$_ct/r" show "$_src_ref:CHANGELOG.md" 2>/dev/null | head -n 40 || :
  else
    oneh_warn "Could not fetch changelog (offline or no access). Continuing without it."
  fi
  rm -rf "$_ct"
}

cmd_update() {
  _u_yes="${ONEH_YES:-0}"
  while [ "$#" -gt 0 ]; do
    _u_arg=$1
    case $_u_arg in
      --yes|-y) _u_yes=1 ;;
      --channel=*) CHANNEL=${_u_arg#--channel=} ;;
      --channel) shift; [ "$#" -gt 0 ] || oneh_die "update: --channel needs a value"; CHANNEL=$1 ;;
      *) oneh_die "update: unknown option $_u_arg" ;;
    esac
    shift
  done

  oneh_log "Checking $CHANNEL channel at $REPO_URL ..."
  _u_ref=""
  _u_label=""
  if [ "$CHANNEL" = stable ]; then
    _u_tag=$(newest_stable_tag)
    [ -n "$_u_tag" ] || oneh_die "No tags found. Is the repo reachable and authenticated?"
    _u_ref="refs/tags/$_u_tag"
    _u_label="$_u_tag"
  else
    _u_ref="refs/heads/$CHANNEL"
    _u_label="$CHANNEL"
  fi

  _u_remote_commit=$(git ls-remote "$REPO_URL" "$_u_ref" 2>/dev/null | awk 'NR==1 {print $1}')
  [ -n "$_u_remote_commit" ] || oneh_die "Could not resolve $_u_ref at $REPO_URL (offline or private repo without auth?)."
  _u_local_commit=$(git -C "$APP" rev-parse HEAD 2>/dev/null || printf '')

  if [ "$CHANNEL" = stable ] && [ "$_u_remote_commit" = "$_u_local_commit" ]; then
    oneh_log "Already up to date ($(oneh_read_version), $_u_label)."
    return 0
  fi

  oneh_log "Update available: $_u_label ($_u_remote_commit)"
  oneh_log "Currently installed: $(oneh_read_version) ($_u_local_commit)"
  oneh_log "Changelog (top of target CHANGELOG.md):"
  show_remote_changelog "$_u_ref"

  if [ "$_u_yes" -ne 1 ]; then
    if [ ! -t 0 ]; then
      oneh_die "Non-interactive shell: re-run with 'oneh-app update --yes' to confirm."
    fi
    printf 'Apply this update? [y/N] '
    _u_answer=""
    read -r _u_answer || _u_answer=""
    case $_u_answer in
      y|Y|yes|YES) : ;;
      *) oneh_log "Update cancelled."; return 0 ;;
    esac
  fi

  oneh_log "Launching installer (data in $DATA is preserved) ..."
  ONEH_REPO="$REPO_URL" ONEH_HOME="$ONEH_HOME" \
    sh "$ONEH_HOME/data/install.sh" --channel "$CHANNEL" --yes
}

remove_path_marker() {
  _rpm_file=$1
  [ -f "$_rpm_file" ] || return 0
  if grep -qF "$MARKER" "$_rpm_file" 2>/dev/null; then
    sed -i.bak "/$(printf '%s' "$MARKER" | sed 's/[][\.*^$]/\\&/g')/d" "$_rpm_file" 2>/dev/null || :
    rm -f "$_rpm_file.bak"
    oneh_log "Removed PATH line from $_rpm_file"
  fi
}

cmd_uninstall() {
  _un_purge=0
  for _un_arg in "$@"; do
    case $_un_arg in
      --purge-data) _un_purge=1 ;;
      --yes|-y) : ;;
      *) oneh_die "uninstall: unknown option $_un_arg" ;;
    esac
  done

  cmd_stop || :
  oneh_log "Removing oneh-app ..."
  rm -f "$HOME/.local/bin/oneh-app"
  case ${ONEH_OS:-} in
    darwin) rm -rf "$HOME/Applications/OneH.app" ;;
    linux)
      rm -f "$HOME/.local/share/applications/oneh-app.desktop"
      rm -f "$HOME/.local/share/icons/oneh-app.png"
      ;;
  esac
  remove_path_marker "$HOME/.zshrc"
  remove_path_marker "$HOME/.bashrc"
  remove_path_marker "$HOME/.profile"
  rm -rf "$APP" "$APP.prev" "$ONEH_HOME/VERSION"
  if [ "$_un_purge" -eq 1 ]; then
    rm -rf "$ONEH_HOME"
    oneh_log "Data directory purged: $ONEH_HOME"
  else
    oneh_log "Data kept at $DATA (use 'oneh-app uninstall --purge-data' to delete it)."
  fi
  oneh_log "Uninstalled the app and shim. The 'oneh' coding CLI was not touched."
}

cmd_doctor() {
  _doc_fail=0
  oneh_detect_platform
  for _doc_d in git node npm; do
    if command -v "$_doc_d" >/dev/null 2>&1; then
      oneh_log "OK      $_doc_d found"
    else
      oneh_log "MISSING $_doc_d — $(oneh_hint "$_doc_d")"
      _doc_fail=1
    fi
  done
  if command -v node >/dev/null 2>&1; then
    _doc_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || printf 0)
    _doc_minor=$(node -p 'process.versions.node.split(".")[1]' 2>/dev/null || printf 0)
    case $_doc_major in ''|*[!0-9]*) _doc_major=0 ;; esac
    case $_doc_minor in ''|*[!0-9]*) _doc_minor=0 ;; esac
    if [ "$_doc_major" -lt 22 ] || { [ "$_doc_major" -eq 22 ] && [ "$_doc_minor" -lt 12 ]; }; then
      oneh_log "MISSING node >= 22.12 (found $(node --version 2>/dev/null || printf '?')); $(oneh_hint node)"
      _doc_fail=1
    else
      oneh_log "OK      node >= 22.12"
    fi
  fi
  for _doc_p in "$APP" "$DATA" "$ONEH_HOME/VERSION" "$HOME/.local/bin/oneh-app"; do
    if [ -e "$_doc_p" ]; then oneh_log "OK      $_doc_p"; else oneh_log "MISSING $_doc_p"; _doc_fail=1; fi
  done
  if case "$PATH:" in *"$HOME/.local/bin:"*) true ;; *) false ;; esac; then
    oneh_log "OK      ~/.local/bin is on PATH"
  else
    oneh_log "WARN    ~/.local/bin is not on the current PATH"
  fi
  _doc_port=$(oneh_find_free_port 2>/dev/null || printf '')
  [ -n "$_doc_port" ] && oneh_log "OK      loopback port $_doc_port is free (server range starts 4317)"
  if is_running; then oneh_log "OK      server RUNNING at $(server_url)"; else oneh_log "INFO    server STOPPED"; fi
  [ "$_doc_fail" -eq 0 ] || oneh_die "Doctor found problems (see above)."
  oneh_log "Doctor: all critical checks passed."
}

usage() {
  cat <<EOF
Usage: oneh-app <command> [options]

Commands:
  open        start (or reuse) the local web app on 127.0.0.1, port >= 4317
  stop        stop the recorded server process
  status      show running state, URL, version and channel
  update      check tags, show changelog, confirm, then rebuild (keeps data)
              options: --yes, --channel=<stable|main>
  version     print installed version, channel and commit
  doctor      read-only diagnostics
  uninstall   remove app + shim + launcher (data kept by default)
              options: --purge-data, --yes
  logs        tail the server and installer logs

Note: 'oneh' is the coding CLI and is never modified (OQ-030).
EOF
}

[ "$#" -gt 0 ] || { usage; exit 2; }
_cmd=$1
shift
case $_cmd in
  -h|--help|help) usage ;;
  open)    cmd_open "$@" ;;
  stop)    cmd_stop "$@" ;;
  status)  cmd_status "$@" ;;
  update)  cmd_update "$@" ;;
  version|-V|--version) cmd_version "$@" ;;
  doctor)  cmd_doctor "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  logs)    cmd_logs "$@" ;;
  *) printf '[oneh] ERROR: unknown command: %s\n' "$_cmd" >&2; usage >&2; exit 2 ;;
esac
ONEH_SHIM_EOF
  fi
  chmod 755 "$SHIM_FILE"

  # Keep the embedded shim above byte-identical to scripts/oneh-app-shim.sh so
  # scripts/test-install.sh's drift check stays green. Relocate it into DATA
  # and install a thin PATH-aware wrapper at ~/.local/bin/oneh-app that:
  #   * prepends the bundled Node (app/bin) to PATH, and
  #   * starts a prebuilt Next standalone bundle with that bundled Node.
  # From-source installs have no app/server.js, so they keep the old behavior.
  _real_shim="$DATA/oneh-app.sh"
  mv "$SHIM_FILE" "$_real_shim"
  cat > "$SHIM_FILE" <<ONEH_WRAPPER_EOF
#!/bin/sh
# oneh-app wrapper written by install.sh. Delegates to the unmodified shim in
# ~/.oneh/data/oneh-app.sh, but ensures the bundled Node is used.
set -eu
ONEH_HOME="\${ONEH_HOME:-\$HOME/.oneh}"
export ONEH_HOME
APP="\$ONEH_HOME/app"
DATA="\$ONEH_HOME/data"
if [ -x "\$APP/bin/node" ]; then
  PATH="\$APP/bin:\$PATH"
  export PATH
fi

if [ "\${1:-}" = open ] && [ -f "\$APP/server.js" ]; then
  # Prebuilt standalone bundle: start it with the bundled Node, never system node.
  if [ ! -x "\$APP/bin/node" ]; then
    printf '[oneh] ERROR: bundled Node missing at %s/bin/node\\n' "\$APP" >&2
    exit 1
  fi
  PID_FILE="\$DATA/server.pid"
  PORT_FILE="\$DATA/server.port"
  SERVER_LOG="\$DATA/server.log"
  if [ -f "\$PID_FILE" ]; then
    _w_pid=\$(cat "\$PID_FILE" 2>/dev/null || printf '')
    if [ -n "\$_w_pid" ] && kill -0 "\$_w_pid" 2>/dev/null; then
      printf '[oneh] Already running (pid %s).\\n' "\$_w_pid"
      exit 0
    fi
  fi
  mkdir -p "\$DATA"
  . "\$DATA/lib.sh" 2>/dev/null || :
  _w_port=\$(oneh_find_free_port 2>/dev/null || printf '')
  case \$_w_port in
    ''|*[!0-9]*) _w_port=4317 ;;
  esac
  printf '%s\\n' "\$_w_port" > "\$PORT_FILE"
  PORT="\$_w_port" HOSTNAME=127.0.0.1 nohup "\$APP/bin/node" "\$APP/server.js" -H 127.0.0.1 -p "\$_w_port" >> "\$SERVER_LOG" 2>&1 &
  printf '%s\\n' "\$!" > "\$PID_FILE"
  printf '[oneh] Starting oneh (bundled Node) on 127.0.0.1:%s ...\\n' "\$_w_port"
  if command -v curl >/dev/null 2>&1; then
    _w_i=0
    while [ "\$_w_i" -lt 20 ]; do
      if curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:\$_w_port/" 2>/dev/null; then
        printf '[oneh] Ready: http://127.0.0.1:%s/\\n' "\$_w_port"
        exit 0
      fi
      _w_i=\$((_w_i + 1))
      sleep 1
    done
    printf '[oneh] WARN: server did not answer within 20s; check oneh-app logs\\n' >&2
  else
    printf '[oneh] WARN: curl not available; cannot confirm readiness\\n' >&2
  fi
  exit 0
fi

if [ "\${1:-}" = update ] && [ -f "\$DATA/install-config" ]; then
  if grep -q '^INSTALL_MODE=prebuilt\$' "\$DATA/install-config" 2>/dev/null; then
    _u_yes=0
    for _u_a in "\$@"; do
      case \$_u_a in --yes|-y) _u_yes=1 ;; esac
    done
    if [ "\$_u_yes" -ne 1 ]; then
      if [ ! -t 0 ]; then
        printf "[oneh] ERROR: Non-interactive shell: re-run with 'oneh-app update --yes' to confirm.\n" >&2
        exit 1
      fi
      printf 'Apply this update? [y/N] '
      _u_ans=""
      read -r _u_ans || _u_ans=""
      case \$_u_ans in
        y|Y|yes|YES) : ;;
        *) printf '[oneh] Update cancelled.\n'; exit 0 ;;
      esac
    fi
    # The prebuilt update worker downloads + verifies + swaps, keeps data.
    shift
    exec sh "\$DATA/install.sh" "\$@"
  fi
fi

exec "\$ONEH_HOME/data/oneh-app.sh" "\$@"
ONEH_WRAPPER_EOF
  chmod 755 "$SHIM_FILE"
}

# The compact update worker is written to DATA so `oneh-app update` can rebuild
# without re-downloading the installer. It never touches DATA contents.
write_update_worker() {
  cat > "$DATA/install.sh" <<'ONEH_UPDATE_EOF'
#!/bin/sh
# Compact update worker written by install.sh. Keeps ~/.oneh/data intact.
set -eu
ONEH_HOME="${ONEH_HOME:-$HOME/.oneh}"
DATA="$ONEH_HOME/data"
APP="$ONEH_HOME/app"
CFG="$DATA/install-config"
LOG="$ONEH_HOME/install.log"
CHANNEL=stable
while [ "$#" -gt 0 ]; do
  a=$1
  case $a in
    --channel=*) CHANNEL=${a#--channel=} ;;
    --channel) shift; [ "$#" -gt 0 ] || { printf '[oneh] update: --channel needs a value\n' >&2; exit 2; }; CHANNEL=$1 ;;
    --yes|-y) : ;;
    *) printf '[oneh] update: unknown option %s\n' "$a" >&2; exit 2 ;;
  esac
  shift
done
REPO_URL="${ONEH_REPO:-$(sed -n 's/^REPO_URL=//p' "$CFG" 2>/dev/null | head -n 1)}"
ulog() { printf '[oneh] %s\n' "$*"; printf '%s update[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date)" "$$" "$*" >> "$LOG" 2>/dev/null || :; }

INSTALL_MODE=$(sed -n 's/^INSTALL_MODE=//p' "$CFG" 2>/dev/null | head -n 1)
if [ "$INSTALL_MODE" = prebuilt ]; then
  BASE="${ONEH_RELEASES_URL:-$(sed -n 's/^RELEASES_URL=//p' "$CFG" 2>/dev/null | head -n 1)}"
  case $BASE in
    https://*|http://*|file://*) : ;;
    *) ulog "update: invalid or missing releases URL"; exit 1 ;;
  esac
  BASE=${BASE%/}
  PLAT=$(sed -n 's/^PLATFORM=//p' "$CFG" 2>/dev/null | head -n 1)
  case $PLAT in
    ''|*[!A-Za-z0-9-]*) ulog "update: invalid platform token '$PLAT'"; exit 1 ;;
  esac
  dl_one() {
    if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1"
    else return 1; fi
  }
  sha_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
    else return 1; fi
  }
  DL="$ONEH_HOME/.download.$$"; TMP="$ONEH_HOME/.app-update.$$"; READY="$ONEH_HOME/.app-ready.$$"
  SWAPPED=0; BACKUP=0
  mkdir -p "$DL"
  pcleanup() {
    _ps=$?
    [ ! -d "$DL" ] || rm -rf "$DL"
    [ ! -d "$TMP" ] || rm -rf "$TMP"
    [ ! -d "$READY" ] || rm -rf "$READY"
    if [ "$_ps" -ne 0 ] && [ "$SWAPPED" -eq 1 ]; then
      rm -rf "$APP"
      if [ "$BACKUP" -eq 1 ] && [ -d "$APP.prev" ]; then mv "$APP.prev" "$APP"; fi
      ulog "ROLLED BACK to previous app; data untouched."
    fi
    if [ "$_ps" -eq 0 ] && [ -d "$APP.prev" ]; then rm -rf "$APP.prev"; fi
    :
  }
  trap pcleanup EXIT
  VRAW="${ONEH_PIN_VERSION:-}"
  if [ -z "$VRAW" ]; then
    dl_one "$BASE/latest.json" "$DL/latest.json" || { ulog "update: cannot fetch latest.json from $BASE"; exit 1; }
    VRAW=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$DL/latest.json" | head -n 1)
  fi
  case $VRAW in *..*) ulog "update: invalid version '$VRAW'"; exit 1 ;; esac
  printf '%s' "$VRAW" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.]+)?$' || { ulog "update: invalid version '$VRAW'"; exit 1; }
  V=${VRAW#v}; LABEL=$V
  ulog "Updating to prebuilt $LABEL ..."
  A="oneh-web-$V-$PLAT.tar.gz"
  dl_one "$BASE/$A" "$DL/$A" || { ulog "update: download failed: $A"; exit 1; }
  dl_one "$BASE/$A.sha256" "$DL/$A.sha256" || { ulog "update: checksum download failed"; exit 1; }
  BYTES=$(wc -c < "$DL/$A" | tr -d '[:space:]')
  EXP=$(awk 'NF {print $1; exit}' "$DL/$A.sha256" | tr '[:upper:]' '[:lower:]')
  printf '%s' "$EXP" | grep -Eq '^[0-9a-f]{64}$' || { ulog "update: malformed checksum"; exit 1; }
  ACT=$(sha_of "$DL/$A" | tr '[:upper:]' '[:lower:]') || { ulog "update: no SHA-256 tool"; exit 1; }
  [ "$EXP" = "$ACT" ] || { ulog "update: SHA-256 MISMATCH — nothing extracted"; exit 1; }
  mkdir -p "$TMP"
  tar -xzf "$DL/$A" -C "$TMP" || { ulog "update: extraction failed"; exit 1; }
  ROOT=""
  for c in "$TMP/oneh-web" "$TMP" "$TMP/app"; do
    if [ -f "$c/server.js" ] || { [ -f "$c/package.json" ] && [ -d "$c/apps/web" ]; }; then ROOT=$c; break; fi
  done
  if [ -z "$ROOT" ]; then
    for d in "$TMP"/*; do [ -d "$d" ] || continue; if [ -f "$d/server.js" ]; then ROOT=$d; break; fi; done
  fi
  [ -n "$ROOT" ] || { ulog "update: no app root in archive"; exit 1; }
  mkdir -p "$READY"; mv "$ROOT" "$READY/app"
  if [ -d "$APP" ]; then rm -rf "$APP.prev"; mv "$APP" "$APP.prev"; BACKUP=1; fi
  mv "$READY/app" "$APP"; SWAPPED=1
  if [ -x "$APP/runtime/node/bin/node" ] && [ ! -x "$APP/bin/node" ]; then
    mkdir -p "$APP/bin"
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$APP/runtime/node/bin/node" > "$APP/bin/node"
    chmod 755 "$APP/bin/node"
  fi
  printf '%s\n' "$V" > "$ONEH_HOME/VERSION"
  {
    printf 'RELEASES_URL=%s\n' "$BASE"
    printf 'CHANNEL=%s\n' "$CHANNEL"
    printf 'REF=%s\n' "$VRAW"
    printf 'VERSION=%s\n' "$V"
    printf 'ARTIFACT=%s\n' "$A"
    printf 'SHA256=%s\n' "$ACT"
    printf 'BYTES=%s\n' "$BYTES"
    printf 'PLATFORM=%s\n' "$PLAT"
    printf 'INSTALL_MODE=prebuilt\n'
    printf 'INSTALLED_AT=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date)"
  } > "$CFG"
  ulog "Updated to $V ($BYTES bytes, sha256 $ACT). Data preserved."
  exit 0
fi

[ -n "$REPO_URL" ] || { printf '[oneh] update: no repository configured\n' >&2; exit 1; }
SORT_V=sort
if sort -V </dev/null >/dev/null 2>&1; then SORT_V="sort -V"; fi
if [ "$CHANNEL" = stable ]; then
  TAG=$(git ls-remote --tags --refs "$REPO_URL" | sed 's#.*refs/tags/##' | grep -v '\^{}' | grep -v '^$' | $SORT_V | tail -n 1)
  [ -n "$TAG" ] || { ulog "No tags found at $REPO_URL"; exit 1; }
  REF="refs/tags/$TAG"; LABEL=$TAG
else
  REF="refs/heads/$CHANNEL"; LABEL=$CHANNEL
fi
TMP="$ONEH_HOME/.app-update.$$"; SWAPPED=0; BACKUP=0
ucleanup() {
  _us=$?
  if [ -n "$TMP" ] && [ -d "$TMP" ]; then rm -rf "$TMP"; fi
  if [ "$_us" -ne 0 ] && [ "$SWAPPED" -eq 1 ]; then
    rm -rf "$APP"
    if [ "$BACKUP" -eq 1 ] && [ -d "$APP.prev" ]; then mv "$APP.prev" "$APP"; fi
    ulog "ROLLED BACK to previous app; data untouched."
  fi
}
trap ucleanup EXIT
ulog "Updating to $LABEL ..."
git clone --quiet "$REPO_URL" "$TMP" || { ulog "clone failed"; exit 1; }
git -C "$TMP" checkout --quiet "$REF" || { ulog "checkout failed"; exit 1; }
REMOTE=$(git ls-remote "$REPO_URL" "$REF" 2>/dev/null | awk 'NR==1 {print $1}')
PEELED=$(git ls-remote "$REPO_URL" "${REF}^{}" 2>/dev/null | awk 'NR==1 {print $1}')
if [ -n "$PEELED" ]; then REMOTE=$PEELED; fi
LOCAL=$(git -C "$TMP" rev-parse HEAD 2>/dev/null || printf '')
[ -n "$REMOTE" ] && [ "$REMOTE" = "$LOCAL" ] || { ulog "tag commit mismatch (expected $REMOTE, got $LOCAL)"; exit 1; }
if [ "${ONEH_SKIP_BUILD:-0}" -ne 1 ]; then
  (cd "$TMP" && npm ci) || { ulog "npm ci failed"; exit 1; }
  (cd "$TMP/apps/web" && npm run build) || { ulog "npm run build failed"; exit 1; }
else
  ulog "ONEH_SKIP_BUILD=1: dependency/build steps skipped (test mode)."
fi
if [ -d "$APP" ]; then rm -rf "$APP.prev"; mv "$APP" "$APP.prev"; BACKUP=1; fi
mv "$TMP" "$APP"; SWAPPED=1; TMP=""
printf '%s\n' "${LABEL#v}" > "$ONEH_HOME/VERSION"
{
  printf 'REPO_URL=%s\n' "$REPO_URL"
  printf 'CHANNEL=%s\n' "$CHANNEL"
  printf 'REF=%s\n' "$LABEL"
  printf 'VERSION=%s\n' "${LABEL#v}"
  printf 'COMMIT=%s\n' "$LOCAL"
} > "$CFG"
if [ -d "$APP.prev" ]; then rm -rf "$APP.prev"; fi
ulog "Updated to $LABEL ($LOCAL). Data preserved."
ONEH_UPDATE_EOF
  chmod 755 "$DATA/install.sh"
}

# --- launchers --------------------------------------------------------------
find_icon() {
  for _fi in "$SCRIPT_DIR/../assets/icon.png" "$APP/assets/icon.png" "$PWD/assets/icon.png"; do
    if [ -f "$_fi" ]; then printf '%s\n' "$_fi"; return 0; fi
  done
  return 1
}

create_launcher_darwin() {
  _ld_dir="$HOME/Applications/OneH.app/Contents"
  mkdir -p "$_ld_dir/MacOS" "$_ld_dir/Resources"
  _ld_icon_key=""
  _ld_icon=$(find_icon || printf '')
  if [ -n "$_ld_icon" ] && command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
    _ld_set="$DATA/OneH.iconset"
    rm -rf "$_ld_set"; mkdir -p "$_ld_set"
    _ld_made=0
    for _ld_sz in 16 32 128 256 512; do
      if sips -z "$_ld_sz" "$_ld_sz" "$_ld_icon" --out "$_ld_set/icon_${_ld_sz}x${_ld_sz}.png" >/dev/null 2>&1; then
        _ld_made=1
        if [ "$_ld_sz" -eq 256 ]; then cp "$_ld_set/icon_256x256.png" "$_ld_set/icon_256x256@2x.png"; fi
        if [ "$_ld_sz" -eq 32 ]; then cp "$_ld_set/icon_32x32.png" "$_ld_set/icon_32x32@2x.png"; fi
      fi
    done
    if [ "$_ld_made" -eq 1 ] && iconutil -c icns "$_ld_set" -o "$_ld_dir/Resources/AppIcon.icns" >/dev/null 2>&1; then
      _ld_icon_key='  <key>CFBundleIconFile</key><string>AppIcon</string>'
    else
      warn "Could not build .icns from assets/icon.png; launcher will use the generic icon."
    fi
    rm -rf "$_ld_set"
  elif [ -n "$_ld_icon" ]; then
    logv "iconutil/sips unavailable; skipping custom macOS icon."
  else
    logv "assets/icon.png not found; launcher built without a custom icon."
  fi
  cat > "$_ld_dir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OneH</string>
  <key>CFBundleDisplayName</key><string>OneH</string>
  <key>CFBundleIdentifier</key><string>local.oneh.app</string>
  <key>CFBundleExecutable</key><string>oneh-app-launch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
$_ld_icon_key
</dict>
</plist>
EOF
  cat > "$_ld_dir/MacOS/oneh-app-launch" <<EOF
#!/bin/sh
# Locally built launcher — no Gatekeeper quarantine, no signing.
set -eu
"$HOME/.local/bin/oneh-app" open
PORT=\$(cat "$HOME/.oneh/data/server.port" 2>/dev/null || printf 4317)
exec open "http://127.0.0.1:\$PORT/"
EOF
  chmod 755 "$_ld_dir/MacOS/oneh-app-launch"
  log "Created ~/Applications/OneH.app (locally built, unsigned)."
}

create_launcher_linux() {
  _li_dir="$HOME/.local/share/applications"
  _li_icon_dir="$HOME/.local/share/icons"
  mkdir -p "$_li_dir" "$_li_icon_dir"
  cat > "$_li_dir/oneh-app.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=OneH
Comment=oneh local web app (127.0.0.1 only)
Exec="$HOME/.local/bin/oneh-app" open
Icon=$_li_icon_dir/oneh-app.png
Terminal=false
Categories=Development;
EOF
  chmod 755 "$_li_dir/oneh-app.desktop"
  _li_icon=$(find_icon || printf '')
  if [ -n "$_li_icon" ]; then
    cp "$_li_icon" "$_li_icon_dir/oneh-app.png" 2>/dev/null || warn "Could not copy icon."
  else
    logv "assets/icon.png not found; .desktop entry has no custom icon file."
  fi
  log "Created $_li_dir/oneh-app.desktop."
}

ensure_path() {
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) logv "~/.local/bin already on PATH"; return 0 ;;
  esac
  _ep_profile=""
  case ${SHELL:-} in
    */zsh)  _ep_profile="$HOME/.zshrc" ;;
    */bash) _ep_profile="$HOME/.bashrc" ;;
    *)      _ep_profile="$HOME/.profile" ;;
  esac
  [ -f "$_ep_profile" ] || _ep_profile="$HOME/.profile"
  if grep -qF "$MARKER" "$_ep_profile" 2>/dev/null; then
    logv "PATH line already present in $_ep_profile"
    return 0
  fi
  printf '\nexport PATH="$HOME/.local/bin:$PATH"  %s\n' "$MARKER" >> "$_ep_profile"
  log "Added ~/.local/bin to PATH in $_ep_profile (restart your shell)."
}

write_metadata() {
  VERSION_LABEL=${REF_LABEL#v}
  {
    printf 'REPO_URL=%s\n' "$REPO_URL"
    printf 'CHANNEL=%s\n' "$CHANNEL"
    printf 'REF=%s\n' "$REF_LABEL"
    printf 'VERSION=%s\n' "$VERSION_LABEL"
    printf 'COMMIT=%s\n' "$TARGET_COMMIT"
    printf 'PLATFORM=%s/%s\n' "${ONEH_OS:-unknown}" "${ONEH_ARCH:-unknown}"
    printf 'INSTALLED_AT=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date)"
  } > "$CFG"
  printf '%s\n' "$VERSION_LABEL" > "$ONEH_HOME/VERSION"
}

# --- uninstall --------------------------------------------------------------
do_uninstall() {
  if [ -x "$SHIM_FILE" ]; then
    if [ "$PURGE_DATA" -eq 1 ]; then
      ONEH_YES=1 "$SHIM_FILE" uninstall --yes --purge-data
    else
      ONEH_YES=1 "$SHIM_FILE" uninstall --yes
    fi
    return 0
  fi
  warn "Shim not found; performing direct removal."
  [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null || :
  rm -f "$SHIM_FILE" "$HOME/.local/share/applications/oneh-app.desktop" "$HOME/.local/share/icons/oneh-app.png"
  rm -rf "$HOME/Applications/OneH.app"
  rm -rf "$APP" "$APP.prev" "$ONEH_HOME/VERSION"
  if [ "$PURGE_DATA" -eq 1 ]; then rm -rf "$ONEH_HOME"; else log "Data kept at $DATA"; fi
  log "Uninstalled. The 'oneh' coding CLI was not touched."
}

# --- prebuilt download / verify helpers -------------------------------------
# All URLs are assembled from a FIXED base plus strictly validated tokens.
# Never use a filename, version or host read from downloaded content to build
# a URL without passing the strict checks below.

validate_releases_url() {
  case $RELEASES_URL in
    https://*|http://*|file://*) : ;;
    *) die "ONEH_RELEASES_URL must start with https://, http:// or file:// (got '$RELEASES_URL')." ;;
  esac
  case $RELEASES_URL in
    *' '*|*'	'*) die "ONEH_RELEASES_URL contains whitespace." ;;
  esac
  RELEASES_URL=${RELEASES_URL%/}
}

# X.Y.Z with an optional v prefix and optional -/+ semver suffix. Digits,
# letters and dots only: no slashes, no '..', no URL-host injection possible.
valid_version_token() {
  case $1 in *..*) return 1 ;; esac
  printf '%s' "$1" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.]+)?$'
}

download_file() {
  _df_url=$1
  _df_out=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$_df_out" "$_df_url" || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$_df_out" "$_df_url" || return 1
  else
    die "Neither curl nor wget is available. Install one of them and re-run the installer."
  fi
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    die "No SHA-256 tool found (shasum, sha256sum or openssl). Install one and re-run."
  fi
}

detect_platform_token() {
  oneh_detect_platform >/dev/null
  case "$ONEH_OS/$ONEH_ARCH" in
    darwin/arm64) PLATFORM=macos-arm64 ;;
    darwin/x64)   PLATFORM=macos-x64 ;;
    linux/arm64)  PLATFORM=linux-arm64 ;;
    linux/x64)    PLATFORM=linux-x64 ;;
    *) die "No prebuilt artifact mapping for $ONEH_OS/$ONEH_ARCH (first release supports macOS arm64). Use --from-source to build locally." ;;
  esac
  log "Platform: $ONEH_OS/$ONEH_ARCH -> $PLATFORM"
}

fetch_version() {
  if [ -n "$PIN_VERSION" ]; then
    REF_LABEL=$PIN_VERSION
    log "Pinned version: $REF_LABEL"
  else
    download_file "$RELEASES_URL/latest.json" "$DOWNLOAD_DIR/latest.json" \
      || die "Could not download $RELEASES_URL/latest.json. Check ONEH_RELEASES_URL and connectivity."
    REF_LABEL=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$DOWNLOAD_DIR/latest.json" | head -n 1)
    [ -n "$REF_LABEL" ] || die "latest.json at $RELEASES_URL did not contain a version field."
  fi
  valid_version_token "$REF_LABEL" \
    || die "Invalid version '$REF_LABEL' in release metadata; refusing to build a URL from it."
  VERSION_TOKEN=${REF_LABEL#v}
  log "Target version: $REF_LABEL"
}

verify_tarball() {
  ASSET_NAME="oneh-web-$VERSION_TOKEN-$PLATFORM.tar.gz"
  log "Artifact: $ASSET_NAME"
  download_file "$RELEASES_URL/$ASSET_NAME" "$DOWNLOAD_DIR/$ASSET_NAME" \
    || die "Could not download $RELEASES_URL/$ASSET_NAME. Check the release assets."
  download_file "$RELEASES_URL/$ASSET_NAME.sha256" "$DOWNLOAD_DIR/$ASSET_NAME.sha256" \
    || die "Could not download $ASSET_NAME.sha256 — refusing to extract an unverified archive."

  DOWNLOAD_BYTES=$(wc -c < "$DOWNLOAD_DIR/$ASSET_NAME" | tr -d '[:space:]')
  [ -n "$DOWNLOAD_BYTES" ] || die "Could not determine downloaded size."

  EXPECTED_SHA=$(awk 'NF {print $1; exit}' "$DOWNLOAD_DIR/$ASSET_NAME.sha256" \
    | tr '[:upper:]' '[:lower:]')
  case $EXPECTED_SHA in
    ''|*[!0-9a-f]*) die "Malformed .sha256 for $ASSET_NAME (expected 64 hex characters)." ;;
  esac
  [ ${#EXPECTED_SHA} -eq 64 ] || die "Malformed .sha256 for $ASSET_NAME (expected 64 hex characters)."

  ACTUAL_SHA=$(sha256_file "$DOWNLOAD_DIR/$ASSET_NAME" | tr '[:upper:]' '[:lower:]')
  [ "$EXPECTED_SHA" = "$ACTUAL_SHA" ] \
    || die "SHA-256 MISMATCH for $ASSET_NAME (expected $EXPECTED_SHA, got $ACTUAL_SHA). Nothing was extracted."
  log "SHA-256 verified: $ACTUAL_SHA"
  log "Downloaded $ASSET_NAME ($DOWNLOAD_BYTES bytes)"
}

extract_to_app() {
  TMP_APP="$ONEH_HOME/.app-new.$$"
  TMP_READY="$ONEH_HOME/.app-ready.$$"
  rm -rf "$TMP_APP" "$TMP_READY"
  mkdir -p "$TMP_APP"
  tar -xzf "$DOWNLOAD_DIR/$ASSET_NAME" -C "$TMP_APP" \
    || die "Failed to extract $ASSET_NAME. Nothing was installed."

  # D3 packages a single top-level oneh-web/ dir (server.js + runtime/node),
  # but tolerate a bare bundle or an 'app/' wrapper as well.
  APP_ROOT=""
  for _c in "$TMP_APP/oneh-web" "$TMP_APP" "$TMP_APP/app"; do
    if [ -f "$_c/server.js" ] || { [ -f "$_c/package.json" ] && [ -d "$_c/apps/web" ]; }; then
      APP_ROOT=$_c
      break
    fi
  done
  if [ -z "$APP_ROOT" ]; then
    for _d in "$TMP_APP"/*; do
      [ -d "$_d" ] || continue
      if [ -f "$_d/server.js" ] || [ -f "$_d/apps/web/package.json" ]; then APP_ROOT=$_d; break; fi
    done
  fi
  [ -n "$APP_ROOT" ] \
    || die "Extracted archive has no recognizable app (server.js / apps/web). Nothing was installed."

  mkdir -p "$TMP_READY"
  mv "$APP_ROOT" "$TMP_READY/app" || die "Could not stage extracted app."
  rm -rf "$TMP_APP"
  TMP_APP=""

  # No fake success: cross-check the version the bundle reports against the
  # release metadata we actually downloaded.
  if [ -f "$TMP_READY/app/BUNDLE-INFO.txt" ]; then
    _bundle_version=$(sed -n 's/^version=//p' "$TMP_READY/app/BUNDLE-INFO.txt" | head -n 1)
    if [ -n "$_bundle_version" ] && [ "$_bundle_version" != "$VERSION_TOKEN" ]; then
      die "Artifact version mismatch: bundle says '$_bundle_version', release says '$VERSION_TOKEN'."
    fi
  fi

  if [ -d "$APP" ]; then
    rm -rf "$APP.prev"
    mv "$APP" "$APP.prev"
    BACKUP=1
  fi
  mv "$TMP_READY/app" "$APP" || die "Could not move app into place."
  SWAPPED=1
  rm -rf "$TMP_READY"
  TMP_READY=""
  log "Extracted app installed at $APP"
}

ensure_bundled_node() {
  NODE_SOURCE=""
  for _c in "$APP/runtime/node/bin/node" "$APP/bin/node" "$APP/node/bin/node" "$APP/node"; do
    if [ -x "$_c" ]; then NODE_SOURCE=$_c; break; fi
  done
  if [ -z "$NODE_SOURCE" ]; then
    warn "No bundled Node found in the artifact; 'oneh-app open' will require a system Node."
    return 0
  fi
  if [ "$NODE_SOURCE" = "$APP/bin/node" ]; then
    log "Bundled Node ready at $NODE_SOURCE"
    return 0
  fi
  mkdir -p "$APP/bin"
  cat > "$APP/bin/node" <<EOF
#!/bin/sh
# Bundled Node wrapper generated by install.sh. The system Node is never used.
exec "$NODE_SOURCE" "\$@"
EOF
  chmod 755 "$APP/bin/node"
  log "Bundled Node wrapper: $APP/bin/node -> $NODE_SOURCE"
}

prebuilt_write_metadata() {
  {
    printf 'RELEASES_URL=%s\n' "$RELEASES_URL"
    printf 'CHANNEL=%s\n' "$CHANNEL"
    printf 'REF=%s\n' "$REF_LABEL"
    printf 'VERSION=%s\n' "$VERSION_TOKEN"
    printf 'ARTIFACT=%s\n' "$ASSET_NAME"
    printf 'SHA256=%s\n' "$ACTUAL_SHA"
    printf 'BYTES=%s\n' "$DOWNLOAD_BYTES"
    printf 'PLATFORM=%s\n' "$PLATFORM"
    printf 'INSTALL_MODE=prebuilt\n'
    printf 'INSTALLED_AT=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date)"
  } > "$CFG"
  printf '%s\n' "$VERSION_TOKEN" > "$ONEH_HOME/VERSION"
}

# === main ===================================================================
mkdir -p "$ONEH_HOME" "$DATA"

if [ "$UNINSTALL" -eq 1 ]; then
  do_uninstall
  exit 0
fi

# Install the library first so its helpers are available for the rest of the run.
progress "1/8 Installing shared helpers"
write_lib
. "$DATA/lib.sh"
ONEH_VERBOSE=$VERBOSE
export ONEH_VERBOSE

if [ "$FROM_SOURCE" -eq 1 ]; then
  # ---- OLD path: build from git source (no changes to its behavior) ----------
  progress "2/8 Checking source-build tooling"
  ONEH_REPO_URL="$REPO_URL" oneh_check_deps
  oneh_logv "repo: $REPO_URL"
  oneh_auth_guidance

  progress "3/8 Resolving $CHANNEL channel"
  SORT_V=sort
  if sort -V </dev/null >/dev/null 2>&1; then SORT_V="sort -V"; fi
  if [ -n "$PIN_VERSION" ]; then
    REF_LABEL=$PIN_VERSION
    REPO_REF="refs/tags/$PIN_VERSION"
  elif [ "$CHANNEL" = stable ]; then
    REF_LABEL=$(git ls-remote --tags --refs "$REPO_URL" \
      | sed 's#.*refs/tags/##' | grep -v '\^{}' | grep -v '^$' \
      | $SORT_V | tail -n 1)
    [ -n "$REF_LABEL" ] || die "No tags found at $REPO_URL. Check network/auth or use --channel main."
    REPO_REF="refs/tags/$REF_LABEL"
  else
    REF_LABEL=$CHANNEL
    REPO_REF="refs/heads/$CHANNEL"
  fi
  log "Target: $REPO_REF ($REF_LABEL)"

  progress "4/8 Fetching $REF_LABEL"
  TMP_APP="$ONEH_HOME/.app-new.$$"
  rm -rf "$TMP_APP"
  git clone --quiet "$REPO_URL" "$TMP_APP" || die "git clone failed. Authenticate first (see hints above)."
  git -C "$TMP_APP" checkout --quiet "$REPO_REF" || die "Could not check out $REPO_REF"

  progress "5/8 Verifying tag commit"
  REMOTE_COMMIT=$(git ls-remote "$REPO_URL" "$REPO_REF" 2>/dev/null | awk 'NR==1 {print $1}')
  PEELED_COMMIT=$(git ls-remote "$REPO_URL" "${REPO_REF}^{}" 2>/dev/null | awk 'NR==1 {print $1}')
  if [ -n "$PEELED_COMMIT" ]; then REMOTE_COMMIT=$PEELED_COMMIT; fi
  LOCAL_COMMIT=$(git -C "$TMP_APP" rev-parse HEAD 2>/dev/null || printf '')
  [ -n "$REMOTE_COMMIT" ] || die "Could not resolve $REPO_REF remotely."
  [ "$REMOTE_COMMIT" = "$LOCAL_COMMIT" ] || die "Ref commit mismatch: expected $REMOTE_COMMIT, got $LOCAL_COMMIT"
  TARGET_COMMIT=$LOCAL_COMMIT
  logv "Verified commit $TARGET_COMMIT"

  progress "6/8 Installing dependencies and building"
  if [ "${ONEH_SKIP_NPM_CI:-0}" -eq 1 ]; then
    logv "ONEH_SKIP_NPM_CI=1: npm ci skipped (test mode)."
  else
    (cd "$TMP_APP" && npm ci) || die "npm ci failed; see $LOG_FILE"
  fi
  if [ "${ONEH_SKIP_BUILD:-0}" -eq 1 ]; then
    logv "ONEH_SKIP_BUILD=1: npm run build skipped (test mode)."
  else
    (cd "$TMP_APP/apps/web" && npm run build) || die "npm run build failed; see $LOG_FILE"
  fi

  progress "7/8 Swapping app into place"
  if [ -d "$APP" ]; then
    rm -rf "$APP.prev"
    mv "$APP" "$APP.prev"
    BACKUP=1
  fi
  mv "$TMP_APP" "$APP"
  SWAPPED=1
  TMP_APP=""

  progress "Writing config and update worker"
  write_metadata
  write_update_worker
else
  # ---- DEFAULT path: download a prebuilt, verified artifact -----------------
  progress "2/8 Checking download tooling"
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die "Neither curl nor wget is available. Install one of them and re-run the installer."
  fi
  command -v tar >/dev/null 2>&1 || die "tar is required to unpack the bundle."
  validate_releases_url
  log "Release base: $RELEASES_URL"

  progress "3/8 Detecting platform and resolving version"
  detect_platform_token
  DOWNLOAD_DIR="$ONEH_HOME/.download.$$"
  rm -rf "$DOWNLOAD_DIR"
  mkdir -p "$DOWNLOAD_DIR"
  fetch_version

  # NATIVE-ONLY default on macOS: install the real OneH.app and finish here.
  # No web tarball, no bundled Node, no oneh-app shim. The module is fetched
  # from the SAME fixed RELEASES_URL used for all other assets.
  if [ "$ONEH_OS" = darwin ] && [ "$WITH_WEB" -eq 0 ]; then
    progress "4/8 Downloading native app metadata"
    NATIVE_MODULE="$ONEH_HOME/.native-module.$$"
    NATIVE_READY=0
    if [ -f "$SCRIPT_DIR/lib/native-app.sh" ]; then
      cp "$SCRIPT_DIR/lib/native-app.sh" "$NATIVE_MODULE" && NATIVE_READY=1
    elif curl -fsSL --max-time 30 "$RELEASES_URL/native-app.sh" -o "$NATIVE_MODULE"; then
      NATIVE_READY=1
    fi
    [ "$NATIVE_READY" = 1 ] || die "Could not fetch native-app.sh from $RELEASES_URL."
    . "$NATIVE_MODULE"
    command -v oneh_native_install >/dev/null 2>&1 \
      || die "native-app.sh has no installer entry point."
    oneh_native_install || die "Native app install failed; no web fallback in native-only mode."
    printf '%s\n' "$VERSION_TOKEN" > "$ONEH_HOME/VERSION"
    rm -f "$NATIVE_MODULE"
    log "Native-only install complete: ~/Applications/OneH.app ($VERSION_TOKEN)."
    log "Ad-hoc signed, not notarized. Re-run this command to update. Full log: $LOG_FILE"
    exit 0
  fi

  progress "4/8 Downloading artifact"
  verify_tarball

  progress "5/8 Verifying checksum and extracting"
  # Checksum was verified inside verify_tarball BEFORE this extraction.
  extract_to_app

  progress "Writing config and update worker"
  prebuilt_write_metadata
  write_update_worker
  ensure_bundled_node
fi

progress "Writing shim and launchers"
write_shim
ensure_path
if [ "$ONEH_OS" = darwin ]; then create_launcher_darwin; elif [ "$ONEH_OS" = linux ]; then create_launcher_linux; else warn "Unsupported OS $ONEH_OS: skipped launcher."; fi

# Optional NATIVE app install (D7 module). Opt-in ONLY:
#   ONEH_INSTALL_NATIVE=1 sh install.sh ...
# It is non-fatal: the web app install remains the primary, always-on path.
# The module is hosted next to the installers in the public releases repo, and
# is fetched from the SAME fixed RELEASES_URL (never from untrusted input).
if [ "${ONEH_INSTALL_NATIVE:-0}" = 1 ]; then
  NATIVE_MODULE="$ONEH_HOME/.native-module.$$"
  NATIVE_READY=0
  if [ -f "$SCRIPT_DIR/lib/native-app.sh" ]; then
    cp "$SCRIPT_DIR/lib/native-app.sh" "$NATIVE_MODULE" && NATIVE_READY=1
  elif command -v curl >/dev/null 2>&1 \
       && curl -fsSL --max-time 30 "$RELEASES_URL/native-app.sh" -o "$NATIVE_MODULE"; then
    NATIVE_READY=1
  fi
  if [ "$NATIVE_READY" = 1 ]; then
    . "$NATIVE_MODULE"
    if command -v oneh_native_install >/dev/null 2>&1; then
      oneh_native_install || warn "native-app install failed (non-fatal); the web app is installed."
    else
      warn "native-app module has no installer entry point; skipped."
    fi
  else
    warn "native-app module unavailable at $RELEASES_URL; skipped. Publish native-app.sh in the public releases repo to enable it."
  fi
  rm -f "$NATIVE_MODULE"
fi

if [ -d "$APP.prev" ]; then rm -rf "$APP.prev"; fi

log "Installed oneh-app $(cat "$ONEH_HOME/VERSION") at $APP (data preserved at $DATA)."
if [ "$FROM_SOURCE" -eq 0 ]; then
  log "Artifact: $ASSET_NAME — $DOWNLOAD_BYTES bytes — sha256 $ACTUAL_SHA"
  log "Bundled Node: $APP/bin/node (system Node not used by oneh-app)"
fi
log "Start it with: oneh-app open    (serves 127.0.0.1 only, port >= 4317)"
log "Full log: $LOG_FILE"

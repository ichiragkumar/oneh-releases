# scripts/lib/native-app.sh — native macOS .app install module for the oneh installer.
#
# Sourced (never executed standalone) by scripts/install.sh when the owner asks
# for the prebuilt native app instead of the source-built web bundle. It defines
# three public entry points:
#
#   oneh_native_asset_name <version>   pure: print OneH-<version>-arm64.zip
#   oneh_install_native_app <version>  download -> verify SHA-256 -> extract ->
#                                     swap into ~/Applications/OneH.app ->
#                                     clear quarantine -> launch with open
#   oneh_native_install                D4 hook: forwards the installer's real
#                                     VERSION_TOKEN/REF_LABEL to the above
#
# POSIX sh only: no `local`, no `[[ ]]`, no arrays, no process substitution.
# Works under dash, bash --posix and macOS /bin/sh.
#
# PERMISSION BOUNDARY / HONESTY NOTES
# - macOS arm64 only. Anything else is refused before any download or write.
# - The whole operation runs in a subshell so its EXIT trap cannot clobber the
#   caller's trap. The function itself has no side effects at source time.
# - Verification uses the downloaded .sha256 sidecar and a locally computed
#   SHA-256; extraction happens ONLY after an exact match. No version, size,
#   hash or "success" status is ever invented.
# - No privilege escalation, no network publishing, no GitHub Actions, no
#   secret handling. Writes are confined to $HOME (the app destination and a
#   unique temp workspace); the web app under ~/.oneh is never touched.
# - The shipped bundle is ad-hoc signed at best, not Developer-ID signed and
#   not notarized. Clearing com.apple.quarantine is a convenience, not a claim
#   of trust; Gatekeeper may still block first launch.
#
# TEST-ONLY SEAMS (unset in normal operation):
#   ONEH_NATIVE_FIXTURE_DIR   read zip + .sha256 from this directory, no network
#   ONEH_NATIVE_APPS_DIR      alternate Applications parent (must be under $HOME)
#   ONEH_NATIVE_TMP_DIR       alternate parent for the unique temp workspace
#   ONEH_NATIVE_CURL          curl binary override
#   ONEH_NATIVE_UNZIP         unzip binary override
#   ONEH_NATIVE_XATTR         xattr binary override
#   ONEH_NATIVE_OPEN          open binary override (stub can force a launch failure)
#   ONEH_NATIVE_TEST_UNAME_S  fake `uname -s` result (test the macOS refusal)
#   ONEH_NATIVE_TEST_UNAME_M  fake `uname -m` result (test the arch refusal)
#   ONEH_NATIVE_VERSION       fallback version when the positional arg is empty

ONEH_NATIVE_LIB_VERSION=1

# --- pure helpers ------------------------------------------------------------

# Pure string function: no I/O beyond stdout, deterministic for a given input.
oneh_native_asset_name() {
  printf 'OneH-%s-arm64.zip\n' "${1:-}"
}

oneh_native_sidecar_name() {
  printf '%s.sha256\n' "$(oneh_native_asset_name "${1:-}")"
}

_oneh_native_default_releases_url() {
  printf '%s\n' 'https://github.com/ichiragkumar/oneh-releases/releases/latest/download'
}

_oneh_native_note() { printf '[oneh-native] %s\n' "$*"; }
_oneh_native_warn() { printf '[oneh-native] WARN: %s\n' "$*" >&2; }
_oneh_native_err()  { printf '[oneh-native] ERROR: %s\n' "$*" >&2; }

# Accept a conservative, URL-safe version token. Refuse empty, path separators,
# '..', a leading '-' (option-injection risk) or any non [A-Za-z0-9._-] byte.
_oneh_native_version_ok() {
  _onv=${1:-}
  [ -n "$_onv" ] || return 1
  case $_onv in
    */*|*..*|-*|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Print the locally computed SHA-256 (lowercase) of a file, or fail.
_oneh_native_hash_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk 'NR==1 {print $1}' | tr 'A-F' 'a-f'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk 'NR==1 {print $1}' | tr 'A-F' 'a-f'
  else
    return 1
  fi
}

# Read the expected hash from a sidecar. Both bare hashes and the
# `shasum -a 256` form ("<hash>  <file>") are accepted: always the first token.
_oneh_native_expected_hash() {
  awk 'NF {print $1; exit}' "$1" 2>/dev/null | tr 'A-F' 'a-f'
}

# Download (or, in fixture mode, copy) one asset into the temp workspace.
_oneh_native_fetch() {
  _onf_name=$1
  _onf_dst=$2
  if [ -n "${ONEH_NATIVE_FIXTURE_DIR:-}" ]; then
    [ -f "$ONEH_NATIVE_FIXTURE_DIR/$_onf_name" ] || return 1
    cp "$ONEH_NATIVE_FIXTURE_DIR/$_onf_name" "$_onf_dst" || return 1
  else
    "${ONEH_NATIVE_CURL:-curl}" -fLsS --retry 2 --connect-timeout 10 \
      -o "$_onf_dst" "$_onia_base/$_onf_name"
  fi
}

# --- rollback / cleanup ------------------------------------------------------
# Runs inside the operation subshell via `trap '_oneh_native_cleanup' EXIT`, so
# it sees that subshell's _onia_* variables and never disturbs the caller's trap.
# On failure the previous app is restored; the backup is NEVER deleted on
# failure (if the move-back itself fails, the backup is left on disk with a
# warning). On success the superseded backup is removed.
_oneh_native_cleanup() {
  _onc_status=$?
  trap - EXIT
  if [ -n "${_onia_work:-}" ] && [ -d "$_onia_work" ]; then
    rm -rf "$_onia_work" || _oneh_native_warn "Could not remove temp workspace: $_onia_work"
  fi
  if [ "$_onc_status" -ne 0 ] || [ "${_onia_success:-0}" -ne 1 ]; then
    if [ "${_onia_swapped:-0}" -eq 1 ] && [ -e "${_onia_dest:-}" ]; then
      rm -rf "$_onia_dest" || _oneh_native_warn "Could not remove the failed install at $_onia_dest"
    fi
    if [ "${_onia_backup_made:-0}" -eq 1 ] && [ -n "${_onia_backup:-}" ] && [ -d "$_onia_backup" ] && [ ! -L "$_onia_backup" ]; then
      if [ ! -e "${_onia_dest:-}" ] && mv "$_onia_backup" "$_onia_dest" 2>/dev/null; then
        _oneh_native_note "Restored the previous app from backup; failure rollback complete."
      else
        _oneh_native_warn "Previous app is PRESERVED at $_onia_backup — restore it manually if needed."
      fi
    fi
  else
    if [ "${_onia_backup_made:-0}" -eq 1 ] && [ -n "${_onia_backup:-}" ] && [ -d "$_onia_backup" ]; then
      rm -rf "$_onia_backup" || _oneh_native_warn "Could not remove the superseded backup: $_onia_backup"
    fi
  fi
}

# --- public installer --------------------------------------------------------

oneh_install_native_app() {
  (
    _onia_version=${1:-${ONEH_NATIVE_VERSION:-}}
    _onia_dest="${ONEH_NATIVE_APPS_DIR:-$HOME/Applications}/OneH.app"
    _onia_work=""
    _onia_backup=""
    _onia_backup_made=0
    _onia_swapped=0
    _onia_success=0
    trap '_oneh_native_cleanup' EXIT

    # 1. Refuse anything other than macOS arm64 BEFORE any download or write.
    _onia_uname_s=${ONEH_NATIVE_TEST_UNAME_S:-$(uname -s 2>/dev/null || printf unknown)}
    case $_onia_uname_s in
      Darwin) : ;;
      *) _oneh_native_err "macOS is required; detected '$_onia_uname_s'. Refusing to install the native app."; exit 1 ;;
    esac
    _onia_uname_m=${ONEH_NATIVE_TEST_UNAME_M:-$(uname -m 2>/dev/null || printf unknown)}
    case $_onia_uname_m in
      arm64|aarch64) : ;;
      *) _oneh_native_err "This release is arm64 only; detected '$_onia_uname_m'. Refusing a mismatched binary."; exit 1 ;;
    esac

    # 2. Version must be a real, safe token — never invent or guess one.
    if ! _oneh_native_version_ok "$_onia_version"; then
      _oneh_native_err "Invalid or missing version '$_onia_version'. Pass a token such as 1.2.3."
      exit 1
    fi

    # 3. Resolve the releases base URL; refuse embedded credentials and any
    # scheme outside the set the D4 installer itself supports (local file://
    # fixtures are useful for owner testing). SHA-256 is verified regardless.
    _onia_base=${ONEH_RELEASES_URL:-$(_oneh_native_default_releases_url)}
    case $_onia_base in
      *://*@*) _oneh_native_err "Refusing ONEH_RELEASES_URL with embedded credentials."; exit 1 ;;
    esac
    case $_onia_base in
      https://*|http://*|file://*) : ;;
      *) _oneh_native_err "Unsupported ONEH_RELEASES_URL scheme (expected https, http or file)."; exit 1 ;;
    esac
    while :; do
      case $_onia_base in */) _onia_base=${_onia_base%/} ;; *) break ;; esac
    done

    _onia_zip=$(oneh_native_asset_name "$_onia_version")
    _onia_sha=$(oneh_native_sidecar_name "$_onia_version")
    _oneh_native_note "Asset: $_onia_zip  (base: $_onia_base)"

    # 4. The only install destination is ~/Applications/OneH.app.
    case $_onia_dest in
      "$HOME"/*) : ;;
      *) _oneh_native_err "Refusing a destination outside HOME: $_onia_dest"; exit 1 ;;
    esac
    if [ -L "$_onia_dest" ]; then
      _oneh_native_err "Refusing to replace a symlink at $_onia_dest."
      exit 1
    fi

    # 5. Unique temp workspace under HOME; never inside ~/.oneh (web app files).
    _onia_tmp_parent=${ONEH_NATIVE_TMP_DIR:-$HOME}
    _onia_work=$(mktemp -d "$_onia_tmp_parent/.oneh-native.XXXXXX" 2>/dev/null) || {
      _oneh_native_err "Could not create a temp workspace under $_onia_tmp_parent."; exit 1;
    }
    _onia_stage="$_onia_work/stage"
    mkdir -p "$_onia_stage" || { _oneh_native_err "Could not create staging directory."; exit 1; }

    # 6. Fetch the zip and its checksum sidecar.
    if [ -n "${ONEH_NATIVE_FIXTURE_DIR:-}" ]; then
      _oneh_native_note "FIXTURE MODE: reading assets from $ONEH_NATIVE_FIXTURE_DIR (no network)."
    fi
    if ! _oneh_native_fetch "$_onia_zip" "$_onia_work/$_onia_zip"; then
      _oneh_native_err "Could not download $_onia_zip."; exit 1
    fi
    if ! _oneh_native_fetch "$_onia_sha" "$_onia_work/$_onia_sha"; then
      _oneh_native_err "Could not download $_onia_sha."; exit 1
    fi

    # 7. Verify SHA-256 BEFORE any extraction.
    _onia_expected=$(_oneh_native_expected_hash "$_onia_work/$_onia_sha")
    if ! printf '%s' "$_onia_expected" | grep -Eq '^[0-9a-f]{64}$'; then
      _oneh_native_err "Checksum sidecar is missing a 64-char hex SHA-256: $_onia_sha"
      exit 1
    fi
    _onia_actual=$(_oneh_native_hash_of "$_onia_work/$_onia_zip") || {
      _oneh_native_err "Could not compute a local SHA-256 (shasum/sha256sum unavailable)."; exit 1;
    }
    if [ "$_onia_actual" != "$_onia_expected" ]; then
      _oneh_native_err "SHA-256 mismatch for $_onia_zip (expected $_onia_expected, computed $_onia_actual). Nothing was extracted."
      exit 1
    fi
    _oneh_native_note "SHA-256 verified before extraction: $_onia_actual"

    # 8. Extract and validate that a real app bundle is present.
    if ! "${ONEH_NATIVE_UNZIP:-unzip}" -q "$_onia_work/$_onia_zip" -d "$_onia_stage"; then
      _oneh_native_err "unzip failed for $_onia_zip."; exit 1
    fi
    _onia_bundle="$_onia_stage/OneH.app"
    if [ ! -d "$_onia_bundle" ]; then
      _oneh_native_err "The zip did not contain a OneH.app bundle at its root."; exit 1
    fi
    if [ ! -d "$_onia_bundle/Contents/MacOS" ] || [ ! -f "$_onia_bundle/Contents/Info.plist" ]; then
      _oneh_native_err "OneH.app is not a valid macOS app bundle (Contents/MacOS + Info.plist missing)."
      exit 1
    fi
    _onia_has_exe=0
    for _onia_f in "$_onia_bundle"/Contents/MacOS/*; do
      if [ -f "$_onia_f" ] && [ -x "$_onia_f" ]; then _onia_has_exe=1; break; fi
    done
    if [ "$_onia_has_exe" -ne 1 ]; then
      _oneh_native_err "No executable found in OneH.app/Contents/MacOS."; exit 1
    fi

    # 9. Swap into place, moving any previous app aside to a timestamped backup.
    mkdir -p "$(dirname "$_onia_dest")" || { _oneh_native_err "Could not create $(dirname "$_onia_dest")."; exit 1; }
    if [ -e "$_onia_dest" ]; then
      _onia_backup="${_onia_dest}.backup.$(date '+%Y%m%d%H%M%S' 2>/dev/null || printf unknown).$$"
      if [ -e "$_onia_backup" ] || [ -L "$_onia_backup" ]; then
        _oneh_native_err "Backup path already exists: $_onia_backup"; exit 1
      fi
      if ! mv "$_onia_dest" "$_onia_backup"; then
        _oneh_native_err "Could not move the previous app aside to $_onia_backup."; exit 1
      fi
      _onia_backup_made=1
      _oneh_native_note "Previous app moved aside to $_onia_backup"
    fi
    if ! mv "$_onia_bundle" "$_onia_dest"; then
      _oneh_native_err "Could not move the verified bundle into $_onia_dest."; exit 1
    fi
    _onia_swapped=1
    _oneh_native_note "Installed the verified bundle at $_onia_dest"

    # 10. Clear quarantine ONLY on the extracted, installed bundle. An absent
    # attribute is not an error; a real removal failure is reported honestly.
    if "${ONEH_NATIVE_XATTR:-xattr}" -dr com.apple.quarantine "$_onia_dest" 2>/dev/null; then
      _oneh_native_note "Cleared com.apple.quarantine on $_onia_dest only."
    elif "${ONEH_NATIVE_XATTR:-xattr}" -l "$_onia_dest" 2>/dev/null | grep -q 'com.apple.quarantine'; then
      _oneh_native_err "Could not clear com.apple.quarantine on $_onia_dest."; exit 1
    else
      _oneh_native_note "No com.apple.quarantine attribute to clear on $_onia_dest."
    fi
    _oneh_native_note "HONESTY: this build is ad-hoc signed / unsigned — not Developer-ID signed, not notarized. Clearing quarantine does not establish publisher trust."

    # 11. Launch. A launch failure is a failed operation and triggers rollback.
    if ! "${ONEH_NATIVE_OPEN:-open}" "$_onia_dest"; then
      _oneh_native_err "open failed to launch $_onia_dest."
      exit 1
    fi
    _oneh_native_note "Launched $_onia_dest with open."

    _onia_success=1
    exit 0
  )
}

# --- D4 installer hook -------------------------------------------------------
# scripts/install.sh sources this module and calls `oneh_native_install` with no
# arguments after resolving the real release version into VERSION_TOKEN (or
# REF_LABEL in older callers). This adapter forwards that real value; it never
# substitutes a guessed or placeholder version. Failure stays visible to the
# caller (D4 logs it as a non-fatal warning), and no web app file is touched.
oneh_native_install() {
  _oni_version=${VERSION_TOKEN:-${REF_LABEL:-}}
  if [ -z "$_oni_version" ]; then
    _oneh_native_err "No release version available from the installer (VERSION_TOKEN/REF_LABEL unset); refusing to install a native app."
    return 1
  fi
  oneh_install_native_app "$_oni_version"
}

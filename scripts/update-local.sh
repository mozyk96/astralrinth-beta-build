#!/usr/bin/env bash
# update-local.sh — Local updater for AstralRinth Beta on Arch Linux / CachyOS
#
# Purpose:
#   Checks the upstream AstralRinth repository (git.xorison.dev) for updates,
#   builds the optimized native binary for this PC (e.g. x86-64-v3 on Ryzen 5 5600H),
#   and installs it directly to ~/.local/bin/ and ~/.local/share/.
#
#   NO AUR uploads, NO GitHub Releases required, NO credentials or SSH keys needed.
#   Uses local incremental caching for fast rebuilds.
#
# Usage:
#   update-local.sh [OPTIONS]
#
# Options:
#   --check, -c       Check for upstream updates without building or installing
#   --force, -f       Force rebuild and installation even if commit is unchanged
#   --target, -t <T>  Override CPU target: v3 (x86-64-v3), base (x86-64), v4 (x86-64-v4)
#   --status, -s      Show local installation version, upstream status, and CPU ISA
#   --help, -h        Show this help message

set -Eeuo pipefail

# Ensure standard user toolchain paths are present (works smoothly from bash, fish, zsh)
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:$PATH"
export SHARP_IGNORE_GLOBAL_LIBVIPS=1

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$ROOT/state"
mkdir -p "$STATE_DIR"

UPSTREAM_URL='https://git.xorison.dev/didirus/AstralRinth.git'
UPSTREAM_BRANCH='beta'
INSTALLED_STATE_FILE="$STATE_DIR/installed-local-commit.txt"

# Detect best CPU architecture supported by host
detect_cpu_target() {
  if /usr/lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q 'x86-64-v4 (supported'; then
    echo "x86-64-v4"
  elif /usr/lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q 'x86-64-v3 (supported'; then
    echo "x86-64-v3"
  else
    echo "x86-64"
  fi
}

# Parse options
MODE="update"
FORCE=0
TARGET_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|-c)
      MODE="check"
      shift
      ;;
    --force|-f)
      FORCE=1
      shift
      ;;
    --target|-t)
      TARGET_OVERRIDE="$2"
      shift 2
      ;;
    --status|-s)
      MODE="status"
      shift
      ;;
    --help|-h)
      head -n 22 "$0" | tail -n +3 | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1 (run with --help for usage)" >&2
      exit 2
      ;;
  esac
done

TARGET="${TARGET_OVERRIDE:-$(detect_cpu_target)}"
case "$TARGET" in
  v3|x86-64-v3) TARGET="x86-64-v3" ;;
  v4|x86-64-v4) TARGET="x86-64-v4" ;;
  base|x86-64)  TARGET="x86-64" ;;
  *)
    echo "Unsupported target: $TARGET. Choose from: base (x86-64), v3 (x86-64-v3), v4 (x86-64-v4)." >&2
    exit 2
    ;;
esac

# Read currently installed commit
installed_commit=""
if [[ -f "$INSTALLED_STATE_FILE" ]]; then
  installed_commit="$(tr -d '\r\n ' < "$INSTALLED_STATE_FILE")"
elif [[ -f "$STATE_DIR/upstream-commit.txt" ]]; then
  installed_commit="$(tr -d '\r\n ' < "$STATE_DIR/upstream-commit.txt")"
fi

get_upstream_commit() {
  local sha
  sha="$(git ls-remote "$UPSTREAM_URL" "refs/heads/$UPSTREAM_BRANCH" 2>/dev/null | awk '{print $1}')"
  if [[ ! "$sha" =~ ^[0-9a-f]{40,64}$ ]]; then
    echo "ERROR: Unable to contact upstream at $UPSTREAM_URL" >&2
    return 1
  fi
  echo "$sha"
}

if [[ "$MODE" == "status" ]]; then
  echo "=== AstralRinth Local Build Status ==="
  echo "Installed executable: $HOME/.local/bin/AstralRinthApp"
  if [[ -f "$HOME/.local/bin/AstralRinthApp" ]]; then
    echo "Installed size:       $(du -sh "$HOME/.local/bin/AstralRinthApp" | awk '{print $1}')"
  else
    echo "Installed size:       Not installed"
  fi
  echo "Current commit:       ${installed_commit:-not recorded}"
  echo "Detected CPU target:  $TARGET"

  echo -n "Checking upstream...  "
  if upstream_sha="$(get_upstream_commit)"; then
    echo "$upstream_sha (branch: $UPSTREAM_BRANCH)"
    if [[ "$installed_commit" == "$upstream_sha" ]]; then
      echo "Update status:        UP TO DATE"
    else
      echo "Update status:        UPDATE AVAILABLE"
    fi
  else
    echo "Offline / Unreachable"
  fi
  exit 0
fi

echo "==> Checking upstream AstralRinth ($UPSTREAM_URL branch: $UPSTREAM_BRANCH)..."
upstream_sha="$(get_upstream_commit)"
echo "Upstream commit:  $upstream_sha"
echo "Installed commit: ${installed_commit:-<none>}"
echo "Selected target:  $TARGET"

if [[ "$FORCE" -eq 0 && -n "$installed_commit" && "$installed_commit" == "$upstream_sha" && -f "$HOME/.local/bin/AstralRinthApp" ]]; then
  echo "==> AstralRinth is already up to date!"
  echo "    Binary: ~/.local/bin/AstralRinthApp"
  echo "    Tip: Run with '--force' if you want to rebuild anyway."
  exit 0
fi

if [[ "$MODE" == "check" ]]; then
  if [[ "$installed_commit" != "$upstream_sha" ]]; then
    echo "==> UPDATE AVAILABLE: $installed_commit -> $upstream_sha"
    exit 0
  else
    echo "==> Up to date."
    exit 0
  fi
fi

echo "=========================================================="
echo "==> Building AstralRinth ($TARGET) for commit $upstream_sha"
echo "=========================================================="

ARTIFACT_DIR="$ROOT/artifacts" \
REQUESTED_UPSTREAM_SHA="$upstream_sha" \
UPSTREAM_URL="$UPSTREAM_URL" \
BUILD_TARGETS="$TARGET" \
SHARP_IGNORE_GLOBAL_LIBVIPS=1 \
bash "$ROOT/scripts/build-payload.sh"

# Locate the generated payload archive
asset_name="astralrinth-beta-rootfs.tar.zst"
if [[ "$TARGET" == "x86-64-v3" ]]; then
  asset_name="astralrinth-beta-v3-rootfs.tar.zst"
elif [[ "$TARGET" == "x86-64-v4" ]]; then
  asset_name="astralrinth-beta-v4-rootfs.tar.zst"
fi

payload_archive="$ROOT/artifacts/$asset_name"
[[ -f "$payload_archive" ]] || {
  echo "ERROR: Expected built payload not found: $payload_archive" >&2
  exit 1
}

echo "==> Installing $TARGET payload to ~/.local/..."
temp_extract="$(mktemp -d /tmp/astralrinth-extract.XXXXXX)"
trap 'rm -rf "$temp_extract"' EXIT

tar --zstd -xf "$payload_archive" -C "$temp_extract"

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/pixmaps" "$HOME/.local/share/icons"

# Copy binary
install -Dm755 "$temp_extract/usr/bin/AstralRinthApp" "$HOME/.local/bin/AstralRinthApp"

# Compatibility symlinks
ln -sf AstralRinthApp "$HOME/.local/bin/astralrinth"
ln -sf AstralRinthApp "$HOME/.local/bin/astralrinth-beta"

# Desktop integration
if [[ -d "$temp_extract/usr/share" ]]; then
  cp -a "$temp_extract/usr/share/." "$HOME/.local/share/"
fi

# Update desktop and icon caches if tools exist
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

# Record state
printf '%s\n' "$upstream_sha" > "$INSTALLED_STATE_FILE"
printf '%s\n' "$upstream_sha" > "$STATE_DIR/upstream-commit.txt"

echo "==> Running quick verification smoke test..."
smoke_rc=0
timeout 2s "$HOME/.local/bin/AstralRinthApp" >/dev/null 2>&1 || smoke_rc=$?
if [[ "$smoke_rc" -eq 132 ]]; then
  echo "ERROR: Installed binary crashed with SIGILL (illegal instruction)!" >&2
  exit 1
elif [[ "$smoke_rc" -eq 127 ]]; then
  echo "ERROR: Installed binary failed to find required dynamic libraries!" >&2
  exit 1
fi

echo "=========================================================="
echo "==> AstralRinth Beta successfully updated to $upstream_sha!"
echo "    Architecture: $TARGET (optimized)"
echo "    Binary:       $HOME/.local/bin/AstralRinthApp"
echo "    Commands:     astralrinth, astralrinth-beta"
echo "    Launcher:     AstralRinth Beta in application menu"
echo "=========================================================="

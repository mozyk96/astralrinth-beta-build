#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AUR_PACKAGE='astralrinth-beta-bin'
SERVICE_NAME='astralrinth-beta-check'

for cmd in git gh curl python systemctl makepkg; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done
if ! gh auth status >/dev/null 2>&1; then
  echo 'GitHub CLI not authenticated. Run: gh auth login' >&2
  exit 1
fi

[[ -d "$ROOT/.git" ]] || { echo "Run this script inside the cloned GitHub repository, not from an extracted ZIP: $ROOT" >&2; exit 1; }
cd "$ROOT"
REPO_URL="$(git remote get-url origin 2>/dev/null || true)"
case "$REPO_URL" in
  https://github.com/*/*.git|git@github.com:*/*.git) ;;
  *) echo "Origin is not a recognized GitHub URL: ${REPO_URL:-<none>}" >&2; exit 1 ;;
esac
FULL_NAME="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
OWNER="${FULL_NAME%%/*}"
REPO_NAME="${FULL_NAME#*/}"
[[ -n "$OWNER" && -n "$REPO_NAME" && "$OWNER/$REPO_NAME" == "$FULL_NAME" ]] || { echo 'Could not parse GitHub repository name.' >&2; exit 1; }

# If the kit was copied over a configured checkout, rebuild the PKGBUILD template values.
PKGBUILD="$ROOT/aur/PKGBUILD"
if grep -Eq '__GITHUB_OWNER__|__GITHUB_REPO__|__AUR_MAINTAINER_NAME__|__AUR_MAINTAINER_EMAIL__' "$PKGBUILD"; then
  maintainer_name="$(git config user.name || true)"
  maintainer_email="$(git config user.email || true)"
  if [[ -z "$maintainer_name" ]]; then read -r -p 'AUR maintainer name (public package metadata): ' maintainer_name; fi
  if [[ -z "$maintainer_email" ]]; then read -r -p 'AUR maintainer email (public package metadata): ' maintainer_email; fi
  [[ -n "$maintainer_name" && -n "$maintainer_email" ]] || { echo 'Maintainer name and email are required.' >&2; exit 1; }
  python "$ROOT/scripts/configure-template.py" "$PKGBUILD" "$OWNER" "$REPO_NAME" "$maintainer_name" "$maintainer_email"
fi

# Recreate source metadata with makepkg so the AUR file matches PKGBUILD.
(cd "$ROOT/aur" && makepkg --printsrcinfo > .SRCINFO)

# Check local dependencies and offer to install missing Arch packages.
packages=(git curl openssh github-cli jq python rust cmake openssl pkgconf file patchelf libarchive zstd binutils tar util-linux webkit2gtk-4.1 gtk3 libayatana-appindicator librsvg libsoup3 xdg-utils alsa-lib cairo gdk-pixbuf2 glib2 desktop-file-utils)
missing=()
for package in "${packages[@]}"; do
  if ! pacman -Q "$package" >/dev/null 2>&1; then missing+=("$package"); fi
done
if ! command -v mise >/dev/null 2>&1; then missing+=(mise); fi
if ((${#missing[@]})); then
  echo "Missing Arch packages: ${missing[*]}"
  read -r -p 'Install missing packages with sudo pacman now? [Y/n] ' install_answer
  if [[ ! "$install_answer" =~ ^[Nn] ]]; then
    sudo pacman -S --needed "${missing[@]}"
  else
    echo 'Install the listed packages before running the first local build.' >&2
    exit 1
  fi
fi

AUR_KEY_FILE="$HOME/.ssh/astralrinth_beta_aur_ci_ed25519"
AUR_KNOWN_HOSTS_FILE="$HOME/.ssh/astralrinth_beta_aur_known_hosts"
if [[ ! -s "$AUR_KEY_FILE" || ! -s "$AUR_KNOWN_HOSTS_FILE" ]]; then
  echo 'The dedicated AUR SSH key or pinned host keys are missing.' >&2
  echo 'Generate/register a dedicated SSH key in https://aur.archlinux.org/account/ and save the AUR host key.' >&2
  exit 1
fi
chmod 600 "$AUR_KEY_FILE" "$AUR_KNOWN_HOSTS_FILE"

# GitHub Actions is unavailable on this account, so remove the old scheduled workflow.
rm -f "$ROOT/.github/workflows/upstream-beta.yml"
if [[ -d "$ROOT/.github/workflows" ]] && [[ -z "$(find "$ROOT/.github/workflows" -mindepth 1 -print -quit)" ]]; then
  rmdir "$ROOT/.github/workflows" 2>/dev/null || true
fi

# Build the Rust orchestrator and install it outside the repository.
CARGO_TARGET_DIR="$ROOT/target" cargo build --release --manifest-path "$ROOT/Cargo.toml"
install -Dm755 "$ROOT/target/release/astralrinth-publisher" "$HOME/.local/bin/astralrinth-publisher"

# Replace any previous user units with this checkout's absolute path.
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/$SERVICE_NAME.service" <<UNIT
[Unit]
Description=Check, build and publish AstralRinth beta locally
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$ROOT
Environment=PATH=%h/.local/bin:%h/.local/share/mise/shims:%h/.cargo/bin:/usr/local/bin:/usr/bin
Environment=SHARP_IGNORE_GLOBAL_LIBVIPS=1
ExecStart=%h/.local/bin/astralrinth-publisher --root $ROOT
Nice=5
IOSchedulingClass=best-effort
IOSchedulingPriority=6
UNIT
cat > "$UNIT_DIR/$SERVICE_NAME.timer" <<UNIT
[Unit]
Description=Check for AstralRinth beta updates daily

[Timer]
OnBootSec=10min
OnCalendar=daily
Persistent=true
RandomizedDelaySec=5min
Unit=$SERVICE_NAME.service

[Install]
WantedBy=timers.target
UNIT

# Stage only project files; leave unrelated files in the working directory untouched.
git add -A -- .github .gitignore README.uk.md Cargo.toml src aur install.fish install.sh scripts setup.fish setup.sh setup-local.sh setup-local.fish bootstrap.fish bootstrap.sh state
if ! git diff --cached --quiet; then
  git commit -m 'build: publish AstralRinth locally without GitHub Actions'
fi

git fetch origin main
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  if git merge-base --is-ancestor HEAD origin/main; then
    git merge --ff-only origin/main
  elif ! git merge-base --is-ancestor origin/main HEAD; then
    echo 'Local main and origin/main diverged. Refusing to merge or force-push.' >&2
    exit 1
  fi
fi
git push -u origin main

# These secrets belonged only to the now-removed Actions publisher; they are no longer needed remotely.
secret_names="$(gh secret list --repo "$FULL_NAME" --json name --jq '.[].name' 2>/dev/null || true)"
for secret in AUR_SSH_PRIVATE_KEY AUR_SSH_KNOWN_HOSTS; do
  if grep -Fxq "$secret" <<< "$secret_names"; then
    gh secret delete "$secret" --repo "$FULL_NAME" || echo "Warning: could not delete obsolete GitHub secret $secret." >&2
  fi
done

systemctl --user daemon-reload
systemctl --user enable --now "$SERVICE_NAME.timer"
if command -v loginctl >/dev/null 2>&1; then
  if ! loginctl enable-linger "$USER" 2>/dev/null; then
    echo 'Note: could not enable lingering automatically; timer runs while the user manager is active.'
    echo "Optional: sudo loginctl enable-linger $USER"
  fi
fi
echo
echo 'Local build timer is enabled. No GitHub Actions runner or payment method is used.'
echo 'Timer status: systemctl --user status astralrinth-beta-check.timer'
echo 'Service log:  journalctl --user -u astralrinth-beta-check.service -f'
echo "Run manually: ~/.local/bin/astralrinth-publisher --root $ROOT"
echo 'Rust log:     tail -f state/publisher.log'
echo 'The Rust service runs about 10 minutes after boot and once daily. Persistent=true catches a missed daily run after the user manager returns.'
read -r -p 'Run the first check/build now? [Y/n] ' run_now
if [[ ! "$run_now" =~ ^[Nn] ]]; then
  bash "$ROOT/scripts/check-and-publish-local.sh"
fi

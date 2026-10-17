#!/usr/bin/env bash
set -Eeuo pipefail

# Local updater for CachyOS/Arch. It runs only on this machine; no Actions runner or billing needed.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:$PATH"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_URL='https://git.xorison.dev/didirus/AstralRinth.git'
UPSTREAM_BRANCH='beta'
AUR_KEY_FILE="$HOME/.ssh/astralrinth_beta_aur_ci_ed25519"
AUR_KNOWN_HOSTS_FILE="$HOME/.ssh/astralrinth_beta_aur_known_hosts"
LOCK_FILE="$ROOT/state/local-update.lock"

mkdir -p "$ROOT/state"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo 'Another local AstralRinth check/build is already running; skipping this timer tick.'
  exit 0
fi

for cmd in git gh curl jq mise makepkg; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

gh auth status >/dev/null 2>&1 || {
  echo 'GitHub CLI is not logged in. Run: gh auth login' >&2
  exit 1
}

cd "$ROOT"
[[ -d .git ]] || { echo "Not a Git checkout: $ROOT" >&2; exit 1; }
branch="$(git branch --show-current)"
[[ "$branch" == 'main' ]] || {
  echo "Expected branch main, found '$branch'; switch to main before enabling the timer." >&2
  exit 1
}
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Packaging repository has uncommitted changes. Commit or stash them before automated publishing.' >&2
  git status --short >&2
  exit 1
fi

# Pick up recipe/metadata changes that may have been pushed from another terminal.
git fetch --quiet origin main
local_sha="$(git rev-parse HEAD)"
remote_sha="$(git rev-parse origin/main)"
if [[ "$local_sha" != "$remote_sha" ]]; then
  if git merge-base --is-ancestor HEAD origin/main; then
    git merge --ff-only origin/main
  else
    echo 'Local main and origin/main have diverged; refusing to merge or force-push automatically.' >&2
    exit 1
  fi
fi

GH_REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
[[ "$GH_REPOSITORY" == */* ]] || { echo 'Could not determine GitHub owner/repository.' >&2; exit 1; }

upstream_sha="$(git ls-remote "$UPSTREAM_URL" "refs/heads/$UPSTREAM_BRANCH" | awk 'NR == 1 {print $1}')"
[[ "$upstream_sha" =~ ^[0-9a-f]{40,64}$ ]] || {
  echo "Could not read upstream branch '$UPSTREAM_BRANCH' at $UPSTREAM_URL." >&2
  exit 1
}
current_sha="$(tr -d '\r\n' < "$ROOT/state/upstream-commit.txt" 2>/dev/null || true)"
current_tag="$(tr -d '\r\n' < "$ROOT/state/release-tag.txt" 2>/dev/null || true)"
if [[ "$upstream_sha" == "$current_sha" && -n "$current_tag" ]] && gh release view "$current_tag" --repo "$GH_REPOSITORY" >/dev/null 2>&1; then
  local_pkgver="$(sed -n 's/^pkgver=//p' "$ROOT/aur/PKGBUILD" | head -n 1)"
  local_pkgrel="$(sed -n 's/^pkgrel=//p' "$ROOT/aur/PKGBUILD" | head -n 1)"
  expected_aur_version="$local_pkgver-$local_pkgrel"
  aur_info_file="$(mktemp)"
  if ! curl -fsSL -G --data-urlencode 'arg[]=astralrinth-beta-bin' https://aur.archlinux.org/rpc/v5/info -o "$aur_info_file"; then
    rm -f "$aur_info_file"
    echo 'Could not check current AUR status; leaving everything unchanged for a later retry.' >&2
    exit 1
  fi
  aur_result_count="$(jq -r '.resultcount // 0' "$aur_info_file")"
  aur_version="$(jq -r '.results[0].Version // empty' "$aur_info_file")"
  rm -f "$aur_info_file"
  if [[ "$aur_result_count" == '1' && "$aur_version" == "$expected_aur_version" ]]; then
    echo "AstralRinth beta and AUR are current ($upstream_sha / $aur_version); no build needed."
    exit 0
  fi

  echo "GitHub Release is already built, but AUR is missing or outdated (reported: ${aur_version:-not published}). Retrying AUR publication without rebuilding."
  [[ -s "$AUR_KEY_FILE" && -s "$AUR_KNOWN_HOSTS_FILE" ]] || {
    echo 'AUR SSH key or pinned known_hosts file is missing.' >&2
    exit 1
  }
  export GH_TOKEN="$(gh auth token)" GH_REPOSITORY NEEDS_BUILD=false
  export AUR_SSH_PRIVATE_KEY_FILE="$AUR_KEY_FILE"
  export AUR_SSH_KNOWN_HOSTS_FILE="$AUR_KNOWN_HOSTS_FILE"
  export GIT_COMMIT_NAME="$(git config user.name || true)"
  export GIT_COMMIT_EMAIL="$(git config user.email || true)"
  bash "$ROOT/scripts/publish-release.sh"
  exit 0
fi

[[ -s "$AUR_KEY_FILE" ]] || {
  echo "Missing AUR SSH private key: $AUR_KEY_FILE" >&2
  echo 'Re-run fish ./setup.fish, or register a dedicated key in your AUR account.' >&2
  exit 1
}
[[ -s "$AUR_KNOWN_HOSTS_FILE" ]] || {
  echo "Missing pinned AUR known_hosts file: $AUR_KNOWN_HOSTS_FILE" >&2
  exit 1
}

printf 'New AstralRinth beta detected: %s\n' "$upstream_sha"
ARTIFACT_DIR="$ROOT/artifacts" \
REQUESTED_UPSTREAM_SHA="$upstream_sha" \
UPSTREAM_URL="$UPSTREAM_URL" \
bash "$ROOT/scripts/build-payload.sh"

export GH_TOKEN="$(gh auth token)"
export GH_REPOSITORY
export NEEDS_BUILD=true
export AUR_SSH_PRIVATE_KEY_FILE="$AUR_KEY_FILE"
export AUR_SSH_KNOWN_HOSTS_FILE="$AUR_KNOWN_HOSTS_FILE"
export GIT_COMMIT_NAME="$(git config user.name || true)"
export GIT_COMMIT_EMAIL="$(git config user.email || true)"
bash "$ROOT/scripts/publish-release.sh"

echo "Release published. See: https://github.com/$GH_REPOSITORY/releases"
echo 'Timer log: journalctl --user -u astralrinth-beta-check.service'

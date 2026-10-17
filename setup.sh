#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AUR_PACKAGE='astralrinth-beta-bin'
if [[ $# -gt 0 ]]; then
  REPO_NAME="$1"
elif [[ -d "$SCRIPT_DIR/.git" ]]; then
  EXISTING_ORIGIN="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
  case "$EXISTING_ORIGIN" in
    https://github.com/*/*.git) REPO_NAME="${EXISTING_ORIGIN##*/}"; REPO_NAME="${REPO_NAME%.git}" ;;
    git@github.com:*/*.git) REPO_NAME="${EXISTING_ORIGIN##*/}"; REPO_NAME="${REPO_NAME%.git}" ;;
    *) REPO_NAME='astralrinth-beta-build' ;;
  esac
else
  REPO_NAME='astralrinth-beta-build'
fi

if [[ ! "$REPO_NAME" =~ ^[A-Za-z0-9._-]+$ || "$REPO_NAME" =~ ^[.-] || "$REPO_NAME" =~ \.$ ]]; then
  echo 'Repository name may contain only letters, digits, dot, dash, and underscore; it must not start with dot/dash or end with dot.' >&2
  exit 2
fi

for tool in gh git curl ssh-keygen ssh-keyscan makepkg python; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required command: $tool" >&2
    exit 1
  }
done

gh auth status >/dev/null 2>&1 || {
  echo 'GitHub CLI is not authenticated. Run: gh auth login -s repo,workflow' >&2
  exit 1
}
# Ensure the token can create repositories, store Actions secrets and dispatch workflows.
if ! gh auth refresh --hostname github.com -s repo -s workflow; then
  echo 'GitHub authentication needs repo and workflow scopes.' >&2
  echo 'Run: gh auth login -h github.com -s repo -s workflow' >&2
  exit 1
fi
OWNER="$(gh api user --jq .login)"
[[ -n "$OWNER" ]] || { echo 'Could not determine the GitHub username through gh.' >&2; exit 1; }
FULL_NAME="$OWNER/$REPO_NAME"
HTTPS_REMOTE="https://github.com/$FULL_NAME.git"
SSH_REMOTE="git@github.com:$FULL_NAME.git"

REPO_EXISTS=false
if gh repo view "$FULL_NAME" >/dev/null 2>&1; then REPO_EXISTS=true; fi
if [[ -d "$SCRIPT_DIR/.git" ]]; then
  EXISTING_REMOTE="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
  if [[ "$EXISTING_REMOTE" != "$HTTPS_REMOTE" && "$EXISTING_REMOTE" != "$SSH_REMOTE" ]]; then
    echo "This directory is already a Git repository with a different or missing origin: ${EXISTING_REMOTE:-<none>}" >&2
    echo 'Refusing to alter its Git history. Extract a fresh ZIP or fix the origin manually.' >&2
    exit 1
  fi
elif [[ -e "$SCRIPT_DIR/.git" ]]; then
  echo 'The .git path exists but is not a directory; refusing to continue.' >&2
  exit 1
elif [[ "$REPO_EXISTS" == true ]]; then
  echo "GitHub repository $FULL_NAME already exists, but this directory is not its checkout." >&2
  echo 'Refusing to push unrelated history. Choose another repository name or clone/reconcile manually.' >&2
  exit 1
fi

# Verify the package base is free before creating remote resources.
API_FILE="$(mktemp)"
trap 'rm -f "$API_FILE"' EXIT
if ! curl -fsSL -G --data-urlencode "arg[]=$AUR_PACKAGE" https://aur.archlinux.org/rpc/v5/info > "$API_FILE"; then
  echo 'Could not query the AUR API. Check connectivity and retry.' >&2
  exit 1
fi
if grep -Eq '"resultcount"[[:space:]]*:[[:space:]]*[1-9]' "$API_FILE"; then
  # A repeat setup is allowed only when the existing AUR recipe clearly points
  # back to this exact GitHub repo. Never take over an unrelated pkgbase.
  REMOTE_AUR_PKGBUILD="$(curl -fsSL "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=$AUR_PACKAGE" || true)"
  if [[ "$REPO_EXISTS" != true || "$REMOTE_AUR_PKGBUILD" != *"https://github.com/$FULL_NAME"* ]]; then
    echo "The AUR package '$AUR_PACKAGE' already exists and cannot be verified as this project's package." >&2
    echo "Refusing to overwrite or impersonate its maintainer: https://aur.archlinux.org/packages/$AUR_PACKAGE" >&2
    exit 1
  fi
  echo "AUR package already points at https://github.com/$FULL_NAME; treating this as a repeat setup."
fi
rm -f "$API_FILE"
trap - EXIT

MAINTAINER_NAME="$(git config --global user.name || true)"
MAINTAINER_EMAIL="$(git config --global user.email || true)"
if [[ -z "$MAINTAINER_NAME" ]]; then read -r -p 'AUR maintainer name: ' MAINTAINER_NAME; fi
if [[ -z "$MAINTAINER_EMAIL" ]]; then read -r -p 'AUR maintainer email: ' MAINTAINER_EMAIL; fi
[[ -n "$MAINTAINER_NAME" && -n "$MAINTAINER_EMAIL" ]] || {
  echo 'A non-empty maintainer name and email are required for AUR commits.' >&2
  exit 1
}

[[ -f "$SCRIPT_DIR/aur/PKGBUILD" && -f "$SCRIPT_DIR/.github/workflows/upstream-beta.yml" ]] || {
  echo 'Build-kit files are missing. Extract the complete ZIP and rerun setup.fish.' >&2
  exit 1
}
python "$SCRIPT_DIR/scripts/configure-template.py" \
  "$SCRIPT_DIR/aur/PKGBUILD" "$OWNER" "$REPO_NAME" "$MAINTAINER_NAME" "$MAINTAINER_EMAIL"
(
  cd "$SCRIPT_DIR/aur"
  makepkg --printsrcinfo > .SRCINFO
)

# Create a dedicated key just for this public package automation. Never reuse the personal GitHub key.
SSH_DIR="$HOME/.ssh"
AUR_KEY="$SSH_DIR/astralrinth_beta_aur_ci_ed25519"
KNOWN_HOSTS_FILE="$SSH_DIR/astralrinth_beta_aur_known_hosts"
install -d -m 700 "$SSH_DIR"
if [[ ! -f "$AUR_KEY" ]]; then
  ssh-keygen -q -t ed25519 -C "github-actions-$REPO_NAME" -N '' -f "$AUR_KEY"
fi
if [[ ! -f "$AUR_KEY.pub" ]]; then
  ssh-keygen -y -P '' -f "$AUR_KEY" > "$AUR_KEY.pub" || {
    echo "Cannot read $AUR_KEY without a passphrase. Move it aside and rerun setup.fish." >&2
    exit 1
  }
fi
ssh-keygen -y -P '' -f "$AUR_KEY" >/dev/null 2>&1 || {
  echo "The dedicated AUR CI key has a passphrase and cannot be used by this workflow: $AUR_KEY" >&2
  exit 1
}
chmod 600 "$AUR_KEY"

if [[ -s "$KNOWN_HOSTS_FILE" ]]; then
  HOST_KEY_SOURCE='existing pinned key file'
elif [[ -s "$HOME/.ssh/known_hosts" ]] && ssh-keygen -F aur.archlinux.org -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
  ssh-keygen -F aur.archlinux.org -f "$HOME/.ssh/known_hosts" | grep -v '^#' > "$KNOWN_HOSTS_FILE"
  HOST_KEY_SOURCE='pre-existing local known_hosts record'
else
  HOST_KEY_SOURCE='ssh-keyscan (trust-on-first-use; verify fingerprint independently)'
  ssh-keyscan -T 10 -t ed25519 aur.archlinux.org > "$KNOWN_HOSTS_FILE" 2>/dev/null || {
    echo 'Could not retrieve the AUR SSH host key; check connectivity and retry.' >&2
    exit 1
  }
fi
[[ -s "$KNOWN_HOSTS_FILE" ]] || { echo 'AUR known_hosts file is empty.' >&2; exit 1; }
chmod 600 "$KNOWN_HOSTS_FILE"

echo
echo "GitHub repository: https://github.com/$FULL_NAME"
echo 'Visibility: public (required for AUR to download Release assets without a token)'
echo "AUR package base: $AUR_PACKAGE"
read -r -p 'Create/push the pipeline to GitHub now? [y/N] ' ANSWER
[[ "${ANSWER,,}" == y || "${ANSWER,,}" == yes ]] || { echo 'Cancelled before creating or pushing the repository.'; exit 0; }

if [[ "$REPO_EXISTS" != true ]]; then
  gh repo create "$FULL_NAME" --public \
    --description 'Unofficial AstralRinth beta build pipeline for Arch Linux (generic x86-64)'
fi

if [[ ! -d "$SCRIPT_DIR/.git" ]]; then
  git -C "$SCRIPT_DIR" init -b main
  git -C "$SCRIPT_DIR" remote add origin "$HTTPS_REMOTE"
fi
git -C "$SCRIPT_DIR" config user.name "$MAINTAINER_NAME"
git -C "$SCRIPT_DIR" config user.email "$MAINTAINER_EMAIL"
CURRENT_BRANCH="$(git -C "$SCRIPT_DIR" branch --show-current)"
if [[ "$CURRENT_BRANCH" != main ]]; then
  if git -C "$SCRIPT_DIR" show-ref --verify --quiet refs/heads/main; then
    git -C "$SCRIPT_DIR" switch main
  else
    git -C "$SCRIPT_DIR" switch -c main
  fi
fi

gh auth setup-git --hostname github.com
git -C "$SCRIPT_DIR" add -A
if ! git -C "$SCRIPT_DIR" diff --cached --quiet; then
  git -C "$SCRIPT_DIR" commit -m 'chore: bootstrap AstralRinth beta packaging pipeline'
fi
# Fetch the remote before pushing. This makes a repeat run safe if Actions already
# committed updated state/PKGBUILD while the user was adding the AUR SSH key.
git -C "$SCRIPT_DIR" fetch origin main 2>/dev/null || true
if git -C "$SCRIPT_DIR" show-ref --verify --quiet refs/remotes/origin/main; then
  if git -C "$SCRIPT_DIR" merge-base --is-ancestor HEAD origin/main; then
    git -C "$SCRIPT_DIR" merge --ff-only origin/main
  elif ! git -C "$SCRIPT_DIR" merge-base --is-ancestor origin/main HEAD; then
    echo 'Local and GitHub main have diverged. Refusing an automatic merge or force-push.' >&2
    echo 'Clone a fresh copy and reconcile changes manually before running setup again.' >&2
    exit 1
  fi
fi

git -C "$SCRIPT_DIR" push -u origin main || {
  echo 'Git push failed. Nothing was force-pushed; fix the branch/remote issue and rerun this script.' >&2
  exit 1
}

# Use read-only default permissions. The publish job grants contents:write explicitly.
if ! gh api --method PUT "repos/$FULL_NAME/actions/permissions/workflow" \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=false >/dev/null 2>&1; then
  echo 'Warning: could not set Actions default permissions by API; check Settings > Actions > General.' >&2
fi

echo
echo 'Add this PUBLIC SSH key to your AUR account under My Account > SSH Public Keys:'
cat "$AUR_KEY.pub"
echo
echo "AUR SSH host-key fingerprint pinned for Actions ($HOST_KEY_SOURCE):"
ssh-keygen -lf "$KNOWN_HOSTS_FILE" 2>/dev/null || true
echo 'Note: ssh-keyscan is trust-on-first-use; verify this fingerprint independently if possible.'
if command -v xdg-open >/dev/null 2>&1; then xdg-open 'https://aur.archlinux.org/account/' >/dev/null 2>&1 & fi
read -r -p 'Have you registered your PUBLIC key in AUR and reviewed the host-key warning above? [y/N] ' AUR_CONFIRM
if [[ "${AUR_CONFIRM,,}" == y || "${AUR_CONFIRM,,}" == yes ]]; then
  gh secret set AUR_SSH_PRIVATE_KEY --repo "$FULL_NAME" < "$AUR_KEY"
  gh secret set AUR_SSH_KNOWN_HOSTS --repo "$FULL_NAME" < "$KNOWN_HOSTS_FILE"
  gh workflow run upstream-beta.yml --repo "$FULL_NAME" --ref main
  echo
  echo "Repository: https://github.com/$FULL_NAME"
  echo "Actions:    https://github.com/$FULL_NAME/actions"
  echo "AUR package (after a successful run): https://aur.archlinux.org/packages/$AUR_PACKAGE"
else
  echo
  echo 'The GitHub pipeline is pushed, but AUR write secrets were NOT added and the first workflow was not triggered.'
  echo 'After registering the public key, rerun this same command from this directory:'
  echo '  fish ./setup.fish'
  echo 'The script will reuse the repository and key, save the AUR secrets, and start the workflow.'
fi

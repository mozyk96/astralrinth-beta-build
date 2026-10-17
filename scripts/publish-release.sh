#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GH_REPOSITORY:?GH_REPOSITORY is required}"
: "${NEEDS_BUILD:?NEEDS_BUILD is required}"

export GH_TOKEN

if [[ "$NEEDS_BUILD" == 'true' ]]; then
  manifest='artifacts/manifest.json'
  payload='artifacts/astralrinth-beta-rootfs.tar.zst'
  checksum_file='artifacts/astralrinth-beta-rootfs.tar.zst.sha256'
  [[ -s "$manifest" && -s "$payload" && -s "$checksum_file" ]] || {
    echo 'Expected build artifact(s) are missing.' >&2
    exit 1
  }

  pkgver="$(jq -er '.pkgver' "$manifest")"
  tag="$(jq -er '.release_tag' "$manifest")"
  built_sha="$(jq -er '.source_commit' "$manifest")"
  expected_sha256="$(jq -er '.sha256' "$manifest")"
  actual_sha256="$(sha256sum "$payload" | awk '{print $1}')"
  [[ "$expected_sha256" == "$actual_sha256" ]] || {
    echo 'Payload checksum does not match manifest.' >&2
    exit 1
  }
  [[ "$pkgver" =~ ^[0-9][A-Za-z0-9._+]*$ && "$tag" == "v$pkgver" ]] || {
    echo "Unexpected package version/tag in manifest: $pkgver / $tag" >&2
    exit 1
  }

  notes="$(mktemp)"
  trap 'rm -f "$notes"' EXIT
  cat > "$notes" <<NOTES
Unofficial community-built AstralRinth beta package for Arch Linux.

- Upstream branch: beta
- Upstream commit: $built_sha
- Package version: $pkgver
- Architecture: x86_64, generic x86-64 CPU baseline (not native-optimized)
- Asset checksum: SHA-256 $actual_sha256

This is an unofficial repackaging project and is not affiliated with the AstralRinth upstream maintainers.
NOTES

  if gh release view "$tag" --repo "$GH_REPOSITORY" >/dev/null 2>&1; then
    gh release upload "$tag" "$payload" "$checksum_file" "$manifest" --clobber --repo "$GH_REPOSITORY"
  else
    gh release create "$tag" "$payload" "$checksum_file" "$manifest" \
      --title "AstralRinth Beta $pkgver (unofficial Arch payload)" \
      --notes-file "$notes" --prerelease --target main --repo "$GH_REPOSITORY"
  fi

  sed -i -E "s/^pkgver=.*/pkgver=$pkgver/" aur/PKGBUILD
  # Replace both the initial SKIP placeholder and any previously published checksum.
  sed -i -E "s/^sha256sums=.*/sha256sums=('$actual_sha256')/" aur/PKGBUILD
  printf '%s\n' "$built_sha" > state/upstream-commit.txt
  printf '%s\n' "$tag" > state/release-tag.txt
  (cd aur && makepkg --printsrcinfo > .SRCINFO)

  commit_name="${GIT_COMMIT_NAME:-$(git config user.name || true)}"
  commit_email="${GIT_COMMIT_EMAIL:-$(git config user.email || true)}"
  [[ -n "$commit_name" ]] || commit_name='astralrinth-local-builder'
  [[ -n "$commit_email" ]] || commit_email='astralrinth-local-builder@users.noreply.github.com'
  git config user.name "$commit_name"
  git config user.email "$commit_email"
  git add aur/PKGBUILD aur/.SRCINFO state/upstream-commit.txt state/release-tag.txt
  if ! git diff --cached --quiet; then
    git commit -m "ci: publish AstralRinth beta $pkgver"
    gh auth setup-git --hostname github.com
    git push origin HEAD:main
  fi
else
  pkgver="$(sed -n 's/^pkgver=//p' aur/PKGBUILD | head -n 1)"
  tag="$(tr -d '\r\n' < state/release-tag.txt 2>/dev/null || true)"
  if [[ -z "$tag" ]]; then tag="v$pkgver"; fi
  if [[ "$pkgver" == '0.0.0.g0000000000' ]] || ! gh release view "$tag" --repo "$GH_REPOSITORY" >/dev/null 2>&1; then
    echo 'No published release exists yet. The build job should have run; refusing to publish an empty AUR recipe.' >&2
    exit 1
  fi
fi

# AUR publishing uses a dedicated local key, or a secret when invoked from a trusted remote publisher.
if [[ -z "${AUR_SSH_PRIVATE_KEY:-}" && -z "${AUR_SSH_PRIVATE_KEY_FILE:-}" ]]; then
  echo 'No AUR SSH private key supplied; GitHub Release was updated, but AUR push was skipped.' >&2
  exit 1
fi
if [[ -z "${AUR_SSH_KNOWN_HOSTS:-}" && -z "${AUR_SSH_KNOWN_HOSTS_FILE:-}" ]]; then
  echo 'AUR known_hosts is missing; refusing unauthenticated host-key checking.' >&2
  exit 1
fi

ssh_dir="$HOME/.ssh"
install -d -m 700 "$ssh_dir"
if [[ -n "${AUR_SSH_PRIVATE_KEY_FILE:-}" && -n "${AUR_SSH_KNOWN_HOSTS_FILE:-}" ]]; then
  aur_key_file="$AUR_SSH_PRIVATE_KEY_FILE"
  aur_known_hosts_file="$AUR_SSH_KNOWN_HOSTS_FILE"
  [[ -s "$aur_key_file" && -s "$aur_known_hosts_file" ]] || {
    echo 'Local AUR SSH key or pinned known_hosts file is missing.' >&2
    exit 1
  }
else
  aur_key_file="$ssh_dir/aur_astralrinth_beta"
  aur_known_hosts_file="$ssh_dir/known_hosts_aur_astralrinth_beta"
  printf '%s\n' "$AUR_SSH_PRIVATE_KEY" > "$aur_key_file"
  printf '%s\n' "$AUR_SSH_KNOWN_HOSTS" > "$aur_known_hosts_file"
  chmod 600 "$aur_key_file" "$aur_known_hosts_file"
fi
chmod 600 "$aur_key_file" "$aur_known_hosts_file"
export GIT_SSH_COMMAND="ssh -i $aur_key_file -o IdentitiesOnly=yes -o UserKnownHostsFile=$aur_known_hosts_file -o StrictHostKeyChecking=yes"

maintainer_line="$(sed -n 's/^# Maintainer: //p' aur/PKGBUILD | head -n 1)"
maintainer_name="${maintainer_line%% <*}"
maintainer_email="${maintainer_line##*<}"
maintainer_email="${maintainer_email%>}"
[[ -n "$maintainer_name" && -n "$maintainer_email" ]] || {
  echo 'Maintainer name/email could not be read from PKGBUILD.' >&2
  exit 1
}

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/astralrinth-aur.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
repo_dir="$work_dir/aur"
aur_url='ssh://aur@aur.archlinux.org/astralrinth-beta-bin.git'
# Existing package: clone it. New package: initialise a local git repo only after
# confirming through the AUR RPC API that the package base does not exist.
if git clone "$aur_url" "$repo_dir"; then
  :
else
  rpc_file="$work_dir/aur-info.json"
  if ! curl -fsSL -G --data-urlencode 'arg[]=astralrinth-beta-bin' https://aur.archlinux.org/rpc/v5/info -o "$rpc_file"; then
    echo 'Could not verify whether the AUR package exists after clone failed; refusing to push.' >&2
    exit 1
  fi
  if ! jq -e '.resultcount == 0' "$rpc_file" >/dev/null; then
    echo 'AUR clone failed but the package exists; check the SSH key, network, and permissions.' >&2
    exit 1
  fi
  rm -rf -- "$repo_dir"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init --initial-branch=master
  git -C "$repo_dir" remote add origin "$aur_url"
fi

if git -C "$repo_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
  git -C "$repo_dir" fetch origin master
  git -C "$repo_dir" checkout -B master origin/master
else
  git -C "$repo_dir" checkout -B master
fi
cp aur/PKGBUILD aur/.SRCINFO "$repo_dir/"
git -C "$repo_dir" config user.name "$maintainer_name"
git -C "$repo_dir" config user.email "$maintainer_email"
git -C "$repo_dir" add PKGBUILD .SRCINFO
if ! git -C "$repo_dir" diff --cached --quiet; then
  git -C "$repo_dir" commit -m "Update AstralRinth beta to $pkgver"
  git -C "$repo_dir" push -u origin master
  echo "Published AUR package astralrinth-beta-bin ($pkgver)."
else
  echo "AUR package is already up to date ($pkgver)."
fi

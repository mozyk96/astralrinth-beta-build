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

  git config user.name 'github-actions[bot]'
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
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

# Only this trusted publishing job receives the AUR key. The upstream build job never does.
if [[ -z "${AUR_SSH_PRIVATE_KEY:-}" ]]; then
  echo '::warning::AUR_SSH_PRIVATE_KEY is not configured; GitHub Release was updated, but AUR push was skipped.'
  exit 0
fi
if [[ -z "${AUR_SSH_KNOWN_HOSTS:-}" ]]; then
  echo 'AUR_SSH_KNOWN_HOSTS is missing; refusing unauthenticated host-key checking.' >&2
  exit 1
fi

ssh_dir="$HOME/.ssh"
install -d -m 700 "$ssh_dir"
printf '%s\n' "$AUR_SSH_PRIVATE_KEY" > "$ssh_dir/aur_astralrinth_beta"
printf '%s\n' "$AUR_SSH_KNOWN_HOSTS" > "$ssh_dir/known_hosts"
chmod 600 "$ssh_dir/aur_astralrinth_beta" "$ssh_dir/known_hosts"
export GIT_SSH_COMMAND="ssh -i $ssh_dir/aur_astralrinth_beta -o IdentitiesOnly=yes -o UserKnownHostsFile=$ssh_dir/known_hosts -o StrictHostKeyChecking=yes"

maintainer_line="$(sed -n 's/^# Maintainer: //p' aur/PKGBUILD | head -n 1)"
maintainer_name="${maintainer_line%% <*}"
maintainer_email="${maintainer_line##*<}"
maintainer_email="${maintainer_email%>}"
[[ -n "$maintainer_name" && -n "$maintainer_email" ]] || {
  echo 'Maintainer name/email could not be read from PKGBUILD.' >&2
  exit 1
}

work_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/astralrinth-aur.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
repo_dir="$work_dir/aur"
# The AUR supports cloning an empty repository when a package is submitted for the first time.
git -c init.defaultBranch=master clone "ssh://aur@aur.archlinux.org/astralrinth-beta-bin.git" "$repo_dir"

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

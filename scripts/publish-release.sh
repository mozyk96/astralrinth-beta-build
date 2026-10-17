#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GH_REPOSITORY:?GH_REPOSITORY is required}"
: "${NEEDS_BUILD:?NEEDS_BUILD is required}"

export GH_TOKEN

manifest='artifacts/manifest.json'
if [[ "$NEEDS_BUILD" == 'true' ]]; then
  [[ -s "$manifest" ]] || {
    echo "Manifest $manifest is missing." >&2
    exit 1
  }

  pkgver="$(jq -er '.pkgver' "$manifest")"
  tag="$(jq -er '.release_tag' "$manifest")"
  built_sha="$(jq -er '.source_commit' "$manifest")"
  base_sha256="$(jq -er '.sha256' "$manifest")"

  [[ "$pkgver" =~ ^[0-9][A-Za-z0-9._+]*$ && "$tag" == "v$pkgver" ]] || {
    echo "Unexpected package version/tag in manifest: $pkgver / $tag" >&2
    exit 1
  }

  # Verify all target assets listed in manifest
  readarray -t target_keys < <(jq -r '.targets | keys[]' "$manifest")
  upload_files=("$manifest")
  target_notes=""

  for t in "${target_keys[@]}"; do
    asset="$(jq -r ".targets[\"$t\"].asset" "$manifest")"
    expected_sum="$(jq -r ".targets[\"$t\"].sha256" "$manifest")"
    desc="$(jq -r ".targets[\"$t\"].description" "$manifest")"
    asset_path="artifacts/$asset"
    sum_file="artifacts/$asset.sha256"

    [[ -s "$asset_path" && -s "$sum_file" ]] || {
      echo "Expected artifact $asset_path or $sum_file is missing." >&2
      exit 1
    }
    actual_sum="$(sha256sum "$asset_path" | awk '{print $1}')"
    [[ "$expected_sum" == "$actual_sum" ]] || {
      echo "Checksum mismatch for $asset: expected $expected_sum, got $actual_sum" >&2
      exit 1
    }

    upload_files+=("$asset_path" "$sum_file")
    target_notes+="- **$t** ($desc): \`$asset\`\n  SHA-256: \`$actual_sum\`\n"
  done

  notes="$(mktemp)"
  trap 'rm -f "$notes"' EXIT
  cat > "$notes" <<NOTES
Unofficial community-built AstralRinth beta package for Arch Linux / CachyOS.

- Upstream branch: \`beta\`
- Upstream commit: \`$built_sha\`
- Package version: \`$pkgver\`
- Main AUR package: \`astralrinth-beta-bin\` (uses generic x86-64 baseline)

### Compiled Artifacts
$(printf '%b' "$target_notes")

*Note: The AUR package \`astralrinth-beta-bin\` installs the generic x86-64 build for maximum compatibility across all Arch systems. Users with modern processors can optionally download and substitute the \`v3\` (AVX2/FMA) or \`v4\` (AVX-512) payload.*

This is an unofficial repackaging project and is not affiliated with the AstralRinth upstream maintainers.
NOTES

  echo "==> Uploading release assets to GitHub ($tag)..."
  if gh release view "$tag" --repo "$GH_REPOSITORY" >/dev/null 2>&1; then
    gh release upload "$tag" "${upload_files[@]}" --clobber --repo "$GH_REPOSITORY"
  else
    gh release create "$tag" "${upload_files[@]}" \
      --title "AstralRinth Beta $pkgver (multi-target Arch payload)" \
      --notes-file "$notes" --prerelease --target main --repo "$GH_REPOSITORY"
  fi

  # Update AUR metadata in repo
  sed -i -E "s/^pkgver=.*/pkgver=$pkgver/" aur/PKGBUILD
  sed -i -E "s/^sha256sums=.*/sha256sums=('$base_sha256')/" aur/PKGBUILD
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
    echo 'No published release exists yet. Refusing to publish an empty AUR recipe.' >&2
    exit 1
  fi
fi

# AUR publishing configuration
if [[ -z "${AUR_SSH_PRIVATE_KEY:-}" && -z "${AUR_SSH_PRIVATE_KEY_FILE:-}" ]]; then
  echo 'Notice: No AUR SSH private key supplied; GitHub Release was updated, but AUR push was skipped.'
  exit 0
fi
if [[ -z "${AUR_SSH_KNOWN_HOSTS:-}" && -z "${AUR_SSH_KNOWN_HOSTS_FILE:-}" ]]; then
  echo 'Notice: AUR known_hosts is missing; refusing unauthenticated host-key checking.'
  exit 0
fi

ssh_dir="$HOME/.ssh"
install -d -m 700 "$ssh_dir"
if [[ -n "${AUR_SSH_PRIVATE_KEY_FILE:-}" && -n "${AUR_SSH_KNOWN_HOSTS_FILE:-}" ]]; then
  aur_key_file="$AUR_SSH_PRIVATE_KEY_FILE"
  aur_known_hosts_file="$AUR_SSH_KNOWN_HOSTS_FILE"
  [[ -s "$aur_key_file" && -s "$aur_known_hosts_file" ]] || {
    echo 'Local AUR SSH key or pinned known_hosts file is missing.' >&2
    exit 0
  }
else
  aur_key_file="$ssh_dir/aur_astralrinth_beta"
  aur_known_hosts_file="$ssh_dir/known_hosts_aur_astralrinth_beta"
  printf '%s\n' "$AUR_SSH_PRIVATE_KEY" > "$aur_key_file"
  printf '%s\n' "$AUR_SSH_KNOWN_HOSTS" > "$aur_known_hosts_file"
  chmod 600 "$aur_key_file" "$aur_known_hosts_file"
fi
chmod 600 "$aur_key_file" "$aur_known_hosts_file"

# Check AUR SSH authorization beforehand to provide friendly diagnostics instead of a hard crash
echo "==> Verifying AUR SSH key authorization..."
ssh_test_output="$(ssh -i "$aur_key_file" -o IdentitiesOnly=yes -o UserKnownHostsFile="$aur_known_hosts_file" -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -T aur@aur.archlinux.org 2>&1 || true)"
if [[ "$ssh_test_output" == *"Permission denied"* ]]; then
  echo "::warning:: AUR SSH authorization failed (Permission denied)."
  echo "The AUR SSH key is not yet registered in your AUR profile."
  echo "To enable automatic AUR publishing:"
  echo "  1. Copy your public key:"
  echo "     cat ${aur_key_file}.pub"
  echo "  2. Go to https://aur.archlinux.org/account/"
  echo "  3. Paste it into the 'SSH Public Key' field and click Save."
  echo "GitHub Release was published successfully. AUR push skipped until key is added."
  exit 0
fi

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

if git clone "$aur_url" "$repo_dir" 2>/dev/null; then
  :
else
  rpc_file="$work_dir/aur-info.json"
  if ! curl -fsSL -G --data-urlencode 'arg[]=astralrinth-beta-bin' https://aur.archlinux.org/rpc/v5/info -o "$rpc_file"; then
    echo 'Could not verify whether the AUR package exists after clone failed; skipping AUR push.' >&2
    exit 0
  fi
  if ! jq -e '.resultcount == 0' "$rpc_file" >/dev/null; then
    echo 'AUR clone failed but package exists. Check permissions or network.' >&2
    exit 0
  fi
  rm -rf -- "$repo_dir"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init --initial-branch=master
  git -C "$repo_dir" remote add origin "$aur_url"
fi

if git -C "$repo_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
  git -C "$repo_dir" fetch origin master 2>/dev/null || true
  git -C "$repo_dir" checkout -B master origin/master 2>/dev/null || true
else
  git -C "$repo_dir" checkout -B master
fi
cp aur/PKGBUILD aur/.SRCINFO "$repo_dir/"
git -C "$repo_dir" config user.name "$maintainer_name"
git -C "$repo_dir" config user.email "$maintainer_email"
git -C "$repo_dir" add PKGBUILD .SRCINFO
if ! git -C "$repo_dir" diff --cached --quiet; then
  git -C "$repo_dir" commit -m "Update AstralRinth beta to $pkgver"
  if git -C "$repo_dir" push -u origin master; then
    echo "Published AUR package astralrinth-beta-bin ($pkgver)."
  else
    echo "Failed to push to AUR; see errors above."
  fi
else
  echo "AUR package is already up to date ($pkgver)."
fi

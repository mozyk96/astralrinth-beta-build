#!/usr/bin/env bash
set -euo pipefail

package='astralrinth-beta-bin'

if ! command -v pacman >/dev/null 2>&1; then
  echo 'This installer supports Arch Linux and Arch-based distributions only.' >&2
  exit 1
fi

if command -v paru >/dev/null 2>&1; then
  exec paru -S --needed "$package"
elif command -v yay >/dev/null 2>&1; then
  exec yay -S --needed "$package"
elif command -v git >/dev/null 2>&1 && command -v makepkg >/dev/null 2>&1; then
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  if ! git clone "https://aur.archlinux.org/$package.git" "$tmp_dir/$package"; then
    echo "Could not clone AUR package '$package'. It may not be published yet." >&2
    echo 'Check the GitHub Actions workflow and try again after it succeeds.' >&2
    exit 1
  fi
  cd "$tmp_dir/$package"
  makepkg -si
else
  echo 'Install paru or yay, or install git + base-devel, then run this installer again.' >&2
  echo "Manual command: paru -S $package (or yay -S $package)" >&2
  exit 1
fi

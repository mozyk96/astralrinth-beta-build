#!/usr/bin/env bash
set -Eeuo pipefail
KIT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEST="${ASTRALRINTH_REPO_DIR:-$HOME/astralrinth-beta-build}"
REPO='mozyk96/astralrinth-beta-build'
for cmd in gh git rsync; do command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }; done
gh auth status >/dev/null 2>&1 || { echo 'Run gh auth login first.' >&2; exit 1; }
if [[ ! -d "$DEST/.git" ]]; then
  if [[ -e "$DEST" ]]; then echo "Destination exists but is not a Git checkout: $DEST" >&2; exit 1; fi
  gh repo clone "$REPO" "$DEST"
fi
cd "$DEST"
remote="$(git remote get-url origin)"
case "$remote" in *github.com*astralrinth-beta-build*) ;; *) echo "Unexpected origin: $remote" >&2; exit 1;; esac
rsync -av --exclude='.git/' --exclude='LICENSE' --exclude='aur/PKGBUILD' --exclude='aur/.SRCINFO' --exclude='state/upstream-commit.txt' --exclude='state/release-tag.txt' "$KIT_DIR/" "$DEST/"
echo "Build kit copied to $DEST"
exec fish "$DEST/setup.fish"

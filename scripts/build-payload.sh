#!/usr/bin/env bash
set -euo pipefail

: "${REQUESTED_UPSTREAM_SHA:?The checker must pass REQUESTED_UPSTREAM_SHA}"
: "${UPSTREAM_URL:?UPSTREAM_URL is required}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CACHE_ROOT="${BUILD_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/astralrinth-beta-build}"
source_dir="$CACHE_ROOT/AstralRinth"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/astralrinth-build.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
payload_dir="$work_dir/payload"
mkdir -p "$ARTIFACT_DIR" "$payload_dir" "$CACHE_ROOT"

# Reuse the isolated source checkout so pnpm's node_modules and Cargo target cache survive
# between releases. This directory is build-owned; no user project files live here.
if [[ ! -d "$source_dir/.git" ]]; then
  mkdir -p "$source_dir"
  git init -q "$source_dir"
  git -C "$source_dir" remote add origin "$UPSTREAM_URL"
fi
# Discard only changes in the disposable upstream checkout, never the packaging repo.
git -C "$source_dir" reset --hard >/dev/null 2>&1 || true
git -C "$source_dir" clean -fd >/dev/null 2>&1 || true
if ! git -C "$source_dir" fetch --depth=1 origin "$REQUESTED_UPSTREAM_SHA"; then
  git -C "$source_dir" fetch --depth=1 origin beta
fi
if ! git -C "$source_dir" cat-file -e "$REQUESTED_UPSTREAM_SHA^{commit}" 2>/dev/null; then
  # A force-push or rapid upstream update can make the checked revision unavailable in the
  # shallow fetch. Recheck is intentionally explicit rather than silently building another SHA.
  echo "Requested upstream revision $REQUESTED_UPSTREAM_SHA was not fetched." >&2
  echo 'A later scheduled run will retry against the new beta head.' >&2
  exit 1
fi
git -C "$source_dir" checkout --detach "$REQUESTED_UPSTREAM_SHA"
actual_sha="$(git -C "$source_dir" rev-parse HEAD)"
[[ "$actual_sha" == "$REQUESTED_UPSTREAM_SHA" ]]
source_date_epoch="$(git -C "$source_dir" show -s --format=%ct HEAD)"
export SOURCE_DATE_EPOCH="$source_date_epoch"

version="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$source_dir/apps/app-frontend/package.json" | head -n 1)"
if [[ ! "$version" =~ ^[0-9][A-Za-z0-9.+_-]*$ ]]; then
  echo "Could not determine a valid app version from package.json: '$version'" >&2
  exit 1
fi
pkgver="${version//-/_}.g${actual_sha:0:10}"
release_tag="v$pkgver"

# Never compile for the GitHub runner's exact CPU. This is a generic x86-64 baseline.
# Force a portable x86-64 baseline even if the runner or upstream configuration
# injects host-specific compiler flags. Do not use -march=native/-mtune=native.
portable_flags() {
  local input="$1"
  input="$(printf '%s' "$input" | sed -E 's/(^|[[:space:]])-march=[^[:space:]]+/\1/g; s/(^|[[:space:]])-mtune=[^[:space:]]+/\1/g')"
  printf '%s' "$input -O2 -pipe -march=x86-64 -mtune=generic" | xargs
}
export CFLAGS="$(portable_flags "${CFLAGS:-}")"
export CXXFLAGS="$(portable_flags "${CXXFLAGS:-}")"
export RUSTFLAGS='-C target-cpu=x86-64'
unset CARGO_ENCODED_RUSTFLAGS || true
export MISE_YES=1
export MISE_TRUSTED_CONFIG_PATHS="$source_dir"
export CARGO_TARGET_DIR="$source_dir/target"
export CARGO_BUILD_JOBS=4
export TURBO_CONCURRENCY=1
export NODE_OPTIONS='--max-old-space-size=4096'
# Force sharp to use prebuilt portable binaries rather than compiling from source
# against the host's globally-installed libvips (which fails on CachyOS/Arch when node-gyp is absent).
export SHARP_IGNORE_GLOBAL_LIBVIPS=1

cd "$source_dir"

echo "==> Setting up build tools via mise..."
if ! mise install; then
  echo "ERROR: 'mise install' failed in $source_dir." >&2
  exit 1
fi

echo "==> Installing Node.js dependencies via pnpm (frozen lockfile)..."
if ! mise exec -- pnpm install --frozen-lockfile; then
  echo "ERROR: 'pnpm install --frozen-lockfile' failed in $source_dir." >&2
  echo "Build environment diagnostics:" >&2
  echo "  - Node: $(mise exec -- node --version 2>&1 || echo 'unknown')" >&2
  echo "  - pnpm: $(mise exec -- pnpm --version 2>&1 || echo 'unknown')" >&2
  echo "  - SHARP_IGNORE_GLOBAL_LIBVIPS: ${SHARP_IGNORE_GLOBAL_LIBVIPS:-unset}" >&2
  if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists vips-cpp 2>/dev/null; then
    echo "  - Host libvips detected: $(pkg-config --modversion vips-cpp 2>&1)" >&2
  else
    echo "  - Host libvips detected: none" >&2
  fi
  exit 1
fi

echo "==> Building desktop bundle (@modrinth/app)..."
if ! mise exec -- pnpm --filter @modrinth/app build --bundles deb; then
  echo "ERROR: 'pnpm --filter @modrinth/app build --bundles deb' failed." >&2
  exit 1
fi

deb_file="$(find "$source_dir/target/release/bundle/deb" -maxdepth 1 -type f -name '*.deb' -print -quit)"
[[ -n "$deb_file" ]] || {
  echo 'Tauri did not generate a Debian bundle in target/release/bundle/deb.' >&2
  exit 1
}
data_member="$(ar t "$deb_file" | grep -E '^data\.tar\.(zst|xz|gz|bz2)$' | head -n 1 || true)"
[[ -n "$data_member" ]] || {
  echo "Could not locate data.tar.* inside $deb_file" >&2
  exit 1
}
ar p "$deb_file" "$data_member" | bsdtar -xpf - -C "$payload_dir"
python "$PROJECT_ROOT/scripts/normalize-desktop.py" "$payload_dir"
desktop-file-validate "$payload_dir/usr/share/applications/astralrinth-beta.desktop"

# Ship the upstream copyright/licensing notes inside the installed package.
if [[ -f "$source_dir/COPYING.md" ]]; then
  install -Dm644 "$source_dir/COPYING.md" \
    "$payload_dir/usr/share/licenses/astralrinth-beta-bin/COPYING.md"
else
  echo 'Upstream COPYING.md is missing; refusing to publish without the project licensing notice.' >&2
  exit 1
fi

# Package paths must be rooted at usr/ for a normal Arch package.
[[ -d "$payload_dir/usr" ]] || {
  echo 'The extracted Debian payload does not contain usr/.' >&2
  exit 1
}

payload="$ARTIFACT_DIR/astralrinth-beta-rootfs.tar.zst"
tar --zstd --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
  -cf "$payload" -C "$payload_dir" .
sha256="$(sha256sum "$payload" | awk '{print $1}')"
(cd "$ARTIFACT_DIR" && sha256sum astralrinth-beta-rootfs.tar.zst > astralrinth-beta-rootfs.tar.zst.sha256)

python - "$ARTIFACT_DIR/manifest.json" "$actual_sha" "$version" "$pkgver" "$release_tag" "$UPSTREAM_URL" "$sha256" <<'PY'
import json, sys
from pathlib import Path
path, commit, version, pkgver, tag, url, checksum = sys.argv[1:]
Path(path).write_text(json.dumps({
    "upstream": "AstralRinth",
    "branch": "beta",
    "source_url": url,
    "source_commit": commit,
    "source_version": version,
    "pkgver": pkgver,
    "release_tag": tag,
    "architecture": "x86_64",
    "cpu_baseline": "x86-64",
    "rootfs_asset": "astralrinth-beta-rootfs.tar.zst",
    "sha256": checksum,
}, indent=2) + "\n", encoding="utf-8")
PY

printf 'Built AstralRinth beta %s from %s\n' "$pkgver" "$actual_sha"
printf 'Payload: %s (%s bytes)\n' "$payload" "$(stat -c %s "$payload")"
printf 'SHA-256: %s\n' "$sha256"

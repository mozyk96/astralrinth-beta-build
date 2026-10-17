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

mkdir -p "$ARTIFACT_DIR" "$CACHE_ROOT"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"

# Ensure upstream checkout is ready and clean
if [[ ! -d "$source_dir/.git" ]]; then
  mkdir -p "$source_dir"
  git init -q "$source_dir"
  git -C "$source_dir" remote add origin "$UPSTREAM_URL"
fi

# Discard changes only in the disposable upstream checkout, never the packaging repo.
git -C "$source_dir" reset --hard >/dev/null 2>&1 || true
git -C "$source_dir" clean -fd >/dev/null 2>&1 || true

if ! git -C "$source_dir" cat-file -e "$REQUESTED_UPSTREAM_SHA^{commit}" 2>/dev/null; then
  if ! git -C "$source_dir" fetch --depth=1 origin "$REQUESTED_UPSTREAM_SHA"; then
    git -C "$source_dir" fetch --depth=1 origin beta
  fi
fi

if ! git -C "$source_dir" cat-file -e "$REQUESTED_UPSTREAM_SHA^{commit}" 2>/dev/null; then
  echo "Requested upstream revision $REQUESTED_UPSTREAM_SHA was not fetched." >&2
  echo 'A later scheduled run will retry against the new beta head.' >&2
  exit 1
fi

git -C "$source_dir" checkout --detach "$REQUESTED_UPSTREAM_SHA"
actual_sha="$(git -C "$source_dir" rev-parse HEAD)"
[[ "$actual_sha" == "$REQUESTED_UPSTREAM_SHA" ]]
source_date_epoch="$(git -C "$source_dir" show -s --format=%ct HEAD)"
export SOURCE_DATE_EPOCH="$source_date_epoch"

# AstralRinth requires packages/app-lib/.env to compile the backend crate (theseus).
if [[ -f "$source_dir/packages/app-lib/.env.prod" ]]; then
  cp -f "$source_dir/packages/app-lib/.env.prod" "$source_dir/packages/app-lib/.env"
fi

version="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$source_dir/apps/app-frontend/package.json" | head -n 1)"
if [[ ! "$version" =~ ^[0-9][A-Za-z0-9.+_-]*$ ]]; then
  echo "Could not determine a valid app version from package.json: '$version'" >&2
  exit 1
fi
pkgver="${version//-/_}.g${actual_sha:0:10}"
release_tag="v$pkgver"

# Toolchain setup
export MISE_YES=1
export MISE_TRUSTED_CONFIG_PATHS="$source_dir"
export CARGO_BUILD_JOBS=4
export TURBO_CONCURRENCY=1
export NODE_OPTIONS='--max-old-space-size=4096'
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
  exit 1
fi

# Determine targets to build
# Defaults to base (x86-64), v3 (x86-64-v3), and v4 (x86-64-v4)
RAW_TARGETS="${BUILD_TARGETS:-${ASTRALRINTH_TARGETS:-x86-64 x86-64-v3 x86-64-v4}}"
TARGET_LIST=()
for t in $RAW_TARGETS; do
  case "$t" in
    all)
      TARGET_LIST+=("x86-64" "x86-64-v3" "x86-64-v4")
      ;;
    base|x86-64)
      TARGET_LIST+=("x86-64")
      ;;
    v3|x86-64-v3)
      TARGET_LIST+=("x86-64-v3")
      ;;
    v4|x86-64-v4)
      TARGET_LIST+=("x86-64-v4")
      ;;
    *)
      echo "Unknown target: $t. Supported targets: base (x86-64), v3 (x86-64-v3), v4 (x86-64-v4), all" >&2
      exit 1
      ;;
  esac
done

# Deduplicate targets while preserving order
readarray -t TARGETS < <(printf '%s\n' "${TARGET_LIST[@]}" | awk '!seen[$0]++')

echo "==> Selected build targets: ${TARGETS[*]}"

manifest_targets_json="$work_dir/targets.json"
echo "{}" > "$manifest_targets_json"

for t in "${TARGETS[@]}"; do
  echo "=========================================================="
  echo "==> Building target: $t"
  echo "=========================================================="

  case "$t" in
    x86-64)
      t_cflags="-O2 -pipe -march=x86-64 -mtune=generic"
      t_cxxflags="-O2 -pipe -march=x86-64 -mtune=generic"
      t_rustflags="-C target-cpu=x86-64"
      t_asset="astralrinth-beta-rootfs.tar.zst"
      t_desc="x86-64 baseline (universal Arch/CachyOS compatibility)"
      ;;
    x86-64-v3)
      t_cflags="-O2 -pipe -march=x86-64-v3"
      t_cxxflags="-O2 -pipe -march=x86-64-v3"
      t_rustflags="-C target-cpu=x86-64-v3"
      t_asset="astralrinth-beta-v3-rootfs.tar.zst"
      t_desc="x86-64-v3 optimized (AVX2, FMA, BMI1/2)"
      ;;
    x86-64-v4)
      t_cflags="-O2 -pipe -march=x86-64-v4"
      t_cxxflags="-O2 -pipe -march=x86-64-v4"
      t_rustflags="-C target-cpu=x86-64-v4"
      t_asset="astralrinth-beta-v4-rootfs.tar.zst"
      t_desc="x86-64-v4 optimized (AVX-512)"
      ;;
  esac

  # Isolated Cargo target directory per CPU target
  target_cargo_dir="$CACHE_ROOT/cargo-target-$t"
  mkdir -p "$target_cargo_dir"
  ln -sfn "$target_cargo_dir" "$source_dir/target"

  export CFLAGS="$t_cflags"
  export CXXFLAGS="$t_cxxflags"
  export CARGO_TARGET_DIR="$source_dir/target"
  unset CARGO_ENCODED_RUSTFLAGS CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS || true

  # For x86-64-v4: proc macros and build scripts are compiled for the HOST and EXECUTED on
  # the host CPU. If the host lacks AVX-512, passing -C target-cpu=x86-64-v4 via RUSTFLAGS
  # causes those host-executed artifacts (.so proc macros) to crash with SIGILL.
  # Solution: pass `--target x86_64-unknown-linux-gnu` to Tauri/Cargo and configure
  # CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS. Cargo then isolates host tools
  # (build scripts, proc macros, and syn/quote) with host flags, while applying v4
  # optimizations exclusively to target crates and final binaries.
  extra_build_args=()
  if [[ "$t" == "x86-64-v4" ]]; then
    unset RUSTFLAGS || true
    export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS="$t_rustflags"
    extra_build_args=("--target" "x86_64-unknown-linux-gnu")
  else
    export RUSTFLAGS="$t_rustflags"
    unset CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS || true
  fi
  unset RUSTC_WRAPPER V4_WRAPPER_TARGET_CPU || true

  # Clean only bundle packaging output from previous runs, keeping compiled object caches for incremental builds
  rm -rf "$source_dir/target/release/bundle" "$source_dir/target/x86_64-unknown-linux-gnu/release/bundle"

  echo "==> Compiling desktop bundle (@modrinth/app) for $t..."
  if ! mise exec -- pnpm --filter @modrinth/app build "${extra_build_args[@]}" --bundles deb; then
    echo "ERROR: 'pnpm --filter @modrinth/app build' failed for target $t." >&2
    exit 1
  fi

  deb_file="$(find "$target_cargo_dir" -type f -name '*.deb' -print -quit)"
  [[ -n "$deb_file" ]] || {
    echo "Tauri did not generate a Debian bundle in $target_cargo_dir." >&2
    exit 1
  }

  payload_dir="$work_dir/payload-$t"
  rm -rf "$payload_dir"
  mkdir -p "$payload_dir"

  data_member="$(ar t "$deb_file" | grep -E '^data\.tar\.(zst|xz|gz|bz2)$' | head -n 1 || true)"
  [[ -n "$data_member" ]] || {
    echo "Could not locate data.tar.* inside $deb_file" >&2
    exit 1
  }
  ar p "$deb_file" "$data_member" | bsdtar -xpf - -C "$payload_dir"
  python "$PROJECT_ROOT/scripts/normalize-desktop.py" "$payload_dir"
  desktop-file-validate "$payload_dir/usr/share/applications/astralrinth-beta.desktop"

  if [[ -f "$source_dir/COPYING.md" ]]; then
    install -Dm644 "$source_dir/COPYING.md" \
      "$payload_dir/usr/share/licenses/astralrinth-beta-bin/COPYING.md"
  else
    echo 'Upstream COPYING.md is missing; refusing to package without license.' >&2
    exit 1
  fi

  [[ -d "$payload_dir/usr" ]] || {
    echo "The extracted Debian payload for $t does not contain usr/." >&2
    exit 1
  }

  binary="$payload_dir/usr/bin/AstralRinthApp"
  [[ -x "$binary" ]] || {
    echo "Main executable $binary not found or not executable." >&2
    exit 1
  }

  echo "==> Verifying dynamic dependencies for $t..."
  if ldd "$binary" 2>&1 | grep -i 'not found'; then
    echo "ERROR: Unresolved shared libraries detected in $binary" >&2
    exit 1
  fi

  echo "==> Running automated verification for $t..."
  can_execute=false
  if [[ "$t" == "x86-64" ]]; then
    can_execute=true
  elif [[ "$t" == "x86-64-v3" ]]; then
    if /usr/lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q "x86-64-v3 (supported"; then
      can_execute=true
    fi
  elif [[ "$t" == "x86-64-v4" ]]; then
    if /usr/lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q "x86-64-v4 (supported"; then
      can_execute=true
    fi
  fi

  if [[ "$can_execute" == "true" ]]; then
    echo "Host CPU supports $t ISA; running smoke test with timeout..."
    smoke_rc=0
    timeout 2s "$binary" >/dev/null 2>&1 || smoke_rc=$?
    if [[ "$smoke_rc" -eq 132 ]]; then
      echo "ERROR: Binary crashed with SIGILL (illegal instruction) on host CPU!" >&2
      exit 1
    elif [[ "$smoke_rc" -eq 127 ]]; then
      echo "ERROR: Binary failed to load or start (exit code 127)!" >&2
      exit 1
    else
      echo "Smoke test passed: binary started cleanly without SIGILL (exit code: $smoke_rc)."
    fi
  else
    echo "Host CPU does not support $t ISA; skipping execution smoke test."
    echo "Verifying ELF headers and binary architecture..."
    readelf -h "$binary" | grep -q "Advanced Micro Devices X86-64" || {
      echo "ERROR: Invalid ELF header in $binary" >&2
      exit 1
    }
    echo "ELF headers valid for $t."
  fi

  out_payload="$ARTIFACT_DIR/$t_asset"
  tar --zstd --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
    -cf "$out_payload" -C "$payload_dir" .
  sha256="$(sha256sum "$out_payload" | awk '{print $1}')"
  (cd "$ARTIFACT_DIR" && sha256sum "$t_asset" > "$t_asset.sha256")

  python - "$manifest_targets_json" "$t" "$t_asset" "$sha256" "$t_desc" "$t_cflags" "$t_rustflags" <<'PY'
import json, sys
from pathlib import Path
path, t_name, asset, checksum, desc, cflags, rustflags = sys.argv[1:]
p = Path(path)
data = json.loads(p.read_text(encoding="utf-8")) if p.is_file() else {}
data[t_name] = {
    "asset": asset,
    "sha256": checksum,
    "description": desc,
    "cflags": cflags,
    "rustflags": rustflags,
}
p.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY

  printf 'Target %s successfully built and validated.\n' "$t"
  printf '  Asset:   %s (%s bytes)\n' "$out_payload" "$(stat -c %s "$out_payload")"
  printf '  SHA-256: %s\n' "$sha256"
done

# Generate consolidated manifest
base_sha256=""
if [[ -f "$ARTIFACT_DIR/astralrinth-beta-rootfs.tar.zst.sha256" ]]; then
  base_sha256="$(awk '{print $1}' "$ARTIFACT_DIR/astralrinth-beta-rootfs.tar.zst.sha256")"
fi

python - "$ARTIFACT_DIR/manifest.json" "$manifest_targets_json" "$actual_sha" "$version" "$pkgver" "$release_tag" "$UPSTREAM_URL" "$base_sha256" <<'PY'
import json, sys
from pathlib import Path
manifest_path, targets_json_path, commit, version, pkgver, tag, url, base_checksum = sys.argv[1:]
new_targets = json.loads(Path(targets_json_path).read_text(encoding="utf-8"))
p_manifest = Path(manifest_path)
existing_targets = {}
if p_manifest.is_file():
    try:
        existing_targets = json.loads(p_manifest.read_text(encoding="utf-8")).get("targets", {})
    except Exception:
        pass
targets = {**existing_targets, **new_targets}
manifest = {
    "upstream": "AstralRinth",
    "branch": "beta",
    "source_url": url,
    "source_commit": commit,
    "source_version": version,
    "pkgver": pkgver,
    "release_tag": tag,
    "architecture": "x86_64",
    "targets": targets,
    "rootfs_asset": "astralrinth-beta-rootfs.tar.zst",
    "sha256": base_checksum or (targets.get("x86-64", {}).get("sha256", "")),
}
Path(manifest_path).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY

echo "==> Build completed successfully for all targets."

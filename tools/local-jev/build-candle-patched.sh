#!/usr/bin/env bash
set -euo pipefail

tools_dir="$(cd "$(dirname "$0")" && pwd)"
crate="$(cd "$tools_dir/../../native/local-jev" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Resolve the exact Candle version from the existing lockfile.
cargo fetch --locked --manifest-path "$crate/Cargo.toml"
candle_dir="$(
  cargo metadata --locked --offline --format-version 1 --manifest-path "$crate/Cargo.toml" |
    python3 -c 'import json, pathlib, sys
packages = json.load(sys.stdin)["packages"]
paths = [pathlib.Path(p["manifest_path"]).parent for p in packages
         if p["name"] == "candle-core" and p["version"] == "0.9.2"]
if len(paths) != 1:
    sys.exit("Expected one locked candle-core 0.9.2")
print(paths[0])'
)"

scratch_crate="$scratch/native/local-jev"
mkdir -p "$scratch_crate" "$scratch/tools"
ln -s "$tools_dir/../vera-playground" "$scratch/tools/vera-playground"
cp "$crate/"{Cargo.lock,Cargo.toml,build.rs} "$scratch_crate/"
cp -R "$crate/src" "$scratch_crate/"
cp -R "$candle_dir" "$scratch/candle-core"
patch -s -d "$scratch/candle-core" -p1 < "$tools_dir/candle-row-scheduling.patch"

config="patch.crates-io.candle-core.path='$scratch/candle-core'"
export CARGO_TARGET_DIR="$crate/target/candle-scheduling"
cd "$scratch_crate"
cargo update --offline --config "$config" -p candle-core
python3 - "$crate/Cargo.lock" Cargo.lock <<'PY'
from pathlib import Path
import re
import sys

original, local = (Path(file).read_text() for file in sys.argv[1:])
registry_source = r'(name = "candle-core"\nversion = "0\.9\.2"\n)source = [^\n]*\nchecksum = [^\n]*\n'
expected, removed = re.subn(registry_source, r'\1', original, count=1)
if removed != 1 or expected != local:
    sys.exit("Dependency resolution changed beyond the local Candle source")
PY

if [ "$#" -eq 0 ]; then
    set -- --bin local-laya
fi
cargo build --locked --offline --release --config "$config" "$@"
printf 'Patched build output is under %s\n' "$CARGO_TARGET_DIR"

#!/usr/bin/env bash
# Capture Rust golden outputs for parity testing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$ROOT/target/release/seaforge_v2"
GOLDEN="$ROOT/parity/golden"
CASES="$ROOT/parity/cases"

mkdir -p "$GOLDEN" "$CASES"

if [[ ! -x "$BINARY" ]]; then
  echo "Building Rust binary..."
  (cd "$ROOT" && cargo build --release)
fi

echo "Capturing golden outputs from Rust..."

# Example simulations
"$BINARY" simulate-params "$ROOT/examples/simulation_params.json" "$GOLDEN/simulation_params.json"
"$BINARY" simulate "$ROOT/examples/vessel_config.json" "$ROOT/examples/voyage_route.json" "$GOLDEN/vessel_route.json"
"$BINARY" optimize "$ROOT/examples/search_space.json" "$ROOT/examples/voyage_route.json" "$GOLDEN/optimize.json"
"$BINARY" demo "$GOLDEN/demo.json"

# Mission briefs x tiers
TIERS=(lowest standard premium cheapest)
for brief in "$ROOT"/mission-briefs/*.json; do
  id=$(basename "$brief" .json)
  for tier in "${TIERS[@]}"; do
    out="$GOLDEN/brief_${id}_${tier}.json"
    echo "  brief $id tier=$tier"
    "$BINARY" brief "$brief" "$out" "--tier=$tier" || echo "WARN: brief $id tier=$tier failed"
  done
done

echo "Golden outputs captured in $GOLDEN"

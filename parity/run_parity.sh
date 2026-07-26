#!/usr/bin/env bash
# Differential parity harness: compare Jac vs Rust simulation envelopes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST_BIN="$ROOT/target/release/seaforge_v2"
GOLDEN="$ROOT/parity/golden"
TOLERANCE="${PARITY_TOLERANCE:-1e-9}"
FAILURES=0
PASSED=0

export PATH="$HOME/.local/bin:$PATH"

compare_json() {
  local rust_file="$1"
  local jac_file="$2"
  local label="$3"

  if [[ ! -f "$rust_file" ]]; then
    echo "SKIP $label: no rust golden"
    return 0
  fi
  if [[ ! -f "$jac_file" ]]; then
    echo "FAIL $label: jac output missing"
    FAILURES=$((FAILURES + 1))
    return 1
  fi

  python3 - "$rust_file" "$jac_file" "$TOLERANCE" "$label" <<'PY'
import json, math, sys

rust_path, jac_path, tol_s, label = sys.argv[1:5]
tol = float(tol_s)

def load(p):
    with open(p) as f:
        return json.load(f)

def compare(a, b, path="$"):
    if type(a) != type(b):
        print(f"FAIL {label}: type mismatch at {path}: {type(a).__name__} vs {type(b).__name__}")
        return False
    if isinstance(a, dict):
        keys_a, keys_b = set(a), set(b)
        if keys_a != keys_b:
            print(f"FAIL {label}: key mismatch at {path}: extra rust={keys_a-keys_b} extra jac={keys_b-keys_a}")
            return False
        return all(compare(a[k], b[k], f"{path}.{k}") for k in a)
    if isinstance(a, list):
        if len(a) != len(b):
            print(f"FAIL {label}: list length at {path}: {len(a)} vs {len(b)}")
            return False
        return all(compare(a[i], b[i], f"{path}[{i}]") for i in range(len(a)))
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        if isinstance(a, float) or isinstance(b, float):
            af, bf = float(a), float(b)
            if math.isinf(af) and math.isinf(bf):
                return (af > 0) == (bf > 0)
            if math.isnan(af) and math.isnan(bf):
                return True
            denom = max(abs(af), abs(bf), 1e-30)
            if abs(af - bf) / denom > tol:
                print(f"FAIL {label}: float drift at {path}: {af} vs {bf} (rel={abs(af-bf)/denom:.2e})")
                return False
            return True
        if a != b:
            print(f"FAIL {label}: int mismatch at {path}: {a} vs {b}")
            return False
        return True
    if a != b:
        print(f"FAIL {label}: value mismatch at {path}: {a!r} vs {b!r}")
        return False
    return True

rust = load(rust_path)
jac = load(jac_path)
ok = compare(rust, jac)
sys.exit(0 if ok else 1)
PY
}

run_case() {
  local label="$1"
  local cmd_type="$2"
  local input="$3"
  local extra="${4:-}"
  local rust_out="/tmp/seaforge_parity_rust_${label}.json"
  local jac_out="/tmp/seaforge_parity_jac_${label}.json"
  local golden="$GOLDEN/${label}.json"

  echo "--- $label ---"

  case "$cmd_type" in
    simulate-params)
      "$RUST_BIN" simulate-params "$input" "$rust_out"
      jac run "$ROOT/parity/run_jac_sim.jac" -- "$input" "$jac_out" 2>/dev/null || true
      ;;
    simulate)
      local route="$extra"
      "$RUST_BIN" simulate "$input" "$route" "$rust_out"
      ;;
    brief)
      local tier="$extra"
      "$RUST_BIN" brief "$input" "$rust_out" "--tier=$tier"
      ;;
    optimize)
      local route="$extra"
      "$RUST_BIN" optimize "$input" "$route" "$rust_out"
      ;;
    demo)
      "$RUST_BIN" demo "$rust_out"
      ;;
  esac

  if [[ -f "$golden" ]]; then
    if compare_json "$golden" "$rust_out" "${label}_rust_regression"; then
      echo "  rust golden OK"
    else
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  if [[ -f "$jac_out" ]] && compare_json "$rust_out" "$jac_out" "$label"; then
    echo "PASS $label"
    PASSED=$((PASSED + 1))
  else
    echo "PENDING $label (jac not ready or mismatch)"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "=== SeaForge Parity Harness ==="
echo "Tolerance: $TOLERANCE"
echo ""

# Run against golden files if jac outputs exist
for golden in "$GOLDEN"/*.json; do
  [[ -f "$golden" ]] || continue
  name=$(basename "$golden" .json)
  jac_out="/tmp/seaforge_parity_jac_${name}.json"
  if [[ -f "$jac_out" ]]; then
    if compare_json "$golden" "$jac_out" "$name"; then
      echo "PASS $name (vs golden)"
      PASSED=$((PASSED + 1))
    else
      FAILURES=$((FAILURES + 1))
    fi
  fi
done

echo ""
echo "=== Summary: $PASSED passed, $FAILURES failed/pending ==="
[[ $FAILURES -eq 0 ]]

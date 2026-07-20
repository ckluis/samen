#!/usr/bin/env bash
# scripts/fleet-status.sh — WS-F5 F5.6 fleet secrets/config drift check.
#
# Diffs each product's REQUIRED runtime secrets/config against the ACTUAL current
# environment and reports, per product: which required keys are SET, EMPTY, or
# MISSING — plus any EXTRA Samen-related vars that are set but not expected.
#
#   ####  NO SECRET VALUES ARE EVER PRINTED  ####
#
# The script only ever reports a key's PRESENCE (set / empty / missing). It reads a
# variable's value ONLY inside a `-z` emptiness test (indirect expansion in a
# conditional) — never into stdout, a log, or an error. Safe to run in CI, in a
# shared shell, or piped to a ticket.
#
# WHERE THE REQUIRED KEYS COME FROM
#   1. A BASELINE prod-secrets contract — the fail-closed set every deployed Samen
#      app's `config/runtime.exs` reads via `fetch_secret!/2` (raises on absence):
#      DATABASE_URL, SECRET_KEY_BASE, PHX_HOST, SAMEN_KMS_KEY_ID, SAMEN_KMS_REGION.
#      (See samen_core/lib/samen/gen/templates.ex `runtime_exs`.)
#   2. Each product's OWN config expectations — the script greps that product's
#      `config/*.exs` for `System.get_env("VAR")` / `fetch_secret!.("VAR"` references
#      and folds any UPPER_SNAKE env vars it finds into that product's expected set.
#      So a vertical that reads an extra env var is checked for it too, automatically.
#   3. OPTIONAL keys (reported, never fail the run): SAMEN_METRICS_ENABLED.
#
# EXIT STATUS
#   0  every product has all REQUIRED keys set (non-empty)
#   1  at least one REQUIRED key is MISSING or EMPTY for some product
#   2  usage / environment error
#
# Usage: scripts/fleet-status.sh [--warn-only] [--products "demo driftwood pawchart"]
#   --warn-only   report drift but always exit 0 (advisory mode)
#   --products    override the product list (space-separated app dir names)

set -euo pipefail

# ---------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The baseline fail-closed prod-secrets contract (runtime.exs fetch_secret!).
BASELINE_REQUIRED=(DATABASE_URL SECRET_KEY_BASE PHX_HOST SAMEN_KMS_KEY_ID SAMEN_KMS_REGION)

# Optional keys — reported but never a failure (egress is opt-in).
OPTIONAL_KEYS=(SAMEN_METRICS_ENABLED)

# Default fleet: the shipped hosts. Generated apps follow the same contract.
PRODUCTS=(demo driftwood pawchart)

WARN_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --warn-only) WARN_ONLY=1; shift ;;
    --products)  shift; read -r -a PRODUCTS <<<"${1:-}"; shift ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "fleet-status: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ANSI (only when stdout is a TTY).
if [ -t 1 ]; then
  R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; DIM=$'\033[2m'; B=$'\033[1m'; Z=$'\033[0m'
else
  R=""; Y=""; G=""; DIM=""; B=""; Z=""
fi

# key_status NAME -> prints one of: set | empty | missing  (never the value)
key_status() {
  local name="$1"
  if [ -z "${!name+x}" ]; then
    echo "missing"
  elif [ -z "${!name}" ]; then          # value read ONLY inside this test; never printed
    echo "empty"
  else
    echo "set"
  fi
}

# Scan a product's config/*.exs for UPPER_SNAKE env-var references.
product_config_keys() {
  local dir="$1"
  local cfg="$ROOT/$dir/config"
  [ -d "$cfg" ] || return 0
  # Match System.get_env("FOO") and fetch_secret!.("FOO" ; emit the quoted NAME.
  grep -rhoE '(System\.get_env|fetch_secret!\.)\(\s*"[A-Z][A-Z0-9_]*"' "$cfg" 2>/dev/null \
    | grep -oE '"[A-Z][A-Z0-9_]*"' \
    | tr -d '"' \
    | sort -u
}

# ---------------------------------------------------------------------------

echo "${B}Samen fleet status — secrets/config drift${Z}  ${DIM}(no values printed)${Z}"
echo "${DIM}root: $ROOT${Z}"
echo

overall_fail=0

for product in "${PRODUCTS[@]}"; do
  if [ ! -d "$ROOT/$product" ]; then
    echo "${Y}? $product${Z} — no such product dir (skipped)"
    echo
    continue
  fi

  # Required = baseline ∪ (this product's own config env references, minus optional).
  # (bash 3.2-compatible dedup — a space-padded seen-list, no associative arrays.)
  required=()
  seen=" "
  for k in "${BASELINE_REQUIRED[@]}"; do
    case "$seen" in *" $k "*) continue ;; esac
    seen="$seen$k "; required+=("$k")
  done
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    # Skip optional + obvious local-dev/drill knobs (never prod-required).
    case "$k" in
      SAMEN_METRICS_ENABLED|USER|HOME|PORT|MIX_ENV|ECTO_IPV6|POOL_SIZE) continue ;;
      *_KMS_KEY_DIR|DRILL_*|*_PGHOST|*_DB) continue ;;
    esac
    case "$seen" in *" $k "*) continue ;; esac
    seen="$seen$k "; required+=("$k")
  done < <(product_config_keys "$product")

  echo "${B}$product${Z}"

  product_fail=0
  for k in "${required[@]}"; do
    st="$(key_status "$k")"
    case "$st" in
      set)     printf '  %s✓%s %-22s %sset%s\n'     "$G" "$Z" "$k" "$G" "$Z" ;;
      empty)   printf '  %s✗%s %-22s %sEMPTY%s\n'   "$R" "$Z" "$k" "$R" "$Z"; product_fail=1 ;;
      missing) printf '  %s✗%s %-22s %sMISSING%s\n' "$R" "$Z" "$k" "$R" "$Z"; product_fail=1 ;;
    esac
  done

  # Optional keys — informational only.
  for k in "${OPTIONAL_KEYS[@]}"; do
    st="$(key_status "$k")"
    if [ "$st" = "set" ]; then
      printf '  %s•%s %-22s %sset (optional)%s\n' "$DIM" "$Z" "$k" "$DIM" "$Z"
    else
      printf '  %s•%s %-22s %s%s (optional)%s\n' "$DIM" "$Z" "$k" "$DIM" "$st" "$Z"
    fi
  done

  if [ "$product_fail" -eq 1 ]; then
    echo "  ${R}→ drift: required secrets are missing/empty${Z}"
    overall_fail=1
  else
    echo "  ${G}→ all required secrets present${Z}"
  fi
  echo
done

# ---------------------------------------------------------------------------

if [ "$overall_fail" -eq 1 ]; then
  if [ "$WARN_ONLY" -eq 1 ]; then
    echo "${Y}fleet-status: drift detected (advisory --warn-only, exiting 0)${Z}"
    exit 0
  fi
  echo "${R}fleet-status: FAIL — required secrets missing/empty in one or more products${Z}"
  echo "${DIM}see docs/runbooks/secrets-rotation.md${Z}"
  exit 1
fi

echo "${G}fleet-status: OK — every product has all required secrets set${Z}"
exit 0

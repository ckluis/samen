#!/usr/bin/env bash
# scripts/mutation_lint.sh — fast preflight for the mutation gate's two committed
# data files (ADR-049). Milliseconds: no test run, no database, no mutation applied.
#
# `scripts/mutate.sh` calls this FIRST and aborts if it fails, for the same reason
# `scripts/sabotage.sh` calls `sabotage_lint.sh` first: a malformed row in the
# watch-list or the ledger is a LATENT bug that would otherwise be discovered (or
# silently swallowed) somewhere in the middle of a long run.
#
# WHAT IT REFUSES, and why each one is a way the gate could go quietly vacuous:
#
#   targets.tsv
#     · a row that is not exactly 3 tab-separated fields
#     · a target file that does not exist, or does not parse
#     · an app directory that does not exist
#     · an owning test file that does not exist — the single most dangerous typo
#       here, because `mix test <missing file>` fails, which the harness would read
#       as "the baseline is red" (loud) or, worse, a runner that skips it reads as
#       a pass over zero tests (silent)
#     · a target with ZERO mutation sites. A file that cannot be mutated certifies
#       nothing, so its presence inflates the target count while proving nothing;
#       either it has no mutable logic (drop the row) or the engine cannot see it.
#     · a duplicate target row
#
#   `# MUTATION_OWNS:` declarations (test files claiming ownership of a lib
#   file the gate cannot back-reference — scripts/mutation/mutate.exs, issue #20)
#     · a declared path that does not exist — a typo there owns nothing, so the
#       proof the author wired up silently drops out of the gate again
#     · a declaration outside a `*_test.exs` file — the gate only scans test
#       files, so the claim would be read by nobody
#
#   ledger.tsv  (the exemption file — the one place the gate can be told "this
#               survivor is acceptable", so it gets the strictest checks)
#     · a row that is not exactly 7 tab-separated fields
#     · a class that is not EQUIVALENT or ACCEPTED_GAP
#     · a reason under 20 characters — "n/a", "later", "known" are not reasons
#     · an ACCEPTED_GAP with no `ref=` — a deliberate hole must name the ADR or
#       backlog item that owns it, or it is not deferred, it is forgotten
#     · a duplicate key
#     · a STALE row: one whose (relpath, line_sha12, col, family, from>to) matches
#       no live mutation site. Because line_sha12 hashes the EXACT source line the
#       exemption excuses, editing that line expires the exemption here. This is
#       what makes the ledger safe to have at all: an exemption cannot outlive the
#       code it was written about.
#
# Usage: scripts/mutation_lint.sh [--targets <file>] [--ledger <file>]
# Exit:  0 all clean · 1 one or more refusals · 2 usage
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO_ROOT/scripts/mutation/mutate.exs"
TARGETS_FILE="$REPO_ROOT/scripts/mutation/targets.tsv"
LEDGER_FILE="$REPO_ROOT/scripts/mutation/ledger.tsv"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/samen_mutation_lint.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --targets) shift; [[ $# -gt 0 ]] || { echo "mutation_lint.sh: --targets requires a file" >&2; exit 2; }
               TARGETS_FILE="$1"; shift ;;
    --ledger)  shift; [[ $# -gt 0 ]] || { echo "mutation_lint.sh: --ledger requires a file" >&2; exit 2; }
               LEDGER_FILE="$1"; shift ;;
    *) echo "mutation_lint.sh: unknown flag: $1" >&2; exit 2 ;;
  esac
done

bad=0
refuse() { echo "MUTATION LINT: $1"; bad=$((bad + 1)); }

data_rows() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -v '^[[:space:]]*$'; }

# ── targets.tsv ──────────────────────────────────────────────────────────────
[[ -f "$TARGETS_FILE" ]] || { echo "MUTATION LINT: FAILED — no targets file at $TARGETS_FILE"; exit 1; }

targets_total=0
SITES_CACHE="$WORK/sites_all"
: > "$SITES_CACHE"
SEEN_TARGETS="$WORK/seen_targets"
: > "$SEEN_TARGETS"

while IFS= read -r row; do
  targets_total=$((targets_total + 1))
  nf=$(awk -F'\t' '{print NF}' <<<"$row")
  if [[ "$nf" -ne 3 ]]; then
    refuse "targets row $targets_total has $nf tab-separated field(s), expected exactly 3 (relpath, app, test files): $row"
    continue
  fi

  relpath="$(cut -f1 <<<"$row")"
  app="$(cut -f2 <<<"$row")"
  tests="$(cut -f3 <<<"$row")"

  if grep -qxF "$relpath" "$SEEN_TARGETS"; then
    refuse "duplicate target row for $relpath"
  else
    printf '%s\n' "$relpath" >> "$SEEN_TARGETS"
  fi

  if [[ ! -f "$REPO_ROOT/$relpath" ]]; then
    refuse "target file does not exist: $relpath"
    continue
  fi
  if [[ ! -d "$REPO_ROOT/$app" ]]; then
    refuse "$relpath: app directory does not exist: $app"
    continue
  fi

  for tf in $tests; do
    [[ -f "$REPO_ROOT/$app/$tf" ]] \
      || refuse "$relpath: owning test file does not exist: $app/$tf (a missing owning suite is the gate's quietest failure mode)"
  done

  if ! (cd "$REPO_ROOT" && elixir "$ENGINE" list "$relpath") > "$WORK/sites.one" 2>"$WORK/sites.err"; then
    refuse "$relpath: the engine cannot enumerate it — $(head -1 "$WORK/sites.err")"
    continue
  fi

  n=$(grep -c '' "$WORK/sites.one" || true)
  if [[ "$n" -eq 0 ]]; then
    refuse "$relpath: ZERO mutation sites — a target that cannot be mutated certifies nothing; drop the row"
  fi
  cat "$WORK/sites.one" >> "$SITES_CACHE"
done < <(data_rows "$TARGETS_FILE")

[[ "$targets_total" -gt 0 ]] || refuse "targets file $TARGETS_FILE has no data rows"

# ── MUTATION_OWNS declarations ───────────────────────────────────────────────
owns_total=0
while IFS= read -r hit; do
  file="${hit%%:*}"
  owns_total=$((owns_total + 1))
  if [[ "$file" != *_test.exs ]]; then
    refuse "$file: MUTATION_OWNS outside a *_test.exs file — the gate only reads test files, so this claim is dead"
  fi
  for decl in $(sed 's/^[^:]*:[[:space:]]*# MUTATION_OWNS:[[:space:]]*//' <<<"$hit"); do
    [[ -f "$REPO_ROOT/$decl" ]] \
      || refuse "$file: MUTATION_OWNS names a file that does not exist: $decl (the proof drops out of the gate)"
  done
done < <(cd "$REPO_ROOT" && find . -path ./spikes -prune -o \( -name deps -o -name _build -o -name node_modules \) -prune \
           -o -type f \( -name '*.exs' -o -name '*.ex' \) -print 2>/dev/null \
         | sed 's|^\./||' | sort | xargs grep -HE '^[[:space:]]*# MUTATION_OWNS:' 2>/dev/null)

# ── ledger.tsv ───────────────────────────────────────────────────────────────
ledger_total=0
SEEN_KEYS="$WORK/seen_keys"
: > "$SEEN_KEYS"

# Live site keys for every file the LEDGER mentions (a ledger row may legitimately
# point at a --corpus target that is not on the tier-1 watch-list, so enumerate the
# ledger's own files rather than trusting the targets cache alone).
LIVE_KEYS="$WORK/live_keys"
: > "$LIVE_KEYS"
awk -F'\t' '{ print $1 "|" $7 "|" $3 "|" $4 "|" $5 ">" $6 }' "$SITES_CACHE" >> "$LIVE_KEYS"

if [[ -f "$LEDGER_FILE" ]]; then
  ledger_files="$WORK/ledger_files"
  data_rows "$LEDGER_FILE" | cut -f1 | sort -u > "$ledger_files"
  while IFS= read -r lf; do
    [[ -n "$lf" ]] || continue
    grep -qxF "$lf" "$SEEN_TARGETS" && continue
    [[ -f "$REPO_ROOT/$lf" ]] || { refuse "ledger references a file that does not exist: $lf"; continue; }
    (cd "$REPO_ROOT" && elixir "$ENGINE" list "$lf") 2>/dev/null \
      | awk -F'\t' '{ print $1 "|" $7 "|" $3 "|" $4 "|" $5 ">" $6 }' >> "$LIVE_KEYS"
  done < "$ledger_files"

  while IFS= read -r row; do
    ledger_total=$((ledger_total + 1))
    nf=$(awk -F'\t' '{print NF}' <<<"$row")
    if [[ "$nf" -ne 7 ]]; then
      refuse "ledger row $ledger_total has $nf tab-separated field(s), expected exactly 7 (relpath, line_sha12, col, family, from>to, class, reason): $(cut -c1-90 <<<"$row")"
      continue
    fi

    relpath="$(cut -f1 <<<"$row")"
    lsha="$(cut -f2 <<<"$row")"
    col="$(cut -f3 <<<"$row")"
    family="$(cut -f4 <<<"$row")"
    mutation="$(cut -f5 <<<"$row")"
    class="$(cut -f6 <<<"$row")"
    reason="$(cut -f7 <<<"$row")"
    key="$relpath|$lsha|$col|$family|$mutation"

    case "$class" in
      EQUIVALENT|ACCEPTED_GAP) ;;
      *) refuse "$key: class must be EQUIVALENT or ACCEPTED_GAP, got '$class'" ;;
    esac

    if [[ "${#reason}" -lt 20 ]]; then
      refuse "$key: reason is ${#reason} chars — an exemption needs a real justification, not '$reason'"
    fi

    if [[ "$class" == "ACCEPTED_GAP" && "$reason" != *ref=* ]]; then
      refuse "$key: ACCEPTED_GAP has no 'ref=' — a consciously deferred hole must name the ADR/backlog item that owns it"
    fi

    if grep -qxF "$key" "$SEEN_KEYS"; then
      refuse "$key: duplicate ledger key"
    else
      printf '%s\n' "$key" >> "$SEEN_KEYS"
    fi

    if ! grep -qxF "$key" "$LIVE_KEYS"; then
      refuse "$key: STALE — no live mutation site matches it. The source line this exemption excuses has CHANGED (line_sha12 pins its content), so the exemption has expired: re-run scripts/mutate.sh and re-justify, or delete the row."
    fi
  done < <(data_rows "$LEDGER_FILE")
fi

echo ""
if [[ "$bad" -gt 0 ]]; then
  echo "MUTATION LINT: FAILED — $bad refusal(s) over $targets_total target row(s) and $ledger_total ledger row(s)"
  exit 1
fi
echo "MUTATION LINT: ALL PASSED ($targets_total target row(s) resolvable + mutable, $owns_total MUTATION_OWNS declaration(s) resolvable, $ledger_total ledger row(s) well-formed and live)"

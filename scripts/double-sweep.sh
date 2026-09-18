#!/usr/bin/env bash
# scripts/double-sweep.sh — G-06, the DOUBLE SWEEP, as machinery instead of prose.
#
# THE RULE IT ENFORCES. Every increment sweeps the sabotage set TWICE:
#
#   (a) ANCHOR — the increment's NEW patches, swept against a pristine `git archive`
#       of the PREVIOUS HEAD. Each new patch MUST FAIL there. A patch that would fire
#       in BOTH baselines is testing nothing this increment added.
#   (b) DISARM — the whole shipped patch set, swept against THE TREE ABOUT TO SHIP,
#       proving nothing already-shipped was disarmed by the edits in this increment.
#
# ONE SWEEP IS HALF A CHECK. The rule existed only as prose in a session prompt and in
# gate handoffs, so it was enforced by whoever remembered to look — and NINE times a
# commit disarmed a shipped sabotage anyway. The ninth disarmed a red the same run had
# just shipped; the guard still worked, but nothing could prove it had not stopped
# working. This script is that proof, run by a machine.
#
# RE-DERIVED, NEVER INHERITED. Every number here is measured by THIS run: the patch
# sets from the two trees, the NEW set by set-difference over those two lists (never a
# hardcoded count — "how many patches are new" has been wrong three separate times),
# and each baseline's FAILING set from its own sweep. Nothing is read from a table.
#
# COST. This is the CHEAP half of the ritual: `git apply --check` per patch per
# baseline, no compile, no DB, no `mix test` — the full double sweep over 324 patches
# runs in seconds. It is NOT the REPLAY (apply → run the named tests → they must fail →
# revert → SHA-256 byte-exact), which is `scripts/sabotage.sh` and costs ~17 minutes for
# the full set. The two answer different questions and neither substitutes for the
# other: this one asks "does every sabotage still BITE, and does each new one bite only
# on new code"; the replay asks "does the bite still FLIP the named tests".
#
# USAGE
#   scripts/double-sweep.sh [--base <ref>] [--repo <path>] [--work <dir>]
#                           [--keep] [--require-new] [--quiet]
#
#   --base <ref>     the PREVIOUS HEAD to anchor against. Default: origin/main.
#   --repo <path>    the repository to sweep. Default: this script's own repo root.
#   --work <dir>     write the evidence files here (created if absent) instead of a
#                    temp dir: prev-input/prev-failing/ship-input/ship-failing/
#                    new-patches/anchor/comparison/counts. A gate attaches these.
#   --keep           keep the pristine archive extraction and (temp) work dir.
#   --require-new    FAIL if the increment adds no new patches. Use it where an
#                    increment is supposed to ship a red; without it an empty NEW set
#                    is reported as a VACUOUS anchor half, loudly, and is not an error.
#   --quiet          suppress the per-patch anchor detail; keep the verdicts.
#
# EXIT CODES — distinct, so a caller can tell the three failures apart.
#   0  both halves passed
#   2  usage / environment error (bad ref, not a repo, no patches on either side)
#   3  ANCHOR failure — a new patch does not fail at the previous HEAD (it would fire
#      in both baselines), or its named test cannot be found on the SHIPPING tree
#      (the positive control: a MUST_FAIL nobody can locate proves nothing)
#   4  DISARM failure — a patch that applied at the previous HEAD no longer applies to
#      the tree about to ship, or a NEW patch does not apply to the tree it ships with
#   5  ACCOUNTING failure — a half's PROCESSED count does not equal its SELECTED count,
#      which voids every number that half printed (the same defect this run's sibling
#      fix closed in sabotage.sh: a sweep that stops early must never read as coverage)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BASE="origin/main"
WORK=""
WORK_IS_TEMP=1
KEEP=0
REQUIRE_NEW=0
QUIET=0
SAB_REL="scripts/sabotages"

SCRATCH=""

usage() { sed -n '31,56p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

arg_err() {
  echo "double-sweep.sh: $1" >&2
  echo "" >&2
  usage >&2
  exit 2
}

env_err() {
  echo ""
  echo "DOUBLE SWEEP: FAILED — $1"
  exit 2
}

cleanup() {
  if [[ $KEEP -eq 0 ]]; then
    [[ -n "$SCRATCH" && -d "$SCRATCH" ]] && rm -rf "$SCRATCH"
    [[ $WORK_IS_TEMP -eq 1 && -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
  fi
  return 0
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) shift; [[ $# -gt 0 ]] || arg_err "--base requires a ref"; BASE="$1"; shift ;;
    --repo) shift; [[ $# -gt 0 ]] || arg_err "--repo requires a path"; REPO="$1"; shift ;;
    --work) shift; [[ $# -gt 0 ]] || arg_err "--work requires a directory"; WORK="$1"; WORK_IS_TEMP=0; shift ;;
    --keep) KEEP=1; shift ;;
    --require-new) REQUIRE_NEW=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) arg_err "unknown flag: $1" ;;
  esac
done

REPO="$(cd "$REPO" 2>/dev/null && pwd)" || arg_err "--repo: no such directory"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || env_err "--repo is not a git repository: $REPO"

BASE_SHA="$(git -C "$REPO" rev-parse --verify -q "${BASE}^{commit}")" \
  || env_err "--base: not a commit-ish in $REPO: $BASE (fetch it, or pass --base <ref>)"

if [[ -z "$WORK" ]]; then
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/samen_double_sweep.XXXXXX")"
else
  mkdir -p "$WORK" || env_err "--work: cannot create $WORK"
  WORK="$(cd "$WORK" && pwd)"
fi

echo "=============================================================================="
echo " DOUBLE SWEEP (G-06) — anchor against the previous HEAD, disarm against the"
echo "                       tree about to ship. Both halves, every number re-derived."
echo "=============================================================================="
echo "  repo       : $REPO"
echo "  base (PREV): $BASE  ->  $BASE_SHA"
echo "  ship tree  : the WORKING TREE (uncommitted edits included — that is what ships)"
echo "  work dir   : $WORK"

dirty="$(git -C "$REPO" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "  dirty paths in the ship tree: $dirty"
echo ""

# ── the pristine PREVIOUS-HEAD archive, extracted OUTSIDE the repo ───────────────────
# Outside, always: sweeping a checkout of the base inside the repo would let the
# shipping tree's own files leak into the "pristine" baseline, which is the one thing
# this baseline exists to exclude.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/samen_sweep_prev.XXXXXX")"
case "$SCRATCH" in
  "$REPO"|"$REPO"/*) env_err "scratch dir landed INSIDE the repo ($SCRATCH) — refusing to sweep a contaminated baseline" ;;
esac
git -C "$REPO" archive "$BASE_SHA" | tar -x -C "$SCRATCH"
# BOTH statuses in ONE capture: reading $PIPESTATUS into a variable RESETS it, so a
# second read would see the assignment's own status (and under `set -u` on bash 3.2,
# an unbound element). Never infer a pipeline's halves one at a time.
pipe_status=("${PIPESTATUS[@]}")
archive_status="${pipe_status[0]}"
tar_status="${pipe_status[1]}"
[[ "$archive_status" -eq 0 && "$tar_status" -eq 0 ]] \
  || env_err "could not extract a pristine archive of $BASE (git archive=$archive_status tar=$tar_status)"
echo "$SCRATCH" > "$WORK/scratch-path.txt"

# ── one half of the sweep ────────────────────────────────────────────────────────────
# sweep_half <label> <tree-root> <input-list-out> <failing-out> <errors-out> <counts-out>
#
# SELECTED is the number of patch files the tree offers; PROCESSED is the number this
# loop actually audited. They are counted independently ON PURPOSE: if a `while read`
# ever loses a line (a word-split, a NUL, a truncated list) every failing-set number
# derived from that half is void, and the caller must be told rather than shown a
# confident, short answer. This is the same defect class as sabotage.sh reporting a
# fail-fast abort as if it were coverage.
sweep_half() {
  local label="$1" root="$2" input="$3" failing="$4" errors="$5" counts="$6"
  local selected=0 processed=0 p

  if [[ -d "$root/$SAB_REL" ]]; then
    find "$root/$SAB_REL" -maxdepth 1 -name '*.patch' -type f | LC_ALL=C sort > "$input"
  else
    : > "$input"
  fi
  selected="$(wc -l < "$input" | tr -d ' ')"

  : > "$failing"
  : > "$errors"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    processed=$((processed + 1))
    # `git apply --check` runs happily outside a work tree, so the pristine extraction
    # needs no .git of its own — and cannot accidentally consult one.
    ( cd "$root" && git apply --check "$p" ) 2>>"$errors" || basename "$p" >> "$failing"
  done < "$input"

  { echo "SELECTED=$selected"; echo "PROCESSED=$processed"; } > "$counts"
  echo "DOUBLE SWEEP: $label half PROCESSED $processed of $selected SELECTED"
  if [[ "$processed" -ne "$selected" ]]; then
    echo "  !! the $label half audited $processed of $selected patches — every number it"
    echo "     produced is VOID. (A short sweep is not a clean sweep.)"
    return 5
  fi
  return 0
}

ACCOUNTING_BAD=0
sweep_half "PREV" "$SCRATCH" "$WORK/prev-input.txt" "$WORK/prev-failing.txt" \
           "$WORK/prev-errors.txt" "$WORK/prev-counts.txt" || ACCOUNTING_BAD=1
sweep_half "SHIP" "$REPO" "$WORK/ship-input.txt" "$WORK/ship-failing.txt" \
           "$WORK/ship-errors.txt" "$WORK/ship-counts.txt" || ACCOUNTING_BAD=1

prev_selected="$(sed -n 's/^SELECTED=//p' "$WORK/prev-counts.txt")"
ship_selected="$(sed -n 's/^SELECTED=//p' "$WORK/ship-counts.txt")"

if [[ $ACCOUNTING_BAD -eq 1 ]]; then
  echo ""
  echo "DOUBLE SWEEP: FAILED — ACCOUNTING: a half did not audit everything it selected."
  exit 5
fi

if [[ "$prev_selected" -eq 0 && "$ship_selected" -eq 0 ]]; then
  env_err "no patches under $SAB_REL in EITHER tree — this sweep would certify nothing"
fi

# ── the NEW set, DERIVED (never a count someone typed) ───────────────────────────────
sed 's|.*/||' "$WORK/prev-input.txt" | LC_ALL=C sort > "$WORK/prev-names.txt"
sed 's|.*/||' "$WORK/ship-input.txt" | LC_ALL=C sort > "$WORK/ship-names.txt"
LC_ALL=C comm -13 "$WORK/prev-names.txt" "$WORK/ship-names.txt" > "$WORK/new-patches.txt"
LC_ALL=C comm -23 "$WORK/prev-names.txt" "$WORK/ship-names.txt" > "$WORK/removed-patches.txt"
new_count="$(wc -l < "$WORK/new-patches.txt" | tr -d ' ')"
removed_count="$(wc -l < "$WORK/removed-patches.txt" | tr -d ' ')"

echo ""
echo "  patch sets : PREV $prev_selected  ->  SHIP $ship_selected   (NEW $new_count, REMOVED $removed_count)"
if [[ "$removed_count" -gt 0 ]]; then
  echo "  !! this increment DELETES shipped sabotages — deleting a red is the loudest"
  echo "     possible disarm. Each deletion needs a written reason in the PR body:"
  sed 's/^/       - /' "$WORK/removed-patches.txt"
fi

# ══ HALF (a): THE ANCHOR ═════════════════════════════════════════════════════════════
# A new patch anchors on NEW code when it CANNOT fire at the previous HEAD. There are
# exactly two ways for that to be true, and either one is sufficient:
#   (i)  the patch does not apply at PREV — the lib arm it attacks did not exist yet, or
#   (ii) a MUST_FAIL test it names does not exist at PREV — the red is new.
# If the patch applies at PREV *and* every test it names already existed there, the same
# red was already available before this increment: it is testing nothing new.
# POSITIVE CONTROL, always: every MUST_FAIL must be findable on the SHIPPING tree. A
# MUST_FAIL that matches nothing anywhere would "anchor" every patch for free.
echo ""
echo "── HALF (a) ANCHOR — each NEW patch must FAIL at $BASE ─────────────────────────"
anchor_failures=0
: > "$WORK/anchor.txt"

if [[ "$new_count" -eq 0 ]]; then
  echo "  VACUOUS: this increment adds NO new patches, so the anchor half proves nothing."
  echo "  (Legitimate for a change that ships no new red; not a substitute for one.)"
  echo "VACUOUS: 0 new patches" >> "$WORK/anchor.txt"
  if [[ $REQUIRE_NEW -eq 1 ]]; then
    echo "  --require-new was given and the NEW set is empty."
    anchor_failures=$((anchor_failures + 1))
  fi
else
  while IFS= read -r nm; do
    [[ -n "$nm" ]] || continue
    patch="$REPO/$SAB_REL/$nm"
    app="$(sed -n 's/^# APP: //p' "$patch" | head -1)"
    verdict_reasons=""
    {
      echo "=== $nm (app=${app:-<none>}) ==="
    } >> "$WORK/anchor.txt"

    if [[ -z "$app" ]]; then
      echo "  ANCHOR FAIL  $nm — no APP: header; its named tests cannot be located"
      echo "  no APP header" >> "$WORK/anchor.txt"
      anchor_failures=$((anchor_failures + 1))
      continue
    fi

    # (i) does the patch even apply at PREV?
    ( cd "$SCRATCH" && git apply --check "$patch" ) >/dev/null 2>&1
    applies_at_prev=$?
    if [[ $applies_at_prev -ne 0 ]]; then
      verdict_reasons="the patch does not apply at PREV (the lib arm it attacks is new)"
    fi
    echo "  apply --check at PREV: EXIT=$applies_at_prev" >> "$WORK/anchor.txt"

    # (ii) + the positive control, per MUST_FAIL.
    control_bad=0
    new_test=0
    while IFS= read -r mf; do
      [[ -n "$mf" ]] || continue
      ship_hit=1
      prev_hit=1
      [[ -d "$REPO/$app/test" ]] && grep -rqF -- "$mf" "$REPO/$app/test" && ship_hit=0
      [[ -d "$SCRATCH/$app/test" ]] && grep -rqF -- "$mf" "$SCRATCH/$app/test" && prev_hit=0
      echo "  MUST_FAIL: $mf  [ship=$ship_hit prev=$prev_hit]  (0 = found)" >> "$WORK/anchor.txt"
      if [[ $ship_hit -ne 0 ]]; then
        echo "  ANCHOR FAIL  $nm — POSITIVE CONTROL: MUST_FAIL not found in $app/test on the"
        echo "               SHIPPING tree: \"$mf\""
        echo "               A named test nobody can locate cannot have flipped; fix the"
        echo "               header or write the test."
        control_bad=1
      elif [[ $prev_hit -ne 0 ]]; then
        new_test=1
      fi
    done < <(sed -n 's/^# MUST_FAIL: //p' "$patch")

    if [[ $control_bad -eq 1 ]]; then
      anchor_failures=$((anchor_failures + 1))
      continue
    fi
    if [[ $new_test -eq 1 ]]; then
      if [[ -n "$verdict_reasons" ]]; then
        verdict_reasons="$verdict_reasons; and a MUST_FAIL test does not exist at PREV"
      else
        verdict_reasons="a MUST_FAIL test does not exist at PREV (the red is new)"
      fi
    fi

    if [[ -n "$verdict_reasons" ]]; then
      [[ $QUIET -eq 1 ]] || echo "  ANCHORED     $nm — $verdict_reasons"
      echo "  ANCHORED: $verdict_reasons" >> "$WORK/anchor.txt"
    else
      echo "  ANCHOR FAIL  $nm — it APPLIES at PREV and every test it names ALREADY EXISTED"
      echo "               there. This patch would fire in BOTH baselines, so it is not"
      echo "               testing anything this increment added."
      echo "  NOT ANCHORED" >> "$WORK/anchor.txt"
      anchor_failures=$((anchor_failures + 1))
    fi
  done < "$WORK/new-patches.txt"
  [[ $anchor_failures -eq 0 ]] && echo "  anchor half: $new_count of $new_count new patch(es) anchored on new code."
fi

# ══ HALF (b): THE DISARM ═════════════════════════════════════════════════════════════
# The failing sets are re-derived above, one per baseline. A patch that applied at PREV
# and no longer applies to the shipping tree was DISARMED by an edit in this increment.
# A patch failing in BOTH baselines is a pre-existing failure: reported, never absorbed
# into a "known-good" list here, and never counted as a regression (that distinction is
# also the anti-tautology control for this half — without it, a check that called every
# ship-side failure a regression would look identical on a clean tree).
echo ""
echo "── HALF (b) DISARM — nothing already shipped may stop biting ───────────────────"
LC_ALL=C sort "$WORK/prev-failing.txt" -o "$WORK/prev-failing.txt"
LC_ALL=C sort "$WORK/ship-failing.txt" -o "$WORK/ship-failing.txt"
prev_fail_n="$(wc -l < "$WORK/prev-failing.txt" | tr -d ' ')"
ship_fail_n="$(wc -l < "$WORK/ship-failing.txt" | tr -d ' ')"

# ship-side failures that did not fail at PREV, split into the two things they can be.
LC_ALL=C comm -13 "$WORK/prev-failing.txt" "$WORK/ship-failing.txt" > "$WORK/comparison.txt"
: > "$WORK/disarmed.txt"
: > "$WORK/new-broken.txt"
while IFS= read -r nm; do
  [[ -n "$nm" ]] || continue
  if LC_ALL=C grep -qxF -- "$nm" "$WORK/new-patches.txt"; then
    echo "$nm" >> "$WORK/new-broken.txt"
  else
    echo "$nm" >> "$WORK/disarmed.txt"
  fi
done < "$WORK/comparison.txt"
LC_ALL=C comm -23 "$WORK/prev-failing.txt" "$WORK/ship-failing.txt" > "$WORK/recovered.txt"

disarmed_n="$(wc -l < "$WORK/disarmed.txt" | tr -d ' ')"
new_broken_n="$(wc -l < "$WORK/new-broken.txt" | tr -d ' ')"
recovered_n="$(wc -l < "$WORK/recovered.txt" | tr -d ' ')"

echo "  failing at PREV ($prev_fail_n) — re-derived by this run, not inherited:"
if [[ "$prev_fail_n" -eq 0 ]]; then echo "    (none)"; else sed 's/^/    - /' "$WORK/prev-failing.txt"; fi
echo "  failing at SHIP ($ship_fail_n):"
if [[ "$ship_fail_n" -eq 0 ]]; then echo "    (none)"; else sed 's/^/    - /' "$WORK/ship-failing.txt"; fi
if [[ "$recovered_n" -gt 0 ]]; then
  echo "  re-anchored by this increment (failed at PREV, applies now) — not a failure:"
  sed 's/^/    + /' "$WORK/recovered.txt"
fi

disarm_failures=0
if [[ "$disarmed_n" -gt 0 ]]; then
  echo ""
  echo "  DISARMED — applied at $BASE, no longer applies to the tree you are about to ship:"
  sed 's/^/    !! /' "$WORK/disarmed.txt"
  echo "     Name the edit of yours that disarmed each one and RE-ANCHOR the patch."
  echo "     Deleting or relaxing the sabotage is not a fix (ADR-014/024/026)."
  disarm_failures=$((disarm_failures + 1))
fi
if [[ "$new_broken_n" -gt 0 ]]; then
  echo ""
  echo "  NEW PATCH DOES NOT APPLY to the tree it ships with:"
  sed 's/^/    !! /' "$WORK/new-broken.txt"
  echo "     sabotage.sh would abort on this patch before replaying anything after it."
  disarm_failures=$((disarm_failures + 1))
fi
[[ $disarm_failures -eq 0 ]] && echo "  disarm half: nothing already shipped stopped biting."

# ══ VERDICT ══════════════════════════════════════════════════════════════════════════
echo ""
if [[ $anchor_failures -gt 0 || $disarm_failures -gt 0 ]]; then
  if [[ $anchor_failures -gt 0 ]]; then
    echo "DOUBLE SWEEP: FAILED — ANCHOR: $anchor_failures new patch(es) do not anchor on new code (see above)."
    echo "  Evidence: $WORK/anchor.txt, $WORK/new-patches.txt"
    [[ $disarm_failures -gt 0 ]] && echo "  (the DISARM half ALSO failed — see the disarm section above)"
    exit 3
  fi
  echo "DOUBLE SWEEP: FAILED — DISARM: a shipped sabotage stopped biting (see above)."
  echo "  Evidence: $WORK/disarmed.txt, $WORK/new-broken.txt, $WORK/prev-failing.txt, $WORK/ship-failing.txt"
  exit 4
fi

anchor_summary="$new_count of $new_count new patch(es) anchored"
[[ "$new_count" -eq 0 ]] && anchor_summary="VACUOUS, 0 new patches"
echo "DOUBLE SWEEP: ALL PASSED (anchor: $anchor_summary; disarm: $ship_selected of $ship_selected audited, failing set unchanged)"
echo "  NOTE: this is the apply-check half of G-06. The REPLAY — does the bite still FLIP"
echo "        the named tests — is scripts/sabotage.sh (use --range over the NEW patches)."
exit 0

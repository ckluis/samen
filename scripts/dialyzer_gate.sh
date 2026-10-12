#!/usr/bin/env bash
# scripts/dialyzer_gate.sh — dialyzer over every product project (issue #73, ruled: in the
# default ./ci.sh).
#
# Each project fails on any warning that is not in its own `.dialyzer_ignore.exs`, and every
# entry there carries the reason it is a false positive or deliberate code. A NEW warning is
# a failure.
#
# THE PLT RULE. dialyxir decides whether a project's PLT is stale from its LOCKFILE, and an
# in-repo path dependency (samen_core) is not in any lockfile — so a samen_core change would
# leave a dependant's PLT silently stale and dialyzer would check calls against the OLD
# specs (measured: samen_web kept reporting three spec fixes as broken calls until its PLT
# was rebuilt). So:
#   * samen_core       — PLT of external deps only; the lockfile rule is enough.
#   * samen_web        — keeps samen_core IN its PLT (the cross-boundary call checks found
#                        three wrong specs) and this script rebuilds that PLT whenever
#                        samen_core's source hash changes (~95 s), never otherwise.
#   * the other eight  — keep samen_core/samen_web OUT of their PLT (`plt_ignore_apps` +
#                        `:no_unknown` in their mix.exs), so a framework change never forces
#                        eight rebuilds; the framework is checked by its own projects' runs.
#
# Runs the projects ONE AT A TIME: each dialyzer run peaks at ~2–3 GB.
#
# Usage: scripts/dialyzer_gate.sh [app…]     (default: all ten)
# Exit:  0 all clean · 1 a project reported a warning its ignore file does not cover
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS=("$@")
[[ ${#APPS[@]} -gt 0 ]] || APPS=(samen_core samen_web demo driftwood pawchart samen_stripe samen_postmark samen_ses samen_resend samen_anthropic)

# samen_core's source identity: every lib/ file's PATH and content, plus mix.exs/mix.lock —
# tracked files AND untracked-but-not-ignored ones (a new core module that is not yet
# committed is still compiled into samen_web's PLT; hashing only `git ls-files` left that PLT
# stale until the commit — ADR-052 P3 builder note). Sorted, and a path the index lists but
# the work tree no longer has is skipped, so the hash is the work tree as dialyzer sees it.
core_hash() {
  (cd "$REPO_ROOT/samen_core" &&
    git ls-files -z --cached --others --exclude-standard -- lib mix.exs mix.lock | sort -zu |
      while IFS= read -r -d '' f; do
        [[ -f "$f" ]] && { printf '%s\0' "$f"; cat "$f"; }
      done | shasum -a 256 | cut -d' ' -f1)
}

refresh_web_plt() {
  local plts="$REPO_ROOT/samen_web/priv/plts" stamp want have=""
  stamp="$plts/samen_core.source.sha256"
  want="$(core_hash)"
  [[ -f "$stamp" ]] && have="$(cat "$stamp")"
  if [[ "$want" != "$have" ]]; then
    echo "    samen_core changed since samen_web's PLT was built — rebuilding it"
    rm -f "$plts"/dialyxir_*_deps-*.plt "$plts"/dialyxir_*_deps-*.plt.hash
  fi
  mkdir -p "$plts"
  echo "$want" > "$stamp.pending"
}

failed=()
for app in "${APPS[@]}"; do
  [[ -d "$REPO_ROOT/$app" ]] || { echo "DIALYZER: no such project: $app" >&2; exit 2; }
  echo "==> dialyzer: $app"
  [[ "$app" == samen_web ]] && refresh_web_plt
  log="$(mktemp "${TMPDIR:-/tmp}/dialyzer_${app}.XXXXXX")"
  # self-contained: a clean checkout (Actions) has no deps; with them present this is a no-op
  (cd "$REPO_ROOT/$app" && mix deps.get --quiet && mix dialyzer --format short) > "$log" 2>&1
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "    clean"
    [[ "$app" == samen_web && -f "$REPO_ROOT/samen_web/priv/plts/samen_core.source.sha256.pending" ]] &&
      mv "$REPO_ROOT/samen_web/priv/plts/samen_core.source.sha256.pending" "$REPO_ROOT/samen_web/priv/plts/samen_core.source.sha256"
  else
    echo "    FAILED (exit $rc):"
    grep -E '^(lib|test)/.*:[0-9]+' "$log" | sed 's/^/      /' | head -40
    grep -E 'Unused filters|unused filter' -A20 "$log" | sed 's/^/      /' | head -20
    # no warning line at all = dialyzer (or deps) itself failed: show why instead of a bare "FAILED"
    grep -qE '^(lib|test)/.*:[0-9]+|[Uu]nused filter' "$log" || tail -25 "$log" | sed 's/^/      | /'
    failed+=("$app")
  fi
  rm -f "$log"
done

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "DIALYZER: FAILED — ${failed[*]} (a warning not in that project's .dialyzer_ignore.exs: fix it, or add it there WITH the reason it is a false positive)"
  exit 1
fi
echo "DIALYZER: ALL PASSED (${#APPS[@]} projects)"

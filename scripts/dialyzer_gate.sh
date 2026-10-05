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

# samen_core's source identity: every lib/ file's content plus its lockfile.
core_hash() {
  (cd "$REPO_ROOT/samen_core" && git ls-files -z lib mix.exs mix.lock | xargs -0 cat | shasum -a 256 | cut -d' ' -f1)
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
  (cd "$REPO_ROOT/$app" && mix dialyzer --format short) > "$log" 2>&1
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "    clean"
    [[ "$app" == samen_web && -f "$REPO_ROOT/samen_web/priv/plts/samen_core.source.sha256.pending" ]] &&
      mv "$REPO_ROOT/samen_web/priv/plts/samen_core.source.sha256.pending" "$REPO_ROOT/samen_web/priv/plts/samen_core.source.sha256"
  else
    echo "    FAILED (exit $rc):"
    grep -E '^(lib|test)/.*:[0-9]+' "$log" | sed 's/^/      /' | head -40
    grep -E 'Unused filters|unused filter' -A20 "$log" | sed 's/^/      /' | head -20
    failed+=("$app")
  fi
  rm -f "$log"
done

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "DIALYZER: FAILED — ${failed[*]} (a warning not in that project's .dialyzer_ignore.exs: fix it, or add it there WITH the reason it is a false positive)"
  exit 1
fi
echo "DIALYZER: ALL PASSED (${#APPS[@]} projects)"

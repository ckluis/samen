#!/usr/bin/env bash
# One-shot SIGINT proof: interrupt a live run mid-mutant and prove the trap restored the
# real tracked target byte-exact. (The permanent version runs in scripts/mutate_test.sh.)
set -uo pipefail
set -m                                  # own process group per job, so we can signal the group
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TGT="$ROOT/samen_core/lib/samen/ai/agent.ex"
BEFORE=$(shasum -a 256 "$TGT" | awk '{print $1}')
echo "baseline sha: $BEFORE"
MUTATE_PAUSE_BEFORE_RESTORE=8 bash "$ROOT/scripts/mutate.sh" --only context_gate >"$ROOT/scripts/.mutate-acceptance/sigint-run.log" 2>&1 &
PID=$!
sent=0
for _ in $(seq 1 200); do
  kill -0 "$PID" 2>/dev/null || break
  NOW=$(shasum -a 256 "$TGT" | awk '{print $1}')
  if [[ "$NOW" != "$BEFORE" ]]; then
    echo "mutant is LIVE on disk (sha $NOW) -- sending SIGINT to process group -$PID"
    kill -INT -- "-$PID"                # negative PID = the whole process group
    sent=1
    break
  fi
  sleep 0.3
done
wait "$PID"; RC=$?
AFTER=$(shasum -a 256 "$TGT" | awk '{print $1}')
echo "signal sent: $sent   engine exit: $RC (expect 130)"
echo "after sha:   $AFTER"
DIRTY=$(cd "$ROOT" && git status --porcelain -- samen_core/lib/samen/ai/agent.ex | /usr/bin/grep -v '^??' || true)
if [[ "$sent" -eq 1 && "$BEFORE" == "$AFTER" && "$RC" -eq 130 && -z "$DIRTY" ]]; then
  echo "SIGINT PROOF: PASS -- trap restored agent.ex byte-exact after mid-mutant interrupt"
else
  echo "SIGINT PROOF: FAIL (sent=$sent before=$BEFORE after=$AFTER rc=$RC dirty='$DIRTY')"; exit 1
fi

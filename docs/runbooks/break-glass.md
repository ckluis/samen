# Runbook — Break-glass emergency reveal (T4.4)

**Scope:** the DISTINCT emergency reveal path for when the routine reveal would fail
closed because the central audit / control-plane DB is unreachable. Implements the
vision doc's "honest edges" break-glass bullet exactly: *control-plane-down =
deferred anchoring + reveal completes via the live KMS; KMS-down = fail closed, NO
bypass.*

Code: `Samen.BreakGlass`, `Samen.BreakGlass.LocalAudit`, `Samen.BreakGlass.Budget`,
`Samen.BreakGlass.Reconciliation`, `Samen.OperatorPlane.Suspension`.

---

## 1. What survives what (the precise contract)

| Failure | Break-glass behavior |
|---|---|
| **Central audit / control-plane DB down** | Reveal **COMPLETES**. Who/what/why is written to the **local** fsync'd hash chain BEFORE the reveal; central anchoring is DEFERRED to reconnect. |
| **KMS down** | Reveal **FAILS CLOSED** (`{:error, :unavailable}`). Break-glass still calls the live KMS to decrypt; there is NO degraded path that manufactures plaintext. Deny-**recoverable**: when the KMS heals, the same break-glass succeeds. |
| **Operator suspended** (breadth-budget breach) | Reveal **DENIES** (`{:error, :operator_suspended}`). There is NO emergency override of a suspension. |
| **No reason (who/what/why)** | Reveal **REFUSES** (`{:error, :reason_required}`) before any write. |
| **Local audit write fails** | Reveal **FAILS CLOSED** (`{:error, {:local_audit_failed, _}}`) — can't log it ⇒ can't see it. |

The KMS is never bypassable: `Samen.BreakGlass` decrypts through the SAME single
vault chokepoint (`Samen.Vault.reveal/3`) the routine path uses.

---

## 2. Single break-glass role convention

There is exactly ONE break-glass role: `:operator_break_glass`
(`Samen.OperatorPlane.Actor`). It is the only role `Samen.BreakGlass.authorized?/1`
accepts. Keep the set of holders SMALL and reviewable — the audit answer to "who
could break glass" is this one role's membership. `:operator_support`,
`:operator_readonly`, and tenant actors cannot break glass.

Operational rule: grant `:operator_break_glass` to a named, on-call subset; review
its membership on the same cadence as any privileged-access review.

---

## 3. Performing a break-glass reveal

```elixir
Samen.BreakGlass.reveal(%{
  operator:  operator_actor,          # must hold :operator_break_glass
  subject_id: subject_uuid,
  reason:    "PagerDuty INC-1234: <who/what/why>",  # REQUIRED, non-empty
  masked:    masked_value,            # the %Masked{} to reveal
  action:    :reveal_email,           # a declared reveal action
  resource:  MyApp.Scope.Person,
  org_id:    org_uuid                 # chain partition (optional)
})
```

Returns `{:ok, %{plaintext: ..., local_entry: entry}}` on success. Every success
appends a fsync'd entry to the local hash chain AND emits `[:samen, :break_glass,
:reveal]` telemetry.

---

## 4. Reconciliation (when the control plane returns)

```elixir
Samen.BreakGlass.Reconciliation.reconcile(repo: MyApp.Repo)
```

- Verifies the LOCAL chain first. A tampered/gapped local file returns
  `{:error, {:local_tamper, _}}` and anchors **nothing** (fail closed across the
  seam) — investigate before proceeding (see §6).
- Anchors each not-yet-anchored local entry into the central T4.3 chain
  (`aud_chain`) and the `aud_event` tier, idempotently (keyed on the local entry's
  content hash in `brc_break_glass_anchor`).

Run reconciliation on control-plane recovery (a cron on the operator node, or
manually after an incident). It is safe to run repeatedly.

---

## 5. R8 — local-disk durability residue: THE DECISION

**Risk (plan R8):** the local break-glass audit assumes a node disk that survives.
Fly machines (and most ephemeral compute) can be recreated, taking the local file
with them — a window exists between the local write and reconciliation where the
audit lives only on one node's disk.

**Decision: persistent-volume mount (primary) + accept-and-monitor (backstop).**

1. **Persistent volume (primary).** In production, mount a persistent volume per
   operator node and point `:break_glass_local_audit_path` at it:

   ```elixir
   config :samen_core, :break_glass_local_audit_path, "/data/break_glass/audit.local"
   ```

   On Fly this is a `fly volume` attached to the operator process group; the volume
   survives machine restarts and re-deploys, so a reveal written during an outage is
   still present when the node comes back and reconciliation runs. The volume is NOT
   in the Postgres PITR surface (it is a separate device) — consistent with the
   external-KMS decision that keeps accountability material off the DB backup path.

2. **Accept-and-monitor (backstop).** A persistent volume can still be lost
   (destroyed region, detached volume). We do NOT pretend this window is zero. So:
   - `Samen.BreakGlass.Reconciliation.emit_unanchored_signal/1` fires the
     `[:samen, :break_glass, :unanchored]` telemetry with the count of local entries
     NOT yet anchored into the central chain. Wire it to a cron (every few minutes)
     on the operator node.
   - **Alert** when the unanchored count is `> 0` for longer than the expected
     control-plane outage window (e.g. > 15 min). A persistent non-zero count means
     either the control plane is still down OR reconciliation is failing — page.
   - The residue is documented, bounded, and observable — never silent.

**Why not "two synchronous local nodes"?** The plan named it as an option. We chose
persistent-volume + monitor because it is simpler to operate, keeps the fsync'd
single-writer discipline (no cross-node consensus on the emergency path), and the
monitoring signal makes the residue window visible rather than trading it for
distributed-write complexity that itself fails in new ways during a partition. If a
future compliance regime requires zero-single-node-loss, the two-node synchronous
write is the documented upgrade.

---

## 6. Tamper at reconciliation — what it means, what to do

`reconcile/1` returning `{:error, {:local_tamper, {reason, seq}}}` means the local
hash chain does not verify:

- `:tampered_line` — a line's stored content hash does not match its bytes (edited).
- `:seq_gap` — an entry is missing (deleted middle entry, truncated file).
- `:broken_link` — an entry's `prior_hash` does not match the previous entry's hash.
- `:hash_mismatch` — an entry's stored chain hash does not match its recomputed hash.

This is a SECURITY event: the emergency audit was altered on disk. Do NOT delete the
file. Snapshot it, escalate, and reconcile the surviving prefix manually if needed.
The central chain anchors NOTHING from a tampered local file — a corrupt local record
is never laundered into the tamper-evident central chain.

---

## 7. Breadth budget + auto-suspend

`config :samen_core, :break_glass_breadth_budget, 25` distinct subjects per
`:break_glass_breadth_window_seconds` (default 1h), counted in `brl_reveal_ledger`
across ALL reveal paths (routine + break-glass — an operator cannot dodge the budget
via the emergency path). Exceeding it AUTO-SUSPENDS the operator: a row in
`osp_operator_suspension`, an `operator_suspension` audit event, and every reveal
path (routine reveal, impersonation, break-glass) denies for that operator.

Re-enable is EXPLICIT and MANUAL (a suspension is not time-based, so a runaway loop
cannot wait it out):

```elixir
Samen.OperatorPlane.Suspension.clear(operator_id, %{cleared_by: "oncall:alice"})
```

Investigate WHY the budget tripped (compromised credential? runaway automation?)
before clearing.

---

## 8. Telemetry to wire

| Event | Meaning |
|---|---|
| `[:samen, :break_glass, :reveal]` | a break-glass reveal completed (count += 1) |
| `[:samen, :break_glass, :unanchored]` | count of local entries awaiting central anchoring (R8 residue monitor) — alert on sustained `> 0` |

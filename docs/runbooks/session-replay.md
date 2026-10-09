# Runbook — Session replay (ADR-052)

**Scope:** turning session replay on for one tenant org, watching a replay, what the viewer
sees, and how long replays are kept. Code: `Samen.Replay` (capture, storage, player kernel),
`Samen.Web.Replay.*` (recorder, who may watch, player UI). Design:
`docs/adr/ADR-052-observability-wiring-and-masked-replay.md`; reference:
`docs/observability-guide.md` §7.

A replay records what a tenant user DID in a LiveView, never the personal data they saw or
typed: vault-routed fields are stored as references, typed input as shape only. It is
off by default and opt-in per org.

---

## 1. Enable replay for an org

Two switches, both required.

1. **The host runs the capture plane.** In the host's config (or the `child_specs/2` call):

   ```elixir
   config :my_app, Samen.Observability,
     replay: [retention_days: 14, flag_opts: [flag_module: MyApp.Primitives.FeatureFlag]]
   ```

   `flag_opts:` points the flag lookup at the host's FeatureFlag rows for replay only. Bounds
   are validated at boot (`retention_days` 1..90, positive caps, `sample_rate` 0..1); a bad
   value refuses to boot. Driftwood sets this in `config/dev.exs` only.

2. **The org's `samen.replay` flag is ON.** Create (or update) the FeatureFlag row named
   `samen.replay`: `enabled: true`, `rollout_pct: 0`, and ONE target rule
   `%{"attribute" => "org_id", "op" => "in", "values" => [org_id], "then" => "allow"}` (add
   org ids to opt more orgs in). Writes go through the flag resource's admin-gated actions
   (the operator flag admin at `/operator/flags`). The decision is cached; a write through the
   framework invalidates it, and a direct DB edit needs `Samen.FeatureFlags.Cache.invalidate("samen.replay")`.

   Driftwood dev: `MIX_ENV=dev mix driftwood.seed` seeds this row for the Blue Ridge
   Logistics org (`b1112d00-0000-4000-8000-000000000001`, `Driftwood.Seeds.seed_replay_flag/1`).

To turn it **off** for an org: remove the org from the rule, or set `enabled: false` (the kill
switch: every org stops on the next LiveView). Already-stored replays stay until retention
removes them.

Caveat: the flag cache resolves `samen.replay` by NAME across the FeatureFlag rows. Keep exactly
one `samen.replay` row, governed by the operator; do not let a tenant create a second row with
the same name.

## 2. Watch a replay

- **Operator:** open an impersonation session for the org (reason required, as for any
  drill-in), then go to the account page → **Replays →** (`/operator/replays/:org_id`) and
  open a session. Without an active impersonation session the page refuses and shows the
  open-session form. If the session ends or expires mid-playback, the next frame batch stops
  playback.
- **Tenant:** an owner or admin of the org opens **Settings → Session replays**
  (`/settings/replays`). Members are refused.

Every open writes one `replay.viewed` row on the org's audit chain (replay id, viewer id,
impersonation session id for operators). Stepping through frames writes nothing.

## 3. What the viewer sees

| In the recording | Shown as |
|---|---|
| A vault-routed field, viewer has no reveal grant | `••••` |
| The same, operator with a live reveal grant on that subject | the CURRENT value (traced as a reveal span) |
| The subject was crypto-shredded | `[erased]` |
| The record was deleted, or belongs to another org | `[gone]` |
| The view or attribute changed since recording | `[changed]` |
| Freeform text, typed form input, unlisted strings | `▒▒▒ (n)` — shape only |
| Streams / uploads | `▒ n items` |

Values are labelled **current** (late binding): a replay shows what the user did with
today's value of each referenced field. The page renders in a script-free sandboxed iframe;
nothing in it can be clicked through to the live app. A frame whose template needs data the
recorder never stores (a form) shows a placeholder for that frame. The drift marker says
whether the view's code changed since the recording.

## 4. Retention

Default **14 days**, configurable 1..90 via `replay: [retention_days: n]`. Retention runs
wherever the replay tables are mounted, even with capture off: the nightly
`Samen.Retention.SweepWorker` deletes sessions older than the window, and their frames
cascade. A crypto-shred needs no replay-specific step: references to the erased subject show
`[erased]` (proved per subject by `mix samen.verify.no_plaintext_pii --subject <uuid> --tiers all`).

## 5. Health

- `Samen.Replay.Monitor.stats/0` on a node: `%{persisted, discarded, failed, dropped}`.
- Metric `samen.replay.session.count{result}`. A rising `failed` means persists are
  being refused (check the logs for `[Samen.Replay] persist failed: <kind>`). A rising
  `dropped` means more than `max_persist_tasks` persists were in flight at once.
- `mix samen.verify.no_plaintext_pii` (the `:replay` tier) proves the stored rows hold no
  plaintext.

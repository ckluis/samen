defmodule Demo.MarketingScope do
  @moduledoc """
  The Demo host's Marketing domain — mounted from the `samen_core` Marketing scope
  blueprint (ADR-004; T3.4).

  One `use Samen.Scopes.Marketing` expands into seven host-owned resources
  (`Demo.MarketingScope.{Campaign,Segment,Subscriber,Template,Send,EmailEvent,Suppression}`),
  each a normal `use Samen.Resource` in the DEMO's `otp_app`/`repo`, so:

    * their columns are catalogued in the DEMO's `tam_table`/`fld_field`
      (the `AddMarketingScope` migration's `catalog_sync/1`);
    * the DEMO's unchanged verifiers scan them;
    * `Subscriber` PII (email) routes into the DEMO's one Postgres vault;
    * org-scope + RBAC policies are inherited, not re-authored;
    * suppression is enforced at send-time (a send to a suppressed subscriber is refused).

  ## Consent/suppression enforcement

  The `Send.create_checked/2` action is the ONLY way to create a send row. It
  queries the `msp_suppression` table before writing. A suppressed subscriber causes
  the action to return `{:error, :suppressed}` — no row, no Oban job.

  ## Sends are Oban jobs

  `Samen.Scopes.Marketing.SendWorker` runs in the `:webhooks_out` queue (capped
  backoff, at-least-once, idempotency key on the send ID, same-transaction enqueue
  via `Samen.Jobs.enqueue_in_tx/3`).

  ## Thin smoke usage (T3.4 acceptance: proves host-mounting works)

  `Demo.MarketingScope.Smoke.run/1` exercises one round-trip per resource, including
  the suppression red path, confirming host-mount, vault routing, and suppression
  enforcement work end-to-end in a real Postgres.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Marketing,
    otp_app: :demo,
    repo: Demo.Repo,
    namespace: Demo.MarketingScope
end

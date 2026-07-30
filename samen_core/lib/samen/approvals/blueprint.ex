defmodule Samen.Approvals.Blueprint do
  @moduledoc """
  T35 §4.7 — the per-host `Approval` resource definer (ADR-040 §4.1). Framework-first:
  the resource SHAPE lives here, once; a host materializes it with a single macro call +
  one migration (the `Samen.Scopes.Primitives.Blueprint.define_webhook/5`-style
  convention — a library-authored blueprint, not per-host hand-authored Ash code).

  `Samen.Approvals` (the T34 engine) is Ash-resource-based (AshStateMachine drives the
  exactly-once `pending -> approved | rejected` guard, §4.3), so — unlike the plain-Ecto
  `Samen.Reveal.{RevealRequest,RevealGrant,RevealAudit}` schemas that any host repo can
  reuse directly — every host wiring the engine needs its OWN compiled `Approval` Ash
  resource bound to its OWN repo (`postgres do repo(...) end` is compile-time-fixed).
  `define_approval/5` is that per-host materialization point.

  ## Shape (mirrors `SamenCore.Support.ApprovalsFixture.Approval`, the T34 in-tree
  reference — see that module for the full ADR-040 §4.1/§4.2/§4.3 rationale)

    * AshStateMachine lifecycle: `pending -> approved | rejected | cancelled`
      (illegal transitions refused by the machine — the exactly-once guard).
    * `org_id allow_nil? true` (the documented CoreAttributes exception, Identity.Org
      precedent) — NULL org = plane-global governance approval (reveal's `pii_reveal`
      kind), structurally hidden from tenant actors by `Samen.Policy.OrgScope`.
    * No persisted action inputs (§4.4): `{org_id, kind, subject_ref, requested_by,
      decided_by, reason, state, deadline_at, timestamps}` only.
    * Distinct-party is enforced by the DB CHECK the migration ships (the
      `apv_distinct_party` shape, T34-F1-tightened: a decided row MUST carry a non-NULL
      approver) — this macro defines the ASH side; the migration (see
      `samen_core/priv/test_repo/migrations/20260728150000_approvals_fixture.exs` for the
      canonical DDL a host copies in, renaming only the table/column abbrev prefix)
      defines the DB side.

  ## Deliberately NO AshOban expiry scan here

  `SamenCore.Support.ApprovalsFixture.Approval` (T34's own fixture) carries an AshOban
  `:expire_scan` trigger to prove the engine's `:expired` path end-to-end. A host
  materializing THIS macro for reveal only does not need it: reveal never sets
  `deadline_at` (`Samen.Reveal.Grants.approve/2` decides synchronously, in the SAME call,
  via `Samen.Reveal.ApprovalHandler`), so there is nothing for an expiry scan to sweep,
  and skipping it avoids requiring every adopting host to provision a new
  `:automation_timers` Oban queue just to materialize this resource (residual: a host
  later adding a GATED Ash-action client with deadline-driven expiry can add its own
  `ash_oban do triggers do ... end end` block directly on the generated resource, or this
  macro can grow an `oban: true` option — no code here forecloses that).

  ## Usage

      defmodule MyApp.Approvals do
        require Samen.Approvals.Blueprint

        Samen.Approvals.Blueprint.define_approval(
          MyApp.Approvals.Approval, :my_app, MyApp.Approvals, MyApp.Repo, "myabbrev"
        )

        use Ash.Domain, validate_config_inclusion?: false

        resources do
          resource(MyApp.Approvals.Approval)
        end
      end

  (`define_approval/5` expands to a top-level `defmodule MyApp.Approvals.Approval do ...
  end` — the same convention `Samen.Scopes.Primitives.Blueprint.define_webhook/5` etc.
  use, just invoked directly by the host instead of via an intermediate scope macro.)

  Deliberately NOT added to `:ash_domains` by this macro (the caller decides) — matching
  the T34 fixture's posture: this is a kernel-owned decision table, not a tenant-catalog
  resource, so keeping it out of the vault_declared_parity / catalog_parity sweep is the
  default (same posture as the automation/notification fixtures).
  """

  defmacro define_approval(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        The T35 host-materialized `Approval` resource (ADR-040 §4.1) — reveal grants'
        engine client on this host. See `Samen.Approvals.Blueprint` for the shape
        rationale; defined via `define_approval/5`, not hand-authored.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshStateMachine],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_approval")
          repo(unquote(repo))
        end

        state_machine do
          initial_states([:pending])
          default_initial_state(:pending)

          transitions do
            transition(:approve, from: :pending, to: :approved)
            transition(:reject, from: :pending, to: :rejected)
            transition(:cancel, from: :pending, to: :cancelled)
          end
        end

        attributes do
          # org_id declared HERE (allow_nil? true) so CoreAttributes' maybe_add skips it
          # — the documented Identity.Org exception (§4.1). NULL = plane-global (reveal).
          attribute(:org_id, :uuid, public?: true, allow_nil?: true)

          attribute(:kind, :string, public?: true, allow_nil?: false)
          attribute(:subject_ref, :string, public?: true, allow_nil?: false)
          attribute(:requested_by, :string, public?: true, allow_nil?: false)
          attribute(:decided_by, :string, public?: true)
          # PiiReasonScan-gated at write (Samen.Approvals); freeform, NOT vault-routed.
          attribute(:reason, :string, public?: true)
          attribute(:deadline_at, :utc_datetime_usec, public?: true)
          attribute(:requested_at, :utc_datetime_usec, public?: true)
          attribute(:decided_at, :utc_datetime_usec, public?: true)

          # Pre-declare the AshStateMachine state attribute so AbbrevStorage prefixes its
          # physical column (the ADR-037 §5.8 C2 self-qualifying-storage duty).
          attribute(:state, :atom,
            allow_nil?: false,
            default: :pending,
            public?: true,
            writable?: false,
            constraints: [one_of: [:pending, :approved, :rejected, :cancelled]]
          )
        end

        actions do
          defaults([:read])

          create :open do
            accept([
              :org_id,
              :kind,
              :subject_ref,
              :requested_by,
              :reason,
              :deadline_at,
              :requested_at
            ])
          end

          update :approve do
            accept([:decided_by])
            require_atomic?(false)
            change(set_attribute(:decided_at, &DateTime.utc_now/0))
            change(transition_state(:approved))
          end

          update :reject do
            accept([:decided_by])
            require_atomic?(false)
            change(set_attribute(:decided_at, &DateTime.utc_now/0))
            change(transition_state(:rejected))
          end

          update :cancel do
            accept([])
            require_atomic?(false)
            change(transition_state(:cancelled))
          end
        end

        policies do
          # Tenant-surface reads are org-scoped (NULL-org governance rows fall out for
          # tenant actors by OrgScope's fail-closed filter). The engine's own reads use
          # authorize?: false (a trusted kernel API, the Grants precedent) — unaffected.
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # Decide actions: the approver must be at least :admin (§4.5 tenant default).
          policy action([:approve, :reject]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end

          policy action_type([:create, :update, :destroy]) do
            authorize_if(always())
          end
        end
      end
    end
  end
end

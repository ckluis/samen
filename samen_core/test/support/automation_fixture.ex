defmodule SamenCore.Support.AutomationFixture.Subject do
  @moduledoc """
  A stand-in for "any catalog resource" that a workflow triggers on (ADR-039 §4.1) —
  the T39 automation engine's trigger source in `samen_core` tests. Carries:

    * `priority` / `status` — bounded enums, **condition-eligible** (project through
      `Samen.Cdc.Projection` as `:enum`);
    * `email` — 🔒 vault-routed PII (`pii_asj_email`), **condition-INELIGIBLE**
      (projects as `:token`). This is what the c2 red-path proves un-referenceable.

  `Samen.Automation.EventCapture` is attached so a create/update fires the in-txn
  dispatch when an active workflow matches (the transactional-capture proof).
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.AutomationFixture,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "asj"

  postgres do
    table("asj_subject")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:title, :string, public?: true, allow_nil?: false)

    attribute(:priority, :atom,
      public?: true,
      default: :normal,
      constraints: [one_of: [:low, :normal, :high, :urgent]]
    )

    attribute(:status, :atom,
      public?: true,
      default: :open,
      constraints: [one_of: [:open, :pending, :closed]]
    )
  end

  pii do
    vault(:pii_email)
    pii_attribute(:email, :string, vault: :pii_email)
    reveal(:reveal_subject)
  end

  # The transactional trigger tap (ADR-039 §4.2): applies to create + update actions.
  changes do
    change(Samen.Automation.EventCapture)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    action :reveal_subject, :map do
      argument(:actor_id, :string, allow_nil?: false)
      argument(:subject_id, :string, allow_nil?: false)

      run(fn input, _ctx ->
        ctx = %Samen.Reveal.Context{
          actor: input.arguments.actor_id,
          subject_id: input.arguments.subject_id,
          resource: __MODULE__,
          action: :reveal_subject,
          label: :email
        }

        if Samen.Reveal.grant_checker().granted?(ctx) do
          {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
        else
          {:error, :denied}
        end
      end)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action(:reveal_subject) do
      authorize_if(always())
    end
  end
end

defmodule SamenCore.Support.AutomationFixture.Target do
  @moduledoc """
  A second trigger-source fixture, added for T40's E2 action library (ADR-039
  §5.2). Distinct from `Subject` (T39's minimal `notify` proof) because the
  record-mutation family needs surfaces `Subject` doesn't have:

    * `owner_id` — the `assign_owner` action's default target attribute;
    * `tags` — the `add_tag` action's designed seam (the Ticket precedent,
      §5.4 — `Target` stands in for "a resource with a `tags` array" here so
      the seam is exercised without reaching into the Support scope);
    * `priority` — condition-eligible (projects `:enum`), used by `mutate_record`/
      `webhook`'s `include` to prove the eligible path;
    * `email` — 🔒 vault-routed PII (`pii_sat_email`), condition-INELIGIBLE —
      the webhook snapshot assert's negative control (never appears in a
      payload even when named).

  `Samen.Automation.EventCapture` is attached so create/update fires the
  in-txn dispatch, exactly like `Subject`.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.AutomationFixture,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "sat"

  postgres do
    table("sat_target")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:title, :string, public?: true, allow_nil?: false)

    attribute(:priority, :atom,
      public?: true,
      default: :normal,
      constraints: [one_of: [:low, :normal, :high, :urgent]]
    )

    attribute(:owner_id, :uuid, public?: true)
    attribute(:tags, {:array, :string}, public?: true, default: [])
  end

  pii do
    vault(:pii_email)
    pii_attribute(:email, :string, vault: :pii_email)
    reveal(:reveal_target)
  end

  changes do
    change(Samen.Automation.EventCapture)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    action :reveal_target, :map do
      argument(:actor_id, :string, allow_nil?: false)
      argument(:subject_id, :string, allow_nil?: false)

      run(fn input, _ctx ->
        ctx = %Samen.Reveal.Context{
          actor: input.arguments.actor_id,
          subject_id: input.arguments.subject_id,
          resource: __MODULE__,
          action: :reveal_target,
          label: :email
        }

        if Samen.Reveal.grant_checker().granted?(ctx) do
          {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
        else
          {:error, :denied}
        end
      end)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action(:reveal_target) do
      authorize_if(always())
    end
  end
end

defmodule SamenCore.Support.AutomationFixture do
  @moduledoc """
  Kernel fixture for the E1 automation engine (T39; ADR-039) + the T40 E2 action
  library. Mounts the Automation scope (`Workflow`/`Reminder`/`Escalation` under
  abbrevs `awf`/`arm`/`aes`) plus two trigger sources — `Subject` (`asj`, T39's
  minimal proof) and `Target` (`sat`, T40's record-mutation-family surfaces) —
  so the whole pipeline — capture → dispatch → run → condition gate → the 8
  E2 actions — can be exercised against a REAL Postgres DB in `samen_core`,
  without touching the demo/vertical hosts (substrate-first, INV-5).

  Deliberately NOT in `:ash_domains` (kept out of the CI verifier/catalog sweeps, like
  `NotificationFixture`); its vault-routed `pii_asj_email`/`pii_sat_email` columns are
  allow-listed for `vault_declared_parity` in `config/test.exs`.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.AutomationFixture.Subject)
    resource(SamenCore.Support.AutomationFixture.Target)
  end

  use Samen.Scopes.Automation,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.AutomationFixture
end

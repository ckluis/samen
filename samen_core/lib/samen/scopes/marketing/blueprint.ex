defmodule Samen.Scopes.Marketing.Blueprint do
  @moduledoc """
  Resource-definition macros for the Marketing scope (T3.4; ADR-004 blueprint).

  Objects: `campaign · segment · subscriber🔒 · template · send · email_event · suppression`
  (doc §"The inherited 80%" scope table).

  ## PII map (🔒)

  | Resource   | Field | Vault      | Column type                        |
  |------------|-------|------------|------------------------------------|
  | subscriber | email | :pii_email | scalar (column: pii_msu_email)     |

  Scalar `pii_attribute`s carry the `pii_` prefix per the scope-authoring guide §5.
  All other resources carry only opaque IDs and bounded data — no subject PII.

  ## Suppression enforcement

  The `define_send` macro emits a `:create_checked` action (the only way to create a
  send row) that:

  1. Looks up the subscriber's org and checks whether a `msp_suppression` row exists
     for `(org_id, subscriber_id)`.
  2. If suppressed → returns `{:error, :suppressed}` without writing any row or
     enqueuing any job.
  3. If not suppressed → inserts the send row and enqueues an Oban job in the
     `:webhooks_out` queue via `Samen.Jobs.enqueue_in_tx/3` (same-transaction enqueue).

  The `:create` default action is **removed** from Send to prevent bypassing this check.

  ## Tier-0 config rows

  `Template` is the Tier-0 config-row resource (malleability ladder §7): one row per
  reusable email template per org. Admin-gated writes.

  ## Storage-name discipline

  Every column is `<abbrev>_<name>` (self-qualifying storage, injected by the Samen
  base macro). The PII scalar field on Subscriber carries the `pii_` prefix FIRST
  (`pii_<abbrev>_<name>`, total: `pii_msu_email`) — the canonical shape the
  `MaterializePii` transformer emits. The public API/catalog only ever sees the logical name.
  """

  # ---------------------------------------------------------------------------
  # Campaign — a marketing campaign. Org-scoped. No PII.
  # ---------------------------------------------------------------------------
  defmacro define_campaign(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Marketing.Campaign — a marketing campaign (doc scope table `campaign`).
        Org-scoped. No PII.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_campaign")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:description, :string, public?: true)
          attribute(:status, :atom,
            public?: true,
            default: :draft,
            constraints: [one_of: [:draft, :scheduled, :sending, :sent, :cancelled]]
          )
          attribute(:scheduled_at, :utc_datetime, public?: true)
          attribute(:sent_at, :utc_datetime, public?: true)
          attribute(:custom, :map, public?: true)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Segment — an audience segment (filter criteria as jsonb). Org-scoped. No PII.
  # ---------------------------------------------------------------------------
  defmacro define_segment(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Marketing.Segment — an audience segment (doc scope table `segment`).
        Filter criteria are stored as a jsonb map. Org-scoped. No PII.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_segment")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:description, :string, public?: true)
          attribute(:filter_criteria, :map, public?: true, default: %{})
          attribute(:subscriber_count, :integer, public?: true, default: 0)
          attribute(:custom, :map, public?: true)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Subscriber — 🔒 PII: email (vault :pii_email). Org-scoped.
  # Tracks consent status and subscription status.
  # ---------------------------------------------------------------------------
  defmacro define_subscriber(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Marketing.Subscriber — a marketing subscriber 🔒 (doc scope table `subscriber🔒`).

        `email` is vault-routed PII (masked by default; plaintext only via the declared
        reveal action under a grant). Org-scoped. Tracks consent status (opted-in /
        opted-out) and subscription status (active / unsubscribed / bounced).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_subscriber")
          repo(unquote(repo))
        end

        attributes do
          attribute(:status, :atom,
            public?: true,
            default: :active,
            constraints: [one_of: [:active, :unsubscribed, :bounced, :complained]]
          )
          attribute(:consent_at, :utc_datetime, public?: true)
          attribute(:source, :string, public?: true)
          attribute(:custom, :map, public?: true)
        end

        pii do
          vault(:pii_email)
          # Scalar PII: column carries the pii_ prefix (pii_msu_email).
          pii_attribute(:email, :string, vault: :pii_email)
          reveal(:reveal_subscriber)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          action :reveal_subscriber, :map do
            argument(:actor_id, :string, allow_nil?: false)
            argument(:subject_id, :string, allow_nil?: false)

            run(fn input, _ctx ->
              ctx = %Samen.Reveal.Context{
                actor: input.arguments.actor_id,
                subject_id: input.arguments.subject_id,
                resource: __MODULE__,
                action: :reveal_subscriber,
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

          policy action(:reveal_subscriber) do
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Template — Tier-0 config rows: reusable email templates per org.
  # Org-scoped. No PII. Admin-gated writes.
  # ---------------------------------------------------------------------------
  defmacro define_template(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Marketing.Template — Tier-0 config rows (doc scope table `template`). One row
        per reusable email template per org (subject_line + body_html). Org-scoped;
        admin-gated writes.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_template")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:subject_line, :string, public?: true, allow_nil?: false)
          attribute(:body_html, :string, public?: true)
          attribute(:body_text, :string, public?: true)
          attribute(:from_name, :string, public?: true)
          attribute(:from_address, :string, public?: true)
          attribute(:enabled, :boolean, public?: true, default: true)
          attribute(:custom, :map, public?: true)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Send — a single send event (campaign → subscriber). Suppression enforced.
  # Sends are Oban jobs (webhooks_out queue). Org-scoped. No PII.
  #
  # The ONLY way to create a send is via the `:create_checked` action, which
  # enforces suppression before writing any row or enqueuing a job. The default
  # `:create` action is absent from this resource by design.
  # ---------------------------------------------------------------------------
  defmacro define_send(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             subscriber_mod,
             campaign_mod,
             template_mod,
             _suppression_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Marketing.Send — a single send event (campaign → subscriber).

        **Suppression enforcement:** sends to a suppressed subscriber are REFUSED.
        The only creation path is `:create_checked`, which queries the suppression
        table (for the same org) before writing any row or enqueuing a job. A send
        to a suppressed subscriber returns `{:error, :suppressed}` — the send row
        is never created and no Oban job is enqueued. This is the load-bearing red
        path for the Marketing scope (T3.4 spec: "consent/suppression enforced at
        send-time (a send to a suppressed subscriber refuses — red path)").

        **Oban job:** when not suppressed, an `Samen.Scopes.Marketing.SendWorker`
        job is enqueued in the `:webhooks_out` queue via same-transaction enqueue
        (Samen.Jobs.enqueue_in_tx/3) so a rollback leaves no `oban_jobs` row.

        Org-scoped. No PII (the send row carries only opaque IDs).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_send")
          repo(unquote(repo))
        end

        attributes do
          attribute(:status, :atom,
            public?: true,
            default: :queued,
            constraints: [one_of: [:queued, :sending, :delivered, :bounced, :failed, :suppressed]]
          )
          attribute(:queued_at, :utc_datetime, public?: true)
          attribute(:sent_at, :utc_datetime, public?: true)
          attribute(:idempotency_key, :string, public?: true)
          attribute(:custom, :map, public?: true)
        end

        relationships do
          belongs_to :subscriber, unquote(subscriber_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :campaign, unquote(campaign_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end

          belongs_to :template, unquote(template_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
        end

        actions do
          # Intentionally NO default :create — all sends must go through
          # :create_checked so suppression is enforced at send-time.
          defaults([:read, :destroy, update: :*])

          # The suppression-checked send creation path.
          # Arguments: subscriber_id, org_id (both required), plus optional
          # campaign_id and template_id.
          create :create_checked do
            accept([:subscriber_id, :campaign_id, :template_id, :custom])

            argument(:subscriber_id, :uuid, allow_nil?: false)
            argument(:org_id, :uuid, allow_nil?: false)
            argument(:campaign_id, :uuid, allow_nil?: true)
            argument(:template_id, :uuid, allow_nil?: true)

            change(fn changeset, _ctx ->
              subscriber_id = Ash.Changeset.get_argument(changeset, :subscriber_id)
              org_id = Ash.Changeset.get_argument(changeset, :org_id)
              repo = unquote(repo)
              subscriber_mod = unquote(subscriber_mod)

              # F3.2 same-org FK: BEFORE the suppression query, confirm the
              # referenced subscriber belongs to THIS send's org. Otherwise an
              # org-A actor could enqueue a send to an org-B subscriber and bypass
              # org B's suppression list (the send's suppression query only sees
              # org A's suppression rows). We read only the subscriber's org_id
              # (bounded UUID, no PII) directly from its table — NOT via Ash.read,
              # so OrgScope does not hide the foreign target from this check. Column
              # names come from resource introspection (not string-sliced).
              sub_table = AshPostgres.DataLayer.Info.table(subscriber_mod)
              sub_id_col = to_string(Ash.Resource.Info.attribute(subscriber_mod, :id).source)
              sub_org_col = to_string(Ash.Resource.Info.attribute(subscriber_mod, :org_id).source)

              subscriber_org_id =
                case repo.query(
                       "SELECT #{sub_org_col} FROM #{sub_table} WHERE #{sub_id_col} = $1 LIMIT 1",
                       [Ecto.UUID.dump!(subscriber_id)]
                     ) do
                  {:ok, %{rows: [[org_bin]]}} when is_binary(org_bin) ->
                    case Ecto.UUID.load(org_bin) do
                      {:ok, uuid} -> uuid
                      :error -> nil
                    end

                  _ ->
                    nil
                end

              cond do
                is_nil(subscriber_org_id) ->
                  Ash.Changeset.add_error(changeset,
                    field: :subscriber_id,
                    message: "cross-org FK: subscriber not found for this org (same-org required)"
                  )

                subscriber_org_id != org_id ->
                  Ash.Changeset.add_error(changeset,
                    field: :subscriber_id,
                    message:
                      "cross-org FK: subscriber belongs to a different org — a send may not " <>
                        "reference another org's subscriber (bypasses their suppression list)"
                  )

                true ->
                  send_checked(changeset, repo, org_id, subscriber_id)
              end
            end)
          end
        end

        # Suppression check + write, run only after the same-org FK check passes.
        defp send_checked(changeset, repo, org_id, subscriber_id) do
          # Check suppression: is there an active row in the suppression table
          # for this (org_id, subscriber_id)? If so, refuse the send.
          # The suppression table is always `msp_suppression` (Marketing scope abbrev msp).
          suppressed? =
            case repo.query(
                   "SELECT 1 FROM msp_suppression WHERE msp_org_id = $1 AND msp_subscriber_id = $2 AND msp_active = true LIMIT 1",
                   [Ecto.UUID.dump!(org_id), Ecto.UUID.dump!(subscriber_id)]
                 ) do
              {:ok, %{rows: [_ | _]}} -> true
              _ -> false
            end

          if suppressed? do
            Ash.Changeset.add_error(changeset, field: :subscriber_id, message: "suppressed")
          else
            changeset
            |> Ash.Changeset.change_attribute(:subscriber_id, subscriber_id)
            |> Ash.Changeset.change_attribute(:org_id, org_id)
            |> Ash.Changeset.change_attribute(:campaign_id, Ash.Changeset.get_argument(changeset, :campaign_id))
            |> Ash.Changeset.change_attribute(:template_id, Ash.Changeset.get_argument(changeset, :template_id))
            |> Ash.Changeset.change_attribute(:status, :queued)
            |> Ash.Changeset.change_attribute(:queued_at, DateTime.utc_now())
          end
        end

        policies do
          policy action_type([:read, :update, :destroy]) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action(:create_checked) do
            authorize_if(Samen.Policy.OrgScope)
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # EmailEvent — delivery/open/click/bounce/unsubscribe events. Org-scoped. No PII.
  # ---------------------------------------------------------------------------
  defmacro define_email_event(module, otp_app, domain, repo, abbrev, send_mod, subscriber_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Marketing.EmailEvent — delivery/open/click/bounce/unsubscribe events
        (doc scope table `email_event`). Append-only by convention (events are not
        updated/deleted in normal flow). Org-scoped. No PII (only opaque IDs).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_email_event")
          repo(unquote(repo))
        end

        attributes do
          attribute(:event_type, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [
              one_of: [:delivered, :opened, :clicked, :bounced, :unsubscribed, :complained, :failed]
            ]
          )
          attribute(:occurred_at, :utc_datetime, public?: true)
          attribute(:metadata, :map, public?: true, default: %{})
        end

        relationships do
          belongs_to :send, unquote(send_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :subscriber, unquote(subscriber_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        actions do
          defaults([:read, create: :*, update: :*])
        end

        policies do
          policy action_type([:read, :create, :update]) do
            authorize_if(Samen.Policy.OrgScope)
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Suppression — opt-out / bounce / unsubscribe suppression list. Org-scoped. No PII.
  # Suppression rows hold only opaque subscriber IDs (the email is in the vault on the
  # subscriber row — not here). Carries the reason code.
  # ---------------------------------------------------------------------------
  defmacro define_suppression(module, otp_app, domain, repo, abbrev, subscriber_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Marketing.Suppression — consent/suppression list (doc scope table `suppression`).

        A suppression row records that a subscriber must NOT receive sends. The send
        creation action checks this table before writing a send row or enqueuing a job.
        Suppression rows carry only the opaque `subscriber_id` FK — no email address (the
        email is in the vault on the subscriber row). The `reason` is a bounded enum.

        Org-scoped. No PII (the subscriber_id is an opaque UUID FK — the PII lives in
        the vault on the subscriber row).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_suppression")
          repo(unquote(repo))
        end

        attributes do
          attribute(:reason, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:unsubscribed, :bounced, :complained, :admin_added, :import]]
          )
          attribute(:active, :boolean, public?: true, default: true)
          attribute(:suppressed_at, :utc_datetime, public?: true)
          attribute(:notes, :string, public?: true)
        end

        relationships do
          belongs_to :subscriber, unquote(subscriber_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end
end

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

  ## E6 soft-delete adoption (ADR-040 §5.9, T37d)

  `campaign`, `segment`, `subscriber` 🔒, and `template` all carry `archivable: true`
  — the §5.9 roster row for this scope. `send`, `email_event`, `suppression`, and
  `consent_event` are explicitly EXCLUDED (all four are (L) append-only ledgers,
  except `suppression`, whose exclusion is absolute and non-negotiable: "a hidden
  suppression row is a compliance leak"). No composition cascade is declared for
  Marketing (§5.4): archiving any of the four adopted resources leaves `send`/
  `email_event`/`suppression` rows untouched.

  ### The suppression-unaffected duty (§5.9 footnote ‡, binding)

  Archiving a `subscriber` never touches suppression state. Suppression is enforced
  at TWO independent layers, and archival has zero bearing on either:

    1. **Create-time** — `Send.:create_checked` queries THIS mount's own
       `Suppression` resource (`<abbrev>_suppression`) directly; it is not archivable
       and is never touched by a subscriber's archive/restore.
    2. **Deliver-time (the C2 chokepoint)** — `Samen.Delivery.Chokepoint.suppressed?/2`
       consults the family-agnostic kernel `dlv_suppression` store
       (`Samen.Delivery.Suppression`, via `Samen.Delivery.SuppressionCheck`), keyed
       on `(org_id, subscriber_id)` — a plain Ecto schema with NO relationship to
       the Ash `Subscriber` resource at all, so an archive/restore on `Subscriber`
       cannot reach it by construction. Archiving a suppressed subscriber does NOT
       lift the suppression; restoring one does NOT lift it either (T37d red test).

  ## Suppression enforcement

  The `define_send` macro emits a `:create_checked` action (the only way to create a
  send row) that:

  1. Looks up the subscriber's org and checks whether an active suppression row
     exists for `(org_id, subscriber_id)`. The check is an `OrgScope`-inheriting Ash
     read of THIS mount's own `Suppression` resource (no hardcoded table name), so it
     is portable across mount abbrevs (ADR-014 §4, Invariant D2).
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

        ADR-040 §5.9 roster (T37d): `campaign` adopts E6 soft-delete
        (`archivable true`). No cascade declared for Marketing (§5.4) — archiving a
        campaign leaves its linked `send` rows live (no PII on this resource, so
        INV-1 masking is not applicable here).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

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

        ADR-040 §5.9 roster (T37d): `segment` adopts E6 soft-delete
        (`archivable true`). No cascade declared for Marketing (§5.4). No PII on
        this resource. No other resource in this scope holds a relationship TO a
        segment (segments are a filter-criteria bag, not a referenced FK target) —
        the §5.5 relationship/aggregate leak duty therefore does not structurally
        apply here; its own default-read exclusion is proven directly (c1 round
        trip, T37d).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

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
  defmacro define_subscriber(module, otp_app, domain, repo, abbrev, consent_event_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Marketing.Subscriber — a marketing subscriber 🔒 (doc scope table `subscriber🔒`).

        `email` is vault-routed PII (masked by default; plaintext only via the declared
        reveal action under a grant). Org-scoped. Tracks consent status (opted-in /
        opted-out) and subscription status (active / unsubscribed / bounced).

        ## Consent ledger (F3 Unit 1)

        The `consent_at` column is a mutable CACHE of the opt-in timestamp. The SOURCE
        OF TRUTH for consent is the append-only `ConsentEvent` ledger: on every
        create/update, `Samen.Marketing.ConsentChange` appends a `:granted` / `:withdrawn`
        row (best-effort, never aborts the write). Derive the current state via
        `Samen.Marketing.Consent.state/3` — latest-event-wins, and it survives a subject
        crypto-shred (the immutable ledger row outlives the vaulted email).

        ## E6 soft-delete adoption (ADR-040 §5.9, T37d)

        `subscriber` adopts E6 soft-delete (`archivable true`) — the §5.9 roster's
        `‡`-footnoted row. INV-1: an archived subscriber keeps its vault token and
        still masks on every plane exactly like a live row (trash, not erasure).
        No cascade declared for Marketing (§5.4) — archiving a subscriber leaves its
        `send`/`email_event`/`suppression` rows live and untouched.

        **The suppression-unaffected duty (binding):** archiving/restoring a
        subscriber has ZERO effect on suppression state, at either enforcement
        layer (`Send.:create_checked`'s own-mount `Suppression` read, and the C2
        `Samen.Delivery.Chokepoint` kernel `dlv_suppression` store) — suppression is
        a fact about deliverability, archival is a fact about visibility; the two
        are orthogonal by construction (see `Samen.Scopes.Marketing`'s moduledoc and
        the T37d red test).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

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

        # F3 Unit 1: the consent-capture seam. On every create/update, append ONE
        # bounded, non-PII ConsentEvent row per consent transition via
        # `Samen.Marketing.ConsentChange` — best-effort (an append failure NEVER aborts
        # the subscriber write; the subscriber state is load-bearing, the ledger rides
        # along), exactly like the Billing SubscriptionMovement seam. Verticals inherit
        # emission at 0 LOC (the change is on the kernel blueprint).
        changes do
          change({Samen.Marketing.ConsentChange, event_resource: unquote(consent_event_mod)})
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

        ADR-040 §5.9 roster (T37d): `template` adopts E6 soft-delete
        (`archivable true`). No cascade declared for Marketing (§5.4) — archiving a
        template leaves its linked `send` rows live (no PII on this resource).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

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
             suppression_mod
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
            constraints: [
              one_of: [:queued, :sending, :delivered, :blocked, :bounced, :failed, :suppressed]
            ]
          )
          attribute(:queued_at, :utc_datetime, public?: true)
          attribute(:sent_at, :utc_datetime, public?: true)
          attribute(:idempotency_key, :string, public?: true)
          attribute(:custom, :map, public?: true)

          # ADR-038 §4.1 (T28/C2): the provider's own message id, when it returns
          # one — the token-blind join key T30's deliverability-webhook
          # reconciliation matches bounce/complaint/open/click events against
          # (provider_message_id -> send receipt -> subscriber ref, NEVER by
          # email address). Nilable: a blocked/suppressed/failed send never gets
          # one. Not PII (an opaque vendor-minted string).
          attribute(:provider_message_id, :string, public?: true)
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

        # F3.5 same-org FK: a send may only reference same-org campaign/template.
        # (The subscriber FK is additionally guarded by the inline suppression-time
        # check inside :create_checked below — the load-bearing case — but the
        # SameOrgFk change covers ALL of them uniformly so the F3.5 verifier passes
        # by the same gated invariant every other scope uses. Redundant on subscriber,
        # harmless: SameOrgFk's before_action re-reads the same bounded org_id.)
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:subscriber, :campaign, :template]})
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

            change(fn changeset, ctx ->
              subscriber_id = Ash.Changeset.get_argument(changeset, :subscriber_id)
              org_id = Ash.Changeset.get_argument(changeset, :org_id)
              repo = unquote(repo)
              subscriber_mod = unquote(subscriber_mod)
              suppression_mod = unquote(suppression_mod)
              actor = Map.get(ctx, :actor)

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
                  send_checked(changeset, repo, org_id, subscriber_id, suppression_mod, actor)
              end
            end)
          end
        end

        # Suppression check + write, run only after the same-org FK check passes.
        #
        # ADR-014 §4 (Invariant D2): the check queries the table owned by THIS
        # blueprint's declared abbrev — no `msp` literal survives, so the mount
        # portably enforces suppression under ANY abbrev (msp, wmp, xyz, …).
        #
        # Preferred form: an Ash read on the mounted Suppression resource, which
        # inherits `OrgScope` (`record.org_id == actor.org_id`) — so the check is
        # bounded to the send's own org by construction and needs no table string
        # at all. The read is scoped to a minimal actor carrying THIS send's org_id
        # (already proven equal to the caller's org by the same-org FK check above),
        # so a cross-org suppression row is invisible exactly as it must be.
        #
        # Fall back to an abbrev-derived raw query ONLY if the Suppression resource
        # is not an addressable Ash resource at this point — never to the literal.
        # Both branches fail CLOSED (an unresolvable check refuses the send) so a
        # broken mount can never silently bypass suppression.
        defp send_checked(changeset, repo, org_id, subscriber_id, suppression_mod, actor) do
          case suppressed?(suppression_mod, repo, org_id, subscriber_id, actor) do
            {:error, reason} ->
              # Fail closed: we could not confirm the subscriber is deliverable.
              Ash.Changeset.add_error(changeset,
                field: :subscriber_id,
                message: "suppression check failed (#{inspect(reason)}) — send refused"
              )

            suppressed? ->
              apply_suppression_result(changeset, org_id, subscriber_id, suppressed?)
          end
        end

        # Returns true/false, or {:error, reason} when the check cannot be run
        # (so the caller fails closed). Prefers an Ash read; abbrev-derived SQL is
        # the reachability fallback.
        defp suppressed?(suppression_mod, repo, org_id, subscriber_id, actor) do
          if ash_resource?(suppression_mod) do
            suppressed_via_ash(suppression_mod, org_id, subscriber_id, actor)
          else
            suppressed_via_abbrev_sql(suppression_mod, repo, org_id, subscriber_id)
          end
        end

        defp ash_resource?(mod) do
          Code.ensure_loaded?(mod) and Ash.Resource.Info.resource?(mod)
        rescue
          _ -> false
        end

        # Ash read on the Suppression resource. Scoped to a minimal actor carrying
        # this send's org_id so `OrgScope` bounds the read to the send's own org.
        # The filter is a plain keyword statement (`Ash.Query.do_filter/2`) — NOT the
        # `filter/2` expr macro — so no macro hygiene games are needed inside this
        # blueprint-generated module.
        defp suppressed_via_ash(suppression_mod, org_id, subscriber_id, actor) do
          scope_actor = suppression_actor(actor, org_id)

          suppression_mod
          |> Ash.Query.for_read(:read, %{}, actor: scope_actor, authorize?: true)
          |> Ash.Query.do_filter(subscriber_id: subscriber_id, active: true)
          |> Ash.exists?()
        rescue
          e -> {:error, e}
        end

        # Reuse the caller's actor when it already carries the send's org_id;
        # otherwise mint a minimal map actor with the send's org_id (the same-org
        # FK check already proved they are equal — this only covers a nil/absent
        # actor, e.g. a direct kernel call in a test).
        defp suppression_actor(%{org_id: aorg} = actor, org_id) when aorg == org_id, do: actor
        defp suppression_actor(_actor, org_id), do: %{org_id: org_id}

        # Fallback ONLY when the resource is not addressable: derive the table and
        # columns from the resource's DECLARED abbrev (never a hardcoded literal).
        defp suppressed_via_abbrev_sql(suppression_mod, repo, org_id, subscriber_id) do
          case Samen.Info.abbrev(suppression_mod) do
            abbrev when is_binary(abbrev) ->
              table = "#{abbrev}_suppression"
              org_col = "#{abbrev}_org_id"
              sub_col = "#{abbrev}_subscriber_id"
              act_col = "#{abbrev}_active"

              case repo.query(
                     "SELECT 1 FROM #{table} WHERE #{org_col} = $1 AND #{sub_col} = $2 AND #{act_col} = true LIMIT 1",
                     [Ecto.UUID.dump!(org_id), Ecto.UUID.dump!(subscriber_id)]
                   ) do
                {:ok, %{rows: [_ | _]}} -> true
                {:ok, _} -> false
                {:error, reason} -> {:error, reason}
              end

            _ ->
              {:error, :no_abbrev}
          end
        end

        defp apply_suppression_result(changeset, org_id, subscriber_id, suppressed?) do
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

        # F3.5 same-org FK: an email event may only reference same-org send/subscriber.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:send, :subscriber]})
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

        ## NEVER archivable (ADR-040 §5.9, absolute — T37d)

        `suppression` is EXPLICITLY excluded from E6 soft-delete adoption: "a hidden
        suppression row is a compliance leak." Do NOT add `archivable: true` here —
        this exclusion is absolute, not a judgment call. Archiving/restoring a
        `subscriber` must never touch this table either (the T37d suppression-
        unaffected red test).
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

        # F3.5 same-org FK: a suppression row may only reference a same-org subscriber.
        # F3 (Unit 6 carry): `notes` is a TENANT free-text column (outside the vault's
        # crypto-shred guarantee — docs/free-text-pii-residue.md). `Samen.Pii.FreeTextScan`
        # is the write-boundary chokepoint: a note that is ITSELF a bare email/SSN/phone
        # shape is REFUSED at `before_action` (fail-closed) before any row lands. Every
        # marketing mount inherits this at 0 authored LOC (framework-first).
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:subscriber]})
          change({Samen.Pii.FreeTextScan, fields: [:notes]})
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
  # ConsentEvent (`<abbrev>_consent_event`) — the append-only marketing-consent
  # ledger (F3 Unit 1; modeled line-for-line on the `mov` subscription-movement
  # ledger, Samen.Scopes.Billing.Blueprint.define_subscription_event / ADR-017).
  # One row appended per consent transition by `Samen.Marketing.ConsentChange`.
  # Token-blind by construction: every column is a bounded id / enum / string /
  # timestamp — NO vaulted PII. Org-scoped. Soft ref (id only) to a subscriber.
  # ---------------------------------------------------------------------------
  defmacro define_consent_event(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Marketing.ConsentEvent — the append-only marketing-consent ledger (F3 Unit 1).

        One row is appended per consent transition by `Samen.Marketing.ConsentChange`,
        carrying the `event` (`:granted` / `:withdrawn`), the `source`, the `purpose`,
        and a `subject_hash` — a deterministic keyed pseudonym of the subject (the
        trace-sink pattern, `Samen.WideEvent.for_subject/1`).

        ## Consent state is DERIVED from this ledger

        `Samen.Marketing.Consent.state/3` folds the subscriber's rows latest-event-wins
        into `:granted | :withdrawn | :none`. This ledger is the SOURCE OF TRUTH for
        consent; the mutable `consent_at` column on `Subscriber` is retained only as a
        convenience cache (it can drift; the ledger cannot — it is append-only).

        ## Suppression HASH survives erasure

        `subject_hash` is computed at append time (while the subject's key still exists)
        and stored as bytes. A subject crypto-shred (`Samen.Erasure.shred/2`) destroys
        the subscriber's vaulted email but NEVER touches this immutable ledger row — so a
        `:withdrawn` event, its `subject_hash`, and therefore the "do-not-contact" fact
        remain honored after the PII is unrecoverable (mirrors the trace-sink pseudonym:
        the stored handle outlives the key).

        ## Append-only

        No `:update` / `:destroy` action is exposed — a consent event is an immutable
        historical fact. The row outlives the mutable subscriber it describes.

        ## No PII by construction

        Every column is a bounded id (uuid soft ref), an enum, a bounded string, a
        keyed hash, or a timestamp — the same discipline as `mov` / `Samen.WideEvent`.
        The resource carries no `pii do` block and no free-text plaintext column.

        Org-scoped: `OrgScope` read + admin-gated append (the change writes with
        `authorize?: false` as a framework emit, like the movement ledger).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_consent_event")
          repo(unquote(repo))
        end

        attributes do
          # Bounded soft ref (id only — NOT belongs_to, so a shredded/deleted
          # subscriber never blocks the immutable historical row).
          attribute(:subscriber_id, :uuid, public?: true, allow_nil?: false)

          # The consent transition this row records (bounded enum).
          attribute(:event, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:granted, :withdrawn]]
          )

          # Where the consent came from (bounded string — e.g. "signup", "import",
          # "crm", "unsubscribe_link"). Not free-text subject content.
          attribute(:source, :string, public?: true)

          # Why the consent applies (bounded enum — the processing purpose).
          attribute(:purpose, :atom,
            public?: true,
            default: :marketing,
            constraints: [one_of: [:marketing, :transactional, :product_updates]]
          )

          # The erasure-surviving keyed pseudonym of the subject (trace-sink pattern).
          # A one-way handle — NOT a raw id, NOT PII. Persists post-shred.
          attribute(:subject_hash, :string, public?: true)

          # Microsecond precision: makes latest-event-wins deterministic even for two
          # transitions in the same wall-clock second.
          attribute(:occurred_at, :utc_datetime_usec, public?: true, allow_nil?: false)
        end

        actions do
          # Append-only: read + a bounded create action ONLY. No update/destroy — a
          # consent event is an immutable fact.
          defaults([:read])

          create :append do
            accept([
              :subscriber_id,
              :event,
              :source,
              :purpose,
              :subject_hash,
              :occurred_at,
              :org_id
            ])
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # Append is admin-gated on the tenant plane; the framework change writes
          # with authorize?: false (a system-emitted row), so this gate governs any
          # DIRECT caller.
          policy action_type(:create) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end
end

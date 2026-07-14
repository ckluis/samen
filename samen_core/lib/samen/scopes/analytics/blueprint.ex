defmodule Samen.Scopes.Analytics.Blueprint do
  @moduledoc """
  Resource-definition macro for the Analytics scope (WS-B / G12; ADR-021).

  Object: `product_event🔓` (`pae`) — the governed, token-blind product-analytics
  event ledger. One `use Samen.Scopes.Analytics` in a host domain expands into
  `<Namespace>.ProductEvent` in the host's `otp_app`/`repo`, so its columns catalogue
  into the host's `tam_table`/`fld_field`, the host verifiers scan it, and it mirrors
  through the vault-excluded CDC projection for free.

  ## Token-blind by construction (the moat — ADR-021 §3)

  Every column is a bounded id (uuid ref), a bounded enum/string label, a
  per-subject HMAC pseudonym token, a bounded map, or a timestamp — the same
  discipline as `mov`/`WideEvent`. There is NO `pii do` block and NO subject
  identity column: a name/email/freeform value CANNOT enter a `pae` row by
  construction. `pae_actor_ref` is a per-subject-keyed HMAC pseudonym
  (`Samen.WideEvent.for_subject/2`), NOT a raw user id — so destroying the subject's
  KMS DEK on shred renders it unlinkable across live + CDC mirror simultaneously
  (erasure for free), and there is no subject column to redact.

  ## Append-only

  No `:update` / `:destroy` action is exposed — a captured event is an immutable
  historical fact. Rows are written ONLY through `Samen.Analytics.track/1` (the
  best-effort capture API), which validates the event name against the bounded
  `Samen.Analytics.Catalog` and refuses any PII-bearing payload BEFORE this
  resource is ever touched (the payload is dropped, never persisted).
  """

  # ---------------------------------------------------------------------------
  # ProductEvent (`pae`) — the append-only, token-blind product-analytics ledger
  # (WS-B / G12; ADR-021). One row per captured product event, appended by
  # `Samen.Analytics.track/1`. Org-scoped. No PII by construction.
  # ---------------------------------------------------------------------------
  defmacro define_product_event(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Analytics.ProductEvent (`pae`) — the governed, token-blind product-analytics
        event ledger (ADR-021; WS-B / G12). One row is appended per captured product
        event by `Samen.Analytics.track/1`, carrying:

          * `org_id` — the tenant (bounded id);
          * `actor_ref` — a per-subject HMAC pseudonym (`WideEvent.for_subject/2`),
            NOT a raw user id, NOT PII (nil when the subject is absent/shredded);
          * `event_name` — an enum from the bounded `Samen.Analytics.Catalog`
            (never freeform); the resource constraint mirrors the catalog;
          * `entity_ref` — a bounded id/token of the entity the event is about;
          * `props` — a bounded map, structurally validated against the event's
            catalog key schema (no freeform string keys) and value-classified against
            the PII oracle at capture (a PII-shaped value is refused before write);
          * `occurred_at` — when the event happened.

        ## Append-only + token-blind

        No update/destroy is exposed (an event is an immutable fact). Every column is
        a bounded id/enum/token/map/timestamp — no `pii do` block, no subject
        identity column. This is what lets `pae` mirror cleanly through the
        vault-excluded CDC projection (`project(ProductEvent)` returns all columns)
        and inherit post-shred erasure for free (the pseudonym's key is destroyed).

        Org-scoped: `OrgScope` read + admin-gated create (the `track/1` framework
        emit writes with `authorize?: false`, like the notifications engine + `mov`).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_product_event")
          repo(unquote(repo))
        end

        attributes do
          # A per-subject HMAC pseudonym (WideEvent.for_subject/2) — a one-way handle
          # keyed on the subject's own KMS DEK, NOT a raw user id and NOT PII. Nil
          # when the subject is absent or already shredded (the row still records the
          # org-scoped fact; it simply loses the actor linkage). Bounded, opaque.
          attribute(:actor_ref, :string, public?: true)

          # The event name — an enum from the bounded Samen.Analytics.Catalog. NOT
          # freeform: track/1 refuses an unregistered name before this resource is
          # touched, and the DB-level constraint mirrors the catalog as a second gate.
          attribute(:event_name, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [
              one_of: [
                :"session.signed_in",
                :"first_run.completed",
                :"record.created",
                :"search.used",
                :"flag.assignment"
              ]
            ]
          )

          # A bounded id/token of the entity the event is about (a record id, a flag
          # name token, etc.). Opaque, non-PII.
          attribute(:entity_ref, :string, public?: true)

          # The bounded event kind (a coarse, low-cardinality classifier for grouping
          # in the seed funnel/retention read). Derived from the event name.
          attribute(:event_kind, :atom,
            public?: true,
            constraints: [
              one_of: [:session, :onboarding, :record, :search, :experiment]
            ]
          )

          # The structurally-validated props map. Keys are bounded catalog labels
          # (track/1 default-denies unregistered keys) and values are PII-classified
          # at capture. Never a freeform-string carrier by contract.
          attribute(:props, :map, public?: true, default: %{})

          attribute(:occurred_at, :utc_datetime, public?: true, allow_nil?: false)
        end

        actions do
          # Append-only: read + a bounded create action ONLY. No update/destroy — a
          # captured event is an immutable fact. (Erasure is via the subject's KMS DEK
          # destruction rendering actor_ref unlinkable, not a per-row destroy.)
          defaults([:read])

          create :append do
            accept([
              :actor_ref,
              :event_name,
              :entity_ref,
              :event_kind,
              :props,
              :occurred_at,
              :org_id
            ])
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # Append is admin-gated on the tenant plane; the framework track/1 emit
          # writes with authorize?: false (a system-emitted row, like the
          # notifications engine + mov), so this gate governs any DIRECT caller.
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

defmodule Samen.Scopes.Views.Blueprint do
  @moduledoc """
  Resource-definition macro for the **Views** scope (G10 saved views, T58).

  One resource: **`SavedView`** — a per-user, org-scoped, NAMED snapshot of a list/view
  surface's UI state (the chosen view TYPE + a serialized, non-secret params blob). It is
  the persistence half of the framework saved-views capability; the samen_web
  `Samen.Web.SavedViews` module owns serialization, the untrusted-restore whitelist, and
  the stored-filter PII gate.

  ## Shape (mirrors the `owner_id` + `:map` blob precedent — `Work.Task`)

    * `name`       — the user-facing label ("My open deals"). Unique per
      `(org_id, owner_id, surface)` among live rows (host migration partial index).
    * `surface`    — a plain string naming WHICH list/view this belongs to (the object-ref
      style anchor, e.g. `"crm.person"`), so a user's saved views for the Contacts list
      are distinct from those for the Deals board. Never a FK.
    * `view_type`  — a BOUNDED atom enum (the WS-G view family: table/board/kanban/
      calendar/timeline/gallery/tree/chart/dashboard). Inline `one_of` like every other
      enum in this codebase — user input never mints an atom.
    * `params`     — a `:map` (jsonb) blob of the serialized, WHITELISTED, NON-SECRET view
      state (sort, filter box text, group-by field, columns, date field, window, caps,
      page size, …). NEVER a vault field: `Samen.Web.SavedViews` REFUSES to persist a
      predicate/field-reference that names a vault-routed (🔒) attribute, so plaintext PII
      can never land in this column (INV-1). The blob is UNTRUSTED on restore — the
      samen_web layer re-validates every field reference against the surface's bounded
      field lists and re-applies `OrgScope` before it drives a query.
    * `owner_id`   — the OWNING user's id (a plain uuid — same posture as
      `Work.Task.owner_id`). The per-user isolation axis.

  ## Access control (the crux — two-axis isolation, both policy-enforced)

    * ORG axis — `Samen.Policy.OrgScope`: a user can NEVER read/list/update/delete a saved
      view in ANOTHER org (cross-org rows do not exist).
    * USER axis — `Samen.Policy.OwnerOnly`: a saved view is PRIVATE to its owner; another
      user in the SAME org can NEVER read/modify/delete it (another user's rows do not
      exist). No sharing model — a private view stays private.

  Both are `FilterCheck`s in separate `policy` blocks, so they AND together into one row
  filter (`org_id == actor.org_id AND owner_id == actor.id`) on every read AND write.
  `RoleAtLeast :member` additionally gates writes (a saved view is a member affordance).

  ## Abbrevs (permanent, registry-checked)

  Each host takes a fresh allocator-proposed abbrev (`mix samen.abbrev.reserve`, ADR-023 —
  the macro never invents one), passed via `abbrevs:`. The samen_web test host reserved
  `wvs` (`Samen.WebTest.Views.SavedView`).

  ## Storage-name discipline

  Every column is `<abbrev>_<name>` (via `Samen.Resource`'s AbbrevStorage transformer),
  matching every other Samen scope.
  """

  # ---------------------------------------------------------------------------
  # SavedView — a per-user, org-scoped, named view-state snapshot. Archivable is
  # OFF (a saved view is deleted outright when the user removes it — there is no
  # trash affordance for a personal view; matching join/pref-shaped rows).
  # ---------------------------------------------------------------------------
  defmacro define_saved_view(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Views.SavedView — a per-user, org-scoped, NAMED snapshot of a list/view surface's
        UI state (G10, T58). `view_type` is a BOUNDED enum; `params` is a NON-SECRET
        `:map` blob (never a vault field — the samen_web `Samen.Web.SavedViews` layer
        refuses to persist a field reference naming a vault-routed attribute, and
        re-validates the blob against the surface's bounded field lists on restore).

        Two-axis isolation, both policy-enforced: `Samen.Policy.OrgScope` (cross-org rows
        do not exist) AND `Samen.Policy.OwnerOnly` (another user's rows do not exist). No
        PII: `name`/`surface`/`params` are operator-authored, non-secret facets.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_saved_view")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
          # The list/view surface this belongs to (object-ref style anchor, plain string).
          attribute(:surface, :string, public?: true, allow_nil?: false)

          # The chosen view type — BOUNDED enum (the WS-G view family). Inline one_of,
          # matching every other enum in this codebase; user input never mints an atom.
          attribute(:view_type, :atom,
            public?: true,
            default: :table,
            constraints: [
              one_of: [
                :table,
                :board,
                :kanban,
                :calendar,
                :timeline,
                :gantt,
                :gallery,
                :tree,
                :chart,
                :dashboard
              ]
            ]
          )

          # The serialized, whitelisted, NON-SECRET view-state blob. NEVER holds a
          # vault-routed field value (INV-1 — enforced at the Samen.Web.SavedViews write
          # boundary). Untrusted on restore (re-validated there).
          attribute(:params, :map, public?: true, default: %{})

          # The OWNING user's id — the per-user isolation axis (plain uuid, same posture
          # as Work.Task.owner_id).
          attribute(:owner_id, :uuid, public?: true, allow_nil?: false)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          # ORG axis + USER axis, each its own policy block so the two FilterChecks AND
          # together into one row filter on every read.
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type(:read) do
            authorize_if(Samen.Policy.OwnerOnly)
          end

          # Writes: org-scoped AND owner-scoped AND member-gated. A create spoofing a
          # foreign owner_id is refused by OwnerOnly (owner_id must equal actor.id); an
          # update/destroy of a foreign row is refused (the row does not exist for the
          # actor under the AND'd filters).
          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless(Samen.Policy.OwnerOnly)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end
end

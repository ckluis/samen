defmodule Samen.Scopes.Calendar.Blueprint do
  @moduledoc """
  Resource-definition macro for the **Calendar** scope (F2; spec §F2/§F8).

  One resource: **`Event`** — an Event/Meeting (`kind` distinguishes the two,
  mirroring `Samen.Scopes.Work.Task.kind`'s `:meeting` value — a Calendar
  `Event` with `kind: :meeting` IS the "Meeting" the spec names, not a second
  resource) with start/end, a 🔒 vaulted attendee list, a location string, and
  an optional recurrence rule (`Samen.Scopes.Calendar.Recurrence`).

  ## PII map (INV-1)

  | Attribute | Classification | Vault? |
  |---|---|---|
  | `attendees` | PII (composite `Samen.Type.Emails`) | **yes** — `vault :pii_attendees` |
  | `kind`, `title`, `description`, `location`, `timezone` | freeform/bounded, non-PII | no |
  | `starts_at`, `ends_at`, `recurrence`, `custom`, `owner_id`, ids/timestamps | non-PII | no |

  `location`/`description` are freeform authored content (Work `Task.title`/
  `.body` parity) — default-deny-CDC-excluded, not vaulted; a vertical whose
  location genuinely identifies a natural person's home address should route
  through `Samen.Type.Address` + `vault :pii_address` at ITS OWN mount (H4),
  same posture as the H3 URL "personal-profile" caveat — out of this
  substrate scope, which ships a plain string location (spec F2 names
  "location" as a bare field, not the H4 composite).

  ## Recurrence (F2 "recurrence rule")

  `recurrence` is a plain `:map` (`Samen.Scopes.Calendar.Recurrence.rule()`
  shape once cast) — not persisted as a computed occurrence list. Expansion
  (`Recurrence.expand/4,5`) is a PURE, BOUNDED, deterministic function of
  `(starts_at, recurrence, window)` — see that module's moduledoc for the
  DST-safety design (deliberately NOT the digest fixed-offset shape).

  ## Soft-delete (ADR-040 §5.9)

  `archivable: true` — a Calendar `Event` is a user-managed noun (class-(L)/
  (M)/(A) exclusions don't apply). No cascade children (single-resource scope).

  ## Storage-name discipline

  Every column is `<abbrev>_<name>`; the vaulted composite `attendees`
  materializes with NO `pii_` prefix (composite convention, ADR-036 D4/H4 —
  same as `full_name`/`emails` elsewhere), so its physical column is
  `<abbrev>_attendees`.
  """

  defmacro define_event(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Calendar.Event — an Event or Meeting (`kind` distinguishes; F2). Start/end,
        a 🔒 vaulted attendee list (`Samen.Type.Emails`, `vault: :pii_attendees`),
        a plain-string location, and an optional recurrence rule expanded via
        `Samen.Scopes.Calendar.Recurrence.expand/4,5` (never persisted as an
        occurrence list — a single row IS the series). Org-scoped. Archivable
        (ADR-040 §5.9).

        `timezone` is DISPLAY metadata only (IANA zone name, default `"Etc/UTC"`)
        — recurrence expansion arithmetic never reads it (see the Recurrence
        moduledoc's DST-safety design: no fixed-offset "local hour" step exists
        to get wrong).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_event")
          repo(unquote(repo))
        end

        attributes do
          attribute(:kind, :atom,
            public?: true,
            default: :event,
            constraints: [one_of: [:event, :meeting]]
          )
          attribute(:title, :string, public?: true)
          attribute(:description, :string, public?: true)
          attribute(:starts_at, :utc_datetime_usec, public?: true, allow_nil?: false)
          attribute(:ends_at, :utc_datetime_usec, public?: true)
          attribute(:location, :string, public?: true)
          # Display-only IANA zone name — never read by Recurrence.expand/4,5.
          attribute(:timezone, :string, public?: true, default: "Etc/UTC")
          # Samen.Scopes.Calendar.Recurrence.rule() shape once cast, or nil
          # (not recurring). Non-PII (bounded freq/interval/count/until scalars).
          attribute(:recurrence, :map, public?: true)
          attribute(:custom, :map, public?: true)
          # Plain uuid — mirrors Samen.Scopes.Work.Task.owner_id (no cross-scope
          # coupling to a specific Identity module shape at mount time).
          attribute(:owner_id, :uuid, public?: true)
        end

        pii do
          vault(:pii_attendees)
          # Composite PII: attendees routes by vault name (no pii_ prefix on column).
          pii_attribute(:attendees, Samen.Type.Emails, vault: :pii_attendees)
        end

        validations do
          # Fail-honest at write time (see Samen.Scopes.Calendar.Recurrence
          # moduledoc) — a malformed rule is refused here, never silently
          # persisted to surface as a raised error at the first ICS export.
          validate(Samen.Scopes.Calendar.RecurrenceGuard, on: [:create, :update])
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
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end
end

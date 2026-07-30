defmodule Samen.Scopes.Calendar do
  @moduledoc """
  The **Calendar** universal scope (F2; spec §F2/§F8 — Event/Meeting +
  recurrence + ICS export). Ships as a **library-authored blueprint**
  (ADR-004), the same shape as `Samen.Scopes.Work` (T43, the closest
  structural template): `use`-ing this module inside a host's Ash domain
  expands into ONE host-owned resource in the host's namespace, a normal
  `use Samen.Resource` with the host's `otp_app`, `repo`, and `domain`.

  ## Resource — `event` (Event/Meeting; `kind` distinguishes)

  - **`Event`** — start/end (`starts_at`/`ends_at`), a 🔒 vaulted `attendees`
    list (`Samen.Type.Emails`, `vault: :pii_attendees`), `location` (plain
    string), an optional `recurrence` rule (expanded via
    `Samen.Scopes.Calendar.Recurrence.expand/4,5`), `kind` (`:event` |
    `:meeting`). Archivable (ADR-040 §5.9).

  See `Samen.Scopes.Calendar.Blueprint` for the full field/PII table.

  ## ICS export

  The web-facing masked `.ics` byte-delivery surface (`samen_web`'s
  `Samen.Web.Ics`) reads THIS resource — see that module's moduledoc.
  `samen_core` has no web/HTTP layer; this scope only defines the substrate
  resource + the pure `Recurrence` expansion the export walks.

  ## Mounting the Calendar scope (the host side)

      defmodule Demo.CalendarScope do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Calendar,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.CalendarScope
      end

  This defines, in the host's namespace: `Demo.CalendarScope.Event`.

  ## Abbrevs (permanent, registry-checked)

  Reserved in `samen_core/priv/abbrev_registry.json` under the HOST module
  name via `mix samen.abbrev.reserve` (ADR-023 — the macro does NOT invent
  abbrevs). Every host mount passes its own allocator-proposed `abbrevs:`
  override (mirroring `Samen.Scopes.Work`'s plumbing) — there is no scope-
  default abbrev pre-claimed by any one host (unlike Work's demo-default
  `wpj`/`wtk`), so `abbrevs:` is REQUIRED at every call site.
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module
    abbrev = fetch_abbrev!(opts, __CALLER__)

    event_mod = Module.concat(namespace, Event)

    quote do
      require Samen.Scopes.Calendar.Blueprint

      resources do
        resource(unquote(event_mod))
      end

      Samen.Scopes.Calendar.Blueprint.define_event(
        unquote(event_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrev)
      )
    end
  end

  defp fetch_abbrev!(opts, caller) do
    case Keyword.get(opts, :abbrevs) do
      {:%{}, _, pairs} ->
        pairs
        |> Map.new(fn {k, v} -> {Macro.expand(k, caller), Macro.expand(v, caller)} end)
        |> Map.fetch(:event)
        |> case do
          {:ok, abbrev} ->
            abbrev

          :error ->
            raise ArgumentError,
                  "use Samen.Scopes.Calendar, abbrevs: must include :event " <>
                    "(e.g. abbrevs: %{event: \"cev\"})"
        end

      nil ->
        raise ArgumentError,
              "use Samen.Scopes.Calendar requires abbrevs: %{event: \"<3-letter>\"} " <>
                "(allocator-proposed via `mix samen.abbrev.reserve --propose`) — " <>
                "there is no pre-claimed scope-default abbrev for Calendar"

      other ->
        raise ArgumentError,
              "use Samen.Scopes.Calendar, abbrevs: must be a compile-time map literal " <>
                "(%{event: \"cev\"}). Got: #{Macro.to_string(other)}"
    end
  end
end

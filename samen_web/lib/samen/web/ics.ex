defmodule Samen.Web.Ics do
  @moduledoc """
  Framework `.ics` (RFC-5545 `text/calendar`) export for a Calendar `Event`
  resource (F2; spec §F2/§F8 c8: "generated pure-Elixir (no dep); text/calendar
  endpoint, org-scoped, PII-masked per plane") — mirrors `Samen.Web.Csv` in
  shape (bounded read, per-plane masking, hand-rolled format, zero new dep).

  ## Export is a first-class MASKING surface (INV-1, NON-NEGOTIABLE)

  Every page of records is resolved through `Samen.Api.PiiResolution` on the
  acting scope's plane BEFORE any line is serialized — same seam CSV export
  uses (ADR-028), same guarantee: the `.ics` feed and the pixel show the SAME
  value on the same plane:

    * tenant own-org           → `ATTENDEE` lines carry the real address;
    * operator (impersonation) → attendees collapse to a SINGLE masked
      `X-SAMEN-ATTENDEES:••••` line — NEVER a plaintext address, NEVER a
      `vt_*` vault token, and no per-address `ATTENDEE:` line at all (a
      masked-but-present placeholder property, not a fake mailto);
    * operator API-key posture → `%Ash.ForbiddenField{}` → NO attendee
      property is emitted at all (mask-by-omission, matching `Samen.Web.Csv`'s
      empty-cell convention).

  This module never calls `Samen.Vault.reveal/3` and has no raw-row read
  path — export cannot leak what the UI wouldn't show.

  ## Export is BOUNDED

  Rows are read exclusively via `Samen.Web.Reads.page!/3` keyset iteration —
  the same bounded-read seam CSV export uses. There is no `Ash.read!` of the
  full set anywhere in this module.

  ## Recurrence — RRULE, not pre-expanded instances

  A recurring `Event` emits ONE `VEVENT` carrying an `RRULE` property (the
  standard iCalendar shape every real calendar client expects — Google/
  Outlook/Apple Calendar all expand `RRULE` client-side) rather than one
  `VEVENT` per occurrence. `Samen.Scopes.Calendar.Recurrence.cast_rule/1` is
  the single source of truth for what a legal rule is; `rrule_line/1` maps
  the SAME `{freq, interval, count, until}` shape to `FREQ=..;INTERVAL=..`
  etc. — no separate recurrence-format decision made here.

  ## Format (hand-rolled RFC 5545, no new dependency — c8)

  `BEGIN:VCALENDAR` / `VERSION:2.0` / `PRODID` / one `BEGIN:VEVENT`...
  `END:VEVENT` per row (`UID`/`DTSTAMP`/`DTSTART`/`DTEND`/`SUMMARY`/
  `LOCATION`/`DESCRIPTION`/`RRULE`/`ATTENDEE`*) / `END:VCALENDAR`, CRLF line
  endings, `,;\\` and newlines escaped in text values per §3.3.11.
  """

  alias Samen.Web.ListState
  alias Samen.Web.Reads
  alias Samen.Scopes.Calendar.Recurrence

  @mask "••••"
  @prodid "-//Samen//Calendar 1.0//EN"

  @doc """
  Export `resource` (a Calendar `Event`-shaped resource: `starts_at`/
  `ends_at`/`title`/`description`/`location`/`recurrence`/`attendees`) rows
  for `scope` as a `text/calendar` binary — `{:ok, ics}`.

  Options:

    * `:repo`      — REQUIRED. The vault repo for `PiiResolution`.
    * `:page_size` — keyset page size (clamped by `Reads`; default
      `#{Reads.default_page_size()}`).
    * `:query`     — optional pre-scoped `Ash.Query` base (defaults to `resource`).
  """
  def export(resource, scope, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, Reads.default_page_size())
    base = Keyword.get(opts, :query, resource)
    cols = [:id, :kind, :title, :description, :starts_at, :ends_at, :location, :recurrence, :attendees]

    events = export_rows(base, resource, scope, cols, page_size, opts, nil, [])

    ics =
      "BEGIN:VCALENDAR\r\n" <>
        "VERSION:2.0\r\n" <>
        "PRODID:#{@prodid}\r\n" <>
        "CALSCALE:GREGORIAN\r\n" <>
        Enum.map_join(events, "", &vevent/1) <>
        "END:VCALENDAR\r\n"

    {:ok, ics}
  end

  # -- internals ---------------------------------------------------------------

  defp export_rows(base, resource, scope, cols, page_size, opts, cursor, acc) do
    state = %ListState{page_size: page_size, sort: {:id, :asc}, cursor: cursor}

    page =
      base
      |> Ash.Query.ensure_selected(cols)
      |> Reads.page!(state, scope: scope)

    resolved =
      Samen.Api.PiiResolution.resolve(
        page.items,
        resource,
        actor_of(scope),
        repo: Keyword.fetch!(opts, :repo)
      )

    acc = acc ++ resolved

    if page.has_more do
      export_rows(base, resource, scope, cols, page_size, opts, page.next_cursor, acc)
    else
      acc
    end
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  defp vevent(event) do
    "BEGIN:VEVENT\r\n" <>
      "UID:#{event.id}@samen\r\n" <>
      "DTSTAMP:#{basic_utc(DateTime.utc_now())}\r\n" <>
      "DTSTART:#{basic_utc(event.starts_at)}\r\n" <>
      maybe_line("DTEND", event.ends_at && basic_utc(event.ends_at)) <>
      maybe_line("SUMMARY", present(event.title)) <>
      maybe_line("DESCRIPTION", present(event.description)) <>
      maybe_line("LOCATION", present(event.location)) <>
      rrule_line(event.recurrence) <>
      attendee_lines(event.attendees) <>
      "END:VEVENT\r\n"
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value

  defp maybe_line(_prop, nil), do: ""
  defp maybe_line(prop, value), do: "#{prop}:#{escape(value)}\r\n"

  defp basic_utc(%DateTime{} = dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  # RFC 5545 §3.3.11 text escaping: backslash, comma, semicolon, then newlines.
  defp escape(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace(";", "\\;")
    |> String.replace("\r\n", "\\n")
    |> String.replace("\n", "\\n")
  end

  # -- recurrence -> RRULE ------------------------------------------------------

  defp rrule_line(nil), do: ""

  defp rrule_line(recurrence) do
    case Recurrence.cast_rule(recurrence) do
      {:ok, nil} -> ""
      {:ok, rule} -> "RRULE:#{rrule_value(rule)}\r\n"
      # A malformed persisted rule is a data bug, not a reason to fail the
      # WHOLE export — the event is still exported, just without an RRULE
      # (fail-soft here mirrors Samen.Web.Csv's unterminated-quote parse).
      {:error, _reason} -> ""
    end
  end

  defp rrule_value(%{freq: freq, interval: interval} = rule) do
    parts = ["FREQ=#{String.upcase(to_string(freq))}", "INTERVAL=#{interval}"]
    parts = if c = Map.get(rule, :count), do: parts ++ ["COUNT=#{c}"], else: parts
    parts = if u = Map.get(rule, :until), do: parts ++ ["UNTIL=#{basic_utc(u)}"], else: parts
    Enum.join(parts, ";")
  end

  # -- attendees (INV-1 masking) ------------------------------------------------

  # Present-but-masked (operator impersonation posture): a SINGLE placeholder
  # property, never a per-address ATTENDEE line, never the vt_* token.
  defp attendee_lines(%Samen.Masked{}), do: "X-SAMEN-ATTENDEES:#{@mask}\r\n"

  # Absent (operator API-key posture, AshJsonApi's omission convention):
  # mask-by-omission — no attendee property at all.
  defp attendee_lines(%Ash.ForbiddenField{}), do: ""

  defp attendee_lines(nil), do: ""

  # Clear (tenant own-org / operator-with-grant): PiiResolution's revealed
  # plaintext for a composite field is the JSON-encoded entries list (the
  # Samen.Vault.Change plaintext form for composite PII, ADR-036 §10 "left
  # exactly as before — the original value is stored byte-for-byte").
  defp attendee_lines(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, entries} when is_list(entries) ->
        Enum.map_join(entries, "", &attendee_line/1)

      _ ->
        ""
    end
  end

  defp attendee_lines(_other), do: ""

  defp attendee_line(%{"address" => address} = entry) do
    case Map.get(entry, "label") do
      nil -> "ATTENDEE:mailto:#{escape(address)}\r\n"
      label -> "ATTENDEE;CN=#{escape(label)}:mailto:#{escape(address)}\r\n"
    end
  end

  defp attendee_line(_other), do: ""
end

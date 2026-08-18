defmodule Samen.Web.IcsMaskingTest do
  @moduledoc """
  F2 / spec c8 — THE ICS EXPORT MASK-BY-DEFAULT RED-PATH (INV-1,
  NON-NEGOTIABLE): an `.ics` feed leaves the app (a calendar client
  subscribes to it), so an attendee line that leaks what the UI masks is an
  exfiltration channel — the same class of risk `Samen.Web.CsvMaskingTest`
  proves for CSV export (ADR-028), same `Samen.MaskingCase` green/red/
  sabotage discipline.

    * **GREEN** — tenant own-org export carries the attendee address in the CLEAR.
    * **RED** — operator (impersonation) export carries a masked placeholder
      line (`X-SAMEN-ATTENDEES:••••`): never the plaintext, never a `vt_*`
      vault token, and no per-address `ATTENDEE:` line at all.
    * **SABOTAGE twins** — (1) plane flip: the SAME event exported on the
      tenant plane goes clear (the resolver is the gate, not a blanket mask);
      (2) leak-scan refutability: a modeled raw-row export IS caught by the
      same `vt_` scan.

  Also proves done-criterion 3: the export IS a parseable `VCALENDAR` (a
  hand-rolled structural parser assertion — BEGIN/END pairing, one VEVENT per
  row, required properties present — no new dependency, matching how
  `Samen.Web.Csv` parses its own RFC-4180 output rather than adopting a lib).
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Web.Ics
  alias Samen.Web.Plane

  alias Samen.WebTest.Calendar.Event

  @secret_addr "ics.vaulted.attendee@sample.invalid"

  defp tenant_scope(org_id), do: Plane.scope(Plane.tenant(), org_id)

  defp operator_scope(org_id),
    do: Plane.scope(Plane.operator("op-1", org_id, "ics-mask-session"), org_id)

  defp seed_event!(org_id, attrs \\ %{}) do
    Event
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org_id,
          title: "Board Sync",
          starts_at: ~U[2026-04-01 15:00:00.000000Z],
          ends_at: ~U[2026-04-01 16:00:00.000000Z],
          location: "HQ — 4th floor",
          attendees: [%{label: "chair", address: @secret_addr}]
        },
        attrs
      ),
      scope: tenant_scope(org_id)
    )
    |> Ash.create!()
  end

  defp export!(scope) do
    {:ok, ics} = Ics.export(Event, scope, repo: Samen.WebTest.Repo)
    ics
  end

  # -- structural VCALENDAR parser assertion (done-criterion 3) ---------------

  defp assert_parseable_vcalendar!(ics) do
    assert String.starts_with?(ics, "BEGIN:VCALENDAR\r\n")
    assert String.ends_with?(ics, "END:VCALENDAR\r\n")
    assert ics =~ "VERSION:2.0\r\n"
    assert ics =~ ~r/^PRODID:.+\r\n/m

    begins = ics |> String.split("BEGIN:VEVENT") |> length() |> Kernel.-(1)
    ends = ics |> String.split("END:VEVENT") |> length() |> Kernel.-(1)
    assert begins == ends and begins > 0, "unbalanced or missing VEVENT blocks"

    Enum.each(["UID:", "DTSTAMP:", "DTSTART:"], fn required ->
      assert ics =~ required, "missing required property #{required}"
    end)

    ics
  end

  describe "ICS export masking per plane (INV-1)" do
    test "GREEN: tenant own-org export carries the attendee address in the CLEAR" do
      org_id = Ash.UUID.generate()
      seed_event!(org_id)

      ics = export!(tenant_scope(org_id)) |> assert_parseable_vcalendar!()

      assert ics =~ @secret_addr
      assert ics =~ "ATTENDEE"
      refute ics =~ "vt_"
      # Non-PII fields ride along unmasked on every plane.
      assert ics =~ "SUMMARY:Board Sync"
      assert ics =~ "LOCATION:HQ"
    end

    test "RED: operator export carries a masked placeholder — NEVER plaintext, NEVER a vt_ token" do
      org_id = Ash.UUID.generate()
      seed_event!(org_id)

      ics = export!(operator_scope(org_id)) |> assert_parseable_vcalendar!()

      assert_masked_dom!(ics, [@secret_addr])
      assert ics =~ "X-SAMEN-ATTENDEES:#{mask()}"
      refute ics =~ "ATTENDEE;"
      refute ics =~ "ATTENDEE:mailto:"
      # Non-PII fields are untouched: masking is per-field, not per-feed.
      assert ics =~ "SUMMARY:Board Sync"
    end

    test "the ICS attendee line EQUALS the UI value on the operator plane (the same-pixel rule)" do
      org_id = Ash.UUID.generate()
      event = seed_event!(org_id)

      at_rest =
        Event
        |> Ash.Query.filter(id == ^event.id)
        |> Ash.Query.ensure_selected([:attendees])
        |> Ash.read_one!(authorize?: false)

      ui_value =
        at_rest
        |> resolve_on_plane(Event, :operator, repo: Samen.WebTest.Repo)
        |> Map.get(:attendees)

      assert_plane_masked!(ui_value)

      ics = export!(operator_scope(org_id))
      assert ics =~ "X-SAMEN-ATTENDEES:#{to_string(ui_value)}"
    end

    test "ANTI-TAUTOLOGY: the SAME event exported on the tenant plane goes CLEAR (plane flip)" do
      org_id = Ash.UUID.generate()
      seed_event!(org_id)

      operator_ics = export!(operator_scope(org_id))
      assert_masked_dom!(operator_ics, [@secret_addr])

      tenant_ics = export!(tenant_scope(org_id))
      assert tenant_ics =~ @secret_addr
      refute tenant_ics =~ mask()
    end

    test "ANTI-TAUTOLOGY: a modeled raw-row export IS caught by the vt_ leak scan" do
      org_id = Ash.UUID.generate()
      event = seed_event!(org_id)

      at_rest =
        Event
        |> Ash.Query.filter(id == ^event.id)
        |> Ash.Query.ensure_selected([:attendees])
        |> Ash.read_one!(authorize?: false)

      assert %Samen.Masked{token: "vt_" <> _ = token} = at_rest.attendees

      leaked_ics = "BEGIN:VEVENT\r\nX-SAMEN-ATTENDEES:#{token}\r\nEND:VEVENT\r\n"
      assert_leak_detected!(leaked_ics, "vt_")
    end

    test "operator API-key posture (forbidden, no grant) omits the attendee property entirely" do
      org_id = Ash.UUID.generate()
      seed_event!(org_id)

      # An operator scope with NO :impersonation marker (the API-key posture,
      # distinct from operator_scope/1's impersonation session above) resolves
      # attendees to %Ash.ForbiddenField{} per Samen.Api.PiiResolution
      # (mask-by-omission) — exercised through the REAL Ics.export/3 path.
      api_key_scope = %Samen.Scope{actor: %{plane: :operator, org_id: org_id, id: "apikey"}}

      ics = export!(api_key_scope) |> assert_parseable_vcalendar!()

      refute ics =~ @secret_addr
      refute ics =~ "vt_"
      refute ics =~ "X-SAMEN-ATTENDEES"
      refute ics =~ "ATTENDEE"
    end
  end
end

defmodule Samen.Web.ReplayPlaceholderCellsTest do
  @moduledoc """
  ADR-052 §2.3 — the replay player's fidelity on vault-routed CELLS. The player rebuilds a
  recorded view's assigns and puts a `%Samen.Replay.Placeholder{}` where a referenced value
  cannot be shown on the viewer's plane (`:masked` → `••••`, `:shredded` → `[erased]`, `:gone`,
  `:code_changed`, …), then calls the view's CURRENT `render/1`. A renderer that matched only
  `%Samen.Masked{}` sent a placeholder to its "no value" clause, so a masked or erased email
  printed "—" — the same glyph as a contact with NO email (claim-evidence RP12).

  The framework now has ONE answer: `Samen.Web.ObjectRef.FieldValue.opaque/1` (a `%Masked{}` or
  a `%Placeholder{}` is present-but-not-shown and passes through AS-IS). Every cell renderer
  either delegates to `FieldValue` or matches that guard. This file proves it per renderer, on
  the player's real rendering path (`Samen.Web.Replay.Renderer.render/2`, the same call
  `PlayerLive` makes): each view is loaded for real on the tenant plane, the seeded record's
  vault fields are replaced with the placeholder the resolver would produce, and the cell must
  show `••••` / `[erased]` — never "—". Positive control: a record with a genuinely EMPTY email
  or phone still renders "—", so the assertions are not vacuous ("—" is still reachable).

  The live (non-replay) rendering is unchanged: the five CRM views' private copies were
  byte-identical to `FieldValue`'s and now delegate to it, and the plane masking suites
  (`contacts_gallery_masking_test.exs`, `crm_detail_render_test.exs`,
  `ai_crm_masking_test.exs`, …) stay green. The end-to-end proof over a REAL recording of
  `ContactsLive` is in `replay_player_test.exs` (R8, "email and phone cells").
  Sabotage 495 reverts the shared guard to `%Masked{}` only.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Factory
  alias Samen.Replay.Placeholder
  alias Samen.Web.AI.CrmLive
  alias Samen.Web.CRM.{CompanyLive, ContactLive, ContactsGalleryLive, ContactsLive}
  alias Samen.Web.Marketing.LeadsLive
  alias Samen.Web.ObjectRef.FieldValue
  alias Samen.Web.Operator.Live, as: OperatorLive
  alias Samen.Web.Replay.Renderer
  alias Samen.Web.Support.TicketLive
  alias Samen.WebTest.Crm.Person

  @dash "—"
  @mask "••••"
  @erased "[erased]"

  defp masked, do: Placeholder.new(:masked)
  defp shredded, do: Placeholder.new(:shredded)

  # -- harness ----------------------------------------------------------------------------

  defp socket(mount, extra \\ %{}) do
    Enum.reduce(
      Map.merge(%{samen_mount: mount, samen_acting_as: false, return_to: nil}, extra),
      %Phoenix.LiveView.Socket{},
      fn {k, v}, s -> Phoenix.Component.assign(s, k, v) end
    )
  end

  # The player's frame for `assigns`: every record whose id is in `ids` rebuilt with `fields`
  # (what `Samen.Replay.Resolver` does with a viewer outcome), rendered by the REAL
  # `Renderer.render/2` (the recorded view's current `render/1`, made inert).
  defp play(view, assigns, ids, fields) do
    assert {:ok, html} = Renderer.render(view, swap(assigns, MapSet.new(ids), fields))
    html
  end

  defp swap(list, ids, f) when is_list(list), do: Enum.map(list, &swap(&1, ids, f))

  defp swap(tuple, ids, f) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> swap(ids, f) |> List.to_tuple()

  defp swap(%Placeholder{} = p, _ids, _f), do: p

  defp swap(map, ids, f) when is_map(map) do
    map = if MapSet.member?(ids, Map.get(map, :id)), do: Map.merge(map, f), else: map

    map
    |> Map.keys()
    |> Enum.reject(&(&1 == :__struct__))
    |> Enum.reduce(map, fn k, acc -> Map.put(acc, k, swap(Map.get(acc, k), ids, f)) end)
  end

  defp swap(other, _ids, _f), do: other

  # The text of the first element matching `re` (group 1), trimmed.
  defp cell(html, re) do
    assert [_, inner] = Regex.run(re, html), "no cell #{inspect(re)} in the frame"
    String.trim(inner)
  end

  defp assert_shows(html, re, expected) do
    got = cell(html, re)
    assert got == expected, "cell #{inspect(re)}: expected #{inspect(expected)}, got #{inspect(got)}"
    refute got == @dash
  end

  defp person_without_contact!(org_id, extra \\ %{}) do
    Factory.create!(
      Person,
      Map.merge(Factory.person("Nomail", "Nophone"), Map.merge(%{display_name: "No Contact", org_id: org_id}, extra)),
      Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), org_id)
    )
  end

  # -- the shared helper -------------------------------------------------------------------

  describe "FieldValue — the one masking-aware formatter" do
    test "opaque/1 is true for %Masked{} and every %Placeholder{}, false for a value" do
      import FieldValue, only: [opaque: 1]
      check = fn v -> if opaque(v), do: true, else: false end

      assert check.(%Samen.Masked{token: "vt_x", label: :emails})
      for kind <- Placeholder.kinds(), do: assert(check.(Placeholder.new(kind)), "#{kind}")
      refute check.("a@b.example")
      refute check.(nil)
      refute check.([])
    end

    test "email/phone/full_name/generic pass a placeholder through: its own text, never —" do
      for {kind, text} <- [masked: @mask, shredded: @erased, gone: "[gone]", code_changed: "[changed]"] do
        p = Placeholder.new(kind)

        for out <- [FieldValue.email(p), FieldValue.phone(p), FieldValue.full_name(p, "Display"), FieldValue.generic(p)] do
          assert out == p
          assert Phoenix.HTML.Safe.to_iodata(out) |> IO.iodata_to_binary() == text
        end
      end
    end

    test "positive control: a genuinely empty email/phone/name is still —; a %Masked{} is unchanged" do
      for empty <- [nil, [], "[]"] do
        assert FieldValue.email(empty) == @dash
        assert FieldValue.phone(empty) == @dash
      end

      assert FieldValue.full_name(nil) == @dash
      assert FieldValue.email([%{"address" => "a@b.example"}]) == "a@b.example"
      m = %Samen.Masked{token: "vt_x", label: :emails}
      assert FieldValue.email(m) == m
    end
  end

  # -- the framework views -----------------------------------------------------------------

  describe "CRM views — a placeholder cell shows the placeholder, an empty cell shows —" do
    setup do
      seeded = Seeds.seed_all()
      %{org: seeded.org_id, person: seeded.crm.person, company: seeded.crm.company}
    end

    test "ContactsLive (list): name, initials, email, phone", ctx do
      assigns = ContactsLive.load(socket(build_mount(:crm)), ctx.org).assigns

      for {ph, text, initials} <- [{masked(), @mask, "··"}, {shredded(), @erased, "··"}] do
        html = play(ContactsLive, assigns, [ctx.person.id], %{full_name: ph, emails: ph, phones: ph})
        assert_shows(html, ~r/class="p-email"[^>]*>(.*?)</s, text)
        assert_shows(html, ~r/class="p-phone"[^>]*>(.*?)</s, text)
        assert_shows(html, ~r/class="p-full-name"[^>]*>(.*?)</s, text)
        assert cell(html, ~r/class="p-name".*?class="av"[^>]*>(.*?)</s) == initials
      end

      # Positive control: a contact with NO email/phone renders — (live and in the player).
      org = Ash.UUID.generate()
      person_without_contact!(org)
      empty = ContactsLive.load(socket(build_mount(:crm)), org).assigns
      html = play(ContactsLive, empty, [], %{})
      assert cell(html, ~r/class="p-email"[^>]*>(.*?)</s) == @dash
      assert cell(html, ~r/class="p-phone"[^>]*>(.*?)</s) == @dash
    end

    test "ContactLive (detail): header + overview email, phone, name", ctx do
      assigns = ContactLive.load(socket(build_mount(:crm)), ctx.org, ctx.person.id).assigns

      for {ph, text} <- [{masked(), @mask}, {shredded(), @erased}] do
        html = play(ContactLive, assigns, [ctx.person.id], %{full_name: ph, emails: ph, phones: ph})

        for class <- ~w(c-email c-phone ov-email ov-phone c-full-name ov-name),
            do: assert_shows(html, ~r/class="#{class}"[^>]*>(.*?)</s, text)

        assert cell(html, ~r/id="contact-header".*?class="av"[^>]*>(.*?)</s) == "··"
      end

      org = Ash.UUID.generate()
      p = person_without_contact!(org)
      html = play(ContactLive, ContactLive.load(socket(build_mount(:crm)), org, p.id).assigns, [], %{})
      for class <- ~w(c-email c-phone ov-email ov-phone), do: assert(cell(html, ~r/class="#{class}"[^>]*>(.*?)</s) == @dash)
    end

    test "CompanyLive (detail): the company's contacts table", ctx do
      assigns = CompanyLive.load(socket(build_mount(:crm)), ctx.org, ctx.company.id).assigns
      row = ~r/class="cc-contact-row"[^>]*>\s*<td>\s*<a[^>]*>(.*?)<\/a>\s*<\/td>\s*<td[^>]*>(.*?)<\/td>/s

      for {ph, text} <- [{masked(), @mask}, {shredded(), @erased}] do
        html = play(CompanyLive, assigns, [ctx.person.id], %{full_name: ph, emails: ph})
        assert [_, name, email] = Regex.run(row, html)
        assert String.trim(name) == text
        assert String.trim(email) == text
      end

      org = Ash.UUID.generate()

      company =
        Ash.create!(
          Ash.Changeset.for_create(Samen.WebTest.Crm.Company, :create, %{org_id: org, name: "Empty Co"}),
          authorize?: false
        )

      person_without_contact!(org, %{company_id: company.id})
      html = play(CompanyLive, CompanyLive.load(socket(build_mount(:crm)), org, company.id).assigns, [], %{})
      assert [_, _name, email] = Regex.run(row, html)
      assert String.trim(email) == @dash
    end

    test "ContactsGalleryLive: card name + email", ctx do
      assigns = ContactsGalleryLive.load(socket(build_mount(:crm)), ctx.org).assigns

      for {ph, text} <- [{masked(), @mask}, {shredded(), @erased}] do
        html = play(ContactsGalleryLive, assigns, [ctx.person.id], %{full_name: ph, emails: ph})
        assert_shows(html, ~r/class="gcard-email mono"[^>]*>(.*?)</s, text)
        # Before the fix a placeholder name fell back to the display name.
        assert_shows(html, ~r/class="gcard-sub"[^>]*>(.*?)</s, text)
      end

      org = Ash.UUID.generate()
      person_without_contact!(org)
      html = play(ContactsGalleryLive, ContactsGalleryLive.load(socket(build_mount(:crm)), org).assigns, [], %{})
      assert cell(html, ~r/class="gcard-email mono"[^>]*>(.*?)</s) == @dash
    end

    test "LeadsLive: lead name + email", ctx do
      assigns = LeadsLive.load(socket(build_mount(:marketing)), ctx.org).assigns

      for {ph, text} <- [{masked(), @mask}, {shredded(), @erased}] do
        html = play(LeadsLive, assigns, [ctx.person.id], %{full_name: ph, emails: ph})
        assert_shows(html, ~r/class="lead-email"[^>]*>(.*?)</s, text)
        assert_shows(html, ~r/class="lead-name"[^>]*>(.*?)</s, text)
      end

      # Positive control: the same lead with an EMPTY email renders —.
      html = play(LeadsLive, assigns, [ctx.person.id], %{emails: nil})
      assert cell(html, ~r/class="lead-email"[^>]*>(.*?)</s) == @dash
    end
  end

  describe "support, AI and operator renderers" do
    setup do
      seeded = Seeds.seed_all()
      %{org: seeded.org_id, support: seeded.support, person: seeded.crm.person}
    end

    test "TicketLive: message body, sender, agent name + email", ctx do
      %{ticket: ticket, message: message, agent: agent} = ctx.support
      base = socket(build_mount(:support), %{org_id: ctx.org, ticket_id: ticket.id})
      conv = TicketLive.load(Phoenix.Component.assign(base, :active_tab, "conversation"), ctx.org, ticket.id).assigns
      details = TicketLive.load(Phoenix.Component.assign(base, :active_tab, "details"), ctx.org, ticket.id).assigns

      for {ph, text} <- [{masked(), @mask}, {shredded(), @erased}] do
        html =
          play(TicketLive, conv, [message.id], %{
            body: ph,
            sender_type: :agent,
            __agent__: %{full_name: ph, handle: "agent-handle"}
          })

        assert_shows(html, ~r/class="msg-body"[^>]*>(.*?)</s, text)
        # Before the fix a placeholder sender name fell back to the handle.
        assert_shows(html, ~r/class="msg-sender"[^>]*>(.*?)</s, text)

        html = play(TicketLive, details, [agent.id], %{full_name: ph, email: ph})
        assert_shows(html, ~r/class="ag-name"[^>]*>(.*?)</s, text)
        assert_shows(html, ~r/class="ag-email"[^>]*>(.*?)</s, text)
      end

      html = play(TicketLive, details, [agent.id], %{email: nil})
      assert cell(html, ~r/class="ag-email"[^>]*>(.*?)</s) == @dash
    end

    test "AI CrmLive grounding preview: name + email (a placeholder name was inspect/1 output)", ctx do
      mount =
        Samen.Web.Mount.new(:ai, Samen.WebTest.Crm, Samen.WebTest.Repo,
          plane: Samen.Web.Plane.tenant(),
          labels: %{ai_crm_resource: Person}
        )

      assigns = CrmLive.load(socket(mount), ctx.org, id: ctx.person.id).assigns

      for {ph, text} <- [{masked(), @mask}, {shredded(), @erased}] do
        html = play(CrmLive, %{assigns | preview: {:ok, %{full_name: ph, emails: ph}}}, [], %{})
        assert_shows(html, ~r/id="ai-preview-email"[^>]*>(.*?)</s, text)
        assert_shows(html, ~r/id="ai-preview-full-name"[^>]*>(.*?)</s, text)
        refute html =~ "#Placeholder"
      end

      html = play(CrmLive, %{assigns | preview: {:ok, %{full_name: nil, emails: nil}}}, [], %{})
      assert cell(html, ~r/id="ai-preview-email"[^>]*>(.*?)</s) == @dash
    end

    test "Operator.Live render_name/render_email (desk, accounts)" do
      for {ph, text} <- [{masked(), @mask}, {shredded(), @erased}] do
        for out <- [OperatorLive.render_name(ph), OperatorLive.render_email(ph)] do
          assert Phoenix.HTML.Safe.to_iodata(out) |> IO.iodata_to_binary() == text
        end
      end

      assert OperatorLive.render_email(nil) == @dash
      assert OperatorLive.render_email([]) == @dash
      assert OperatorLive.render_name(nil) == @dash
    end
  end
end

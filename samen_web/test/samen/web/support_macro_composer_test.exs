defmodule Samen.Web.SupportMacroComposerTest do
  @moduledoc """
  T79 (spec §I6 macros composer palette + CSAT loop closed) — done-criterion 1:
  "Macro test: palette lists org macros, insertion renders into the reply body
  (with any vaulted placeholder resolving per plane — masking test)."

  Mirrors `Samen.Web.SupportKbComposerTest`'s harness shape (T78's own
  composer-suggestion test) — the macro palette coexists with the KB
  suggestion panel on the SAME `TicketLive`.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Support.TicketLive
  alias Samen.Web.Support.Reads
  alias Samen.Web.Mount

  defp mount_socket(org_id, ticket_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:support, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> Phoenix.Component.assign(:org_id, org_id)
    |> Phoenix.Component.assign(:ticket_id, ticket_id)
    |> Phoenix.Component.assign(:active_tab, "conversation")
    |> TicketLive.load(org_id, ticket_id)
  end

  defp html(socket), do: render_html(TicketLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = TicketLive.handle_event(name, params, socket)
    socket
  end

  defp seed_macro(org_id, attrs \\ %{}) do
    Samen.WebTest.Support.Macro
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org_id,
          name: "ack-#{System.unique_integer([:positive])}",
          description: "Standard acknowledgement",
          body_template: "Hi {{agent_name}}, thanks for reaching out!",
          enabled: true
        },
        attrs
      ),
      authorize?: false
    )
    |> Ash.create!()
  end

  # ---------------------------------------------------------------------------
  describe "palette lists org macros" do
    test "an enabled macro appears in the palette; a disabled one does not" do
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      macro = seed_macro(org_id)
      _disabled = seed_macro(org_id, %{name: "disabled-one", enabled: false})

      socket = mount_socket(org_id, ticket.id)
      rendered = html(socket)

      assert rendered =~ ~s(id="macro-palette")
      assert rendered =~ macro.name
      assert rendered =~ macro.description
      assert rendered =~ ~s(id="macro-#{macro.id}")
      assert rendered =~ ~s(phx-click="insert_macro")
      refute rendered =~ "disabled-one"
    end

    test "no macros for the org -> the palette renders nothing (honest empty)" do
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      socket = mount_socket(org_id, ticket.id)

      assert socket.assigns.macros == []
      refute html(socket) =~ ~s(id="macro-palette")
    end

    test "a two-org pin: org B never sees org A's macros" do
      %{org_id: org_a} = Seeds.seed_all()
      %{org_id: org_b, support: %{ticket: ticket_b}} = Seeds.seed_all()
      _macro_a = seed_macro(org_a, %{name: "ORG-A-ONLY-MACRO"})

      mount = build_mount(:support)
      scope_b = Mount.scope(mount, org_b)

      names = Reads.macros(mount, scope_b) |> Enum.map(& &1.name)
      refute "ORG-A-ONLY-MACRO" in names

      # Drop-the-filter-must-flip-a-named-test: reading org A directly (its OWN
      # scope) DOES see it — proving the org_b emptiness above is a real
      # filter, not a vacuous "macros/2 always returns []" tautology.
      scope_a = Mount.scope(mount, org_a)
      names_a = Reads.macros(mount, scope_a) |> Enum.map(& &1.name)
      assert "ORG-A-ONLY-MACRO" in names_a

      socket = mount_socket(org_b, ticket_b.id)
      refute html(socket) =~ "ORG-A-ONLY-MACRO"
    end
  end

  # ---------------------------------------------------------------------------
  describe "insertion renders into the reply body" do
    test "clicking Insert appends the macro's expanded body to the draft reply body" do
      %{org_id: org_id, support: %{ticket: ticket, conversation: _conversation}} = Seeds.seed_all()
      macro = seed_macro(org_id, %{body_template: "Thanks for contacting support."})

      socket = mount_socket(org_id, ticket.id)
      socket = event(socket, "validate_reply", %{"form" => %{"body" => "Hi there,", "message_type" => "reply"}})

      socket = event(socket, "insert_macro", %{"macro_id" => to_string(macro.id)})

      new_body = AshPhoenix.Form.value(socket.assigns.reply_form, :body)
      assert new_body =~ "Hi there,"
      assert new_body =~ "Thanks for contacting support."
    end

    test "insert_macro with an unknown macro_id is a safe no-op" do
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      socket = mount_socket(org_id, ticket.id)
      socket = event(socket, "validate_reply", %{"form" => %{"body" => "unchanged", "message_type" => "reply"}})

      socket = event(socket, "insert_macro", %{"macro_id" => Ash.UUID.generate()})

      assert AshPhoenix.Form.value(socket.assigns.reply_form, :body) == "unchanged"
    end
  end

  # ---------------------------------------------------------------------------
  # MASKING TEST (done-criterion 1's "with any vaulted placeholder resolving
  # per plane"). The composer itself only ever renders on the TENANT plane
  # (`Samen.Web.Support.Live.writable?/1` — write affordances, macros
  # included, are tenant-only; an operator viewing a ticket never sees a
  # composer at all, so there is no LIVE operator-reachable insert_macro
  # event). The masking guarantee is proven at the RESOLUTION layer instead —
  # `Reads.expand_macro/2` never itself calls the vault; it substitutes
  # whatever `Reads.agents/2` ALREADY resolved for the actor's plane. This
  # test proves BOTH directions on the SAME agent record (anti-tautology).
  # ---------------------------------------------------------------------------
  describe "masking — the {{agent_name}} placeholder resolves per plane" do
    test "TENANT plane: expand_macro/2 substitutes the agent's CLEAR full name" do
      %{org_id: org_id} = Seeds.seed_all()
      macro = seed_macro(org_id, %{body_template: "Regards, {{agent_name}}"})

      mount = build_mount(:support, plane: :tenant)
      scope = Mount.scope(mount, org_id)
      agents = Reads.agents(mount, scope)

      expanded = Reads.expand_macro(macro, agents)
      assert expanded =~ Seeds.agent_full_name()
      refute expanded =~ "••••"
    end

    test "OPERATOR plane: the SAME macro + the SAME agent record substitutes ••••, never the plaintext name" do
      %{org_id: org_id} = Seeds.seed_all()
      macro = seed_macro(org_id, %{body_template: "Regards, {{agent_name}}"})

      mount = build_mount(:support, plane: :operator, target_org_id: org_id)
      scope = Mount.scope(mount, org_id)
      agents = Reads.agents(mount, scope)

      expanded = Reads.expand_macro(macro, agents)
      assert expanded =~ "••••"
      refute expanded =~ Seeds.agent_full_name()
    end

    test "no agents on the org -> the placeholder falls back to a neutral phrase, never crashes" do
      # A fresh org with no seeded agent (never fed through Seeds.seed_all/0 —
      # that seeds a full Support fixture including an agent).
      fresh_org = Ash.UUID.generate()
      macro = seed_macro(fresh_org, %{body_template: "Regards, {{agent_name}}"})

      mount = build_mount(:support)
      scope = Mount.scope(mount, fresh_org)
      agents = Reads.agents(mount, scope)

      assert agents == []
      assert Reads.expand_macro(macro, agents) == "Regards, our team"
    end

    test "sabotage twin — insert_macro THROUGH the LiveView handler, direct-invoked on the OPERATOR plane, masks too" do
      # The composer button never RENDERS on the operator plane (writable?/1
      # gates it) — but the event NAME is still a real `handle_event/3` clause
      # reachable by direct invocation (a crafted phx-click, or — as here — a
      # defense-in-depth test). This proves the HANDLER ITSELF (not just the
      # underlying `expand_macro/2` function in isolation) never substitutes
      # unresolved/raw agent data: it must use the ALREADY plane-resolved
      # `socket.assigns.agents`, never a fresh unresolved fetch. The refutable
      # half of the mask assertion (a modeled leak IS detected) — CLAUDE.md's
      # masking-watch-list discipline.
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      macro = seed_macro(org_id, %{body_template: "Regards, {{agent_name}}"})

      socket = mount_socket(org_id, ticket.id, plane: :operator, target_org_id: org_id)
      socket = event(socket, "validate_reply", %{"form" => %{"body" => "Hi,", "message_type" => "reply"}})

      socket = event(socket, "insert_macro", %{"macro_id" => to_string(macro.id)})

      new_body = AshPhoenix.Form.value(socket.assigns.reply_form, :body)
      assert new_body =~ "••••"
      refute new_body =~ Seeds.agent_full_name()
    end
  end
end

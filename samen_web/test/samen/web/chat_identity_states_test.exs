defmodule Samen.Web.ChatIdentityStatesTest do
  @moduledoc """
  THE 3-STATE IDENTITY GATE (ADR-012 §5, test-plan §8.3).

  One seeded cross-plane thread, rendered from the OPERATOR viewer under each stored disclosure
  state, asserts the participant identity model:

    * STATE 1 — `:masked`, `identity_shared: false` → operator sees the `handle` + `••••`, NOT
      the real name.
    * STATE 2 — `:initiator_opt_in`, initiator `identity_shared: true` → operator sees the
      INITIATOR's real name, but a second (non-opted-in) tenant participant STAYS `••••`.
    * STATE 3 — `:tenant_wide` → operator sees ALL tenant participants' real names.

  Anti-tautology controls: the TENANT viewer always sees clear (own plane) in every state; the
  operator NEVER sees message BODIES clear in any state (identity disclosure ≠ content
  disclosure, red path 5). The mechanism is a PLANE CHOICE per subject driven by stored consent —
  every path goes through `PiiResolution`, never a bespoke masking branch.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Chat.{Identity, Reads}
  alias Samen.Web.Mount

  # ==========================================================================
  # STATE 1 — MASKED BY DEFAULT (the floor)
  # ==========================================================================

  test "STATE 1 (:masked): operator sees handle + ••••, NOT the tenant participant's name" do
    org_id = Ash.UUID.generate()
    chat = Seeds.seed_chat(org_id, disclosure_mode: :masked)

    resolved = resolve_operator(org_id, chat)
    tenant = by_handle(resolved, Seeds.tenant_participant_handle())

    # The safe handle is present; the identity is •••• (masked floor).
    assert tenant.handle == Seeds.tenant_participant_handle()
    assert match?(%Samen.Masked{}, tenant.full_name)
    refute Identity.disclosed?(chat.thread, chat.tenant_participant, :operator)
  end

  # ==========================================================================
  # STATE 2 — INITIATOR OPT-IN PER CONVERSATION
  # ==========================================================================

  test "STATE 2 (:initiator_opt_in): operator sees the INITIATOR's name; a non-opted-in participant stays ••••" do
    org_id = Ash.UUID.generate()
    chat = Seeds.seed_chat(org_id, disclosure_mode: :initiator_opt_in, initiator_shared: true)

    resolved = resolve_operator(org_id, chat)
    initiator = by_handle(resolved, Seeds.tenant_participant_handle())
    second = by_handle(resolved, Seeds.second_tenant_handle())

    # The opted-in initiator's real name is DISCLOSED (resolved on the tenant plane).
    assert clear_name(initiator.full_name) == Seeds.tenant_participant_full_name()
    # The OTHER tenant participant did not opt in → stays •••• on the operator plane.
    assert match?(%Samen.Masked{}, second.full_name)
  end

  # ==========================================================================
  # STATE 3 — TENANT-WIDE DISCLOSURE
  # ==========================================================================

  test "STATE 3 (:tenant_wide): operator sees ALL tenant participants' real names" do
    org_id = Ash.UUID.generate()
    chat = Seeds.seed_chat(org_id, disclosure_mode: :tenant_wide)

    resolved = resolve_operator(org_id, chat)
    first = by_handle(resolved, Seeds.tenant_participant_handle())
    second = by_handle(resolved, Seeds.second_tenant_handle())

    assert clear_name(first.full_name) == Seeds.tenant_participant_full_name()
    assert clear_name(second.full_name) == Seeds.second_tenant_full_name()
  end

  # ==========================================================================
  # STATE 3 stamping — the org setting snapshots into the thread at create
  # ==========================================================================

  test "the org ChatDisclosureSetting snapshots into disclosure_mode at thread create (§5.3)" do
    org_id = Ash.UUID.generate()
    Seeds.seed_disclosure_setting(org_id, true)

    mount = chat_mount(plane: :tenant)
    scope = Mount.scope(mount, org_id)

    {:ok, thread} =
      Samen.Web.Chat.create_thread(mount, scope, %{
        org_id: org_id,
        subject: "New cross-plane thread",
        kind: :cross_plane
      })

    # The setting was ON → the thread is stamped :tenant_wide at create (snapshot).
    assert thread.disclosure_mode == :tenant_wide

    # Flipping the org setting OFF later does NOT retroactively change the stamped thread.
    off_org = Ash.UUID.generate()
    Seeds.seed_disclosure_setting(off_org, false)
    off_scope = Mount.scope(chat_mount(plane: :tenant), off_org)

    {:ok, off_thread} =
      Samen.Web.Chat.create_thread(chat_mount(plane: :tenant), off_scope, %{
        org_id: off_org,
        subject: "Masked-floor thread",
        kind: :cross_plane
      })

    assert off_thread.disclosure_mode == :masked
  end

  # ==========================================================================
  # ANTI-TAUTOLOGY CONTROLS
  # ==========================================================================

  test "CONTROL: the TENANT viewer always sees clear identity in EVERY state (own plane)" do
    for mode <- [:masked, :initiator_opt_in, :tenant_wide] do
      org_id = Ash.UUID.generate()
      chat = Seeds.seed_chat(org_id, disclosure_mode: mode)

      mount = chat_mount(plane: :tenant)
      scope = Mount.scope(mount, org_id)
      {:ok, thread} = Reads.get_thread(mount, scope, chat.thread.id)
      participants = Reads.participants(mount, scope, chat.thread.id)
      resolved = Identity.resolve_participants(mount, scope, thread, participants)

      first = by_handle(resolved, Seeds.tenant_participant_handle())
      assert clear_name(first.full_name) == Seeds.tenant_participant_full_name(),
             "tenant viewer must see clear identity under #{mode}"
    end
  end

  test "CONTROL: the operator NEVER sees message BODIES clear, even under :tenant_wide (identity ≠ content)" do
    seeded = Seeds.seed_all()
    # Reuse the seeded org so the ref person exists; tenant-wide discloses IDENTITY not CONTENT.
    chat = Seeds.seed_chat(seeded.org_id, disclosure_mode: :tenant_wide, person_id: seeded.crm.person.id)

    mount = chat_mount(plane: :operator, target_org_id: seeded.org_id)
    scope = Mount.scope(mount, seeded.org_id)

    # Identity is disclosed (tenant_wide) …
    {:ok, thread} = Reads.get_thread(mount, scope, chat.thread.id)
    participants = Reads.participants(mount, scope, chat.thread.id)
    resolved = Identity.resolve_participants(mount, scope, thread, participants)
    first = by_handle(resolved, Seeds.tenant_participant_handle())
    assert clear_name(first.full_name) == Seeds.tenant_participant_full_name()

    # … but the MESSAGE BODY stays masked on the operator plane (content is separate).
    messages = Reads.messages(mount, scope, chat.thread.id)
    assert messages != []
    assert Enum.all?(messages, fn m -> match?(%Samen.Masked{}, m.body) end)
  end

  # -- helpers -----------------------------------------------------------------

  defp resolve_operator(org_id, chat) do
    mount = chat_mount(plane: :operator, target_org_id: org_id)
    scope = Mount.scope(mount, org_id)
    {:ok, thread} = Reads.get_thread(mount, scope, chat.thread.id)
    participants = Reads.participants(mount, scope, chat.thread.id)
    Identity.resolve_participants(mount, scope, thread, participants)
  end

  defp by_handle(participants, handle), do: Enum.find(participants, fn p -> p.handle == handle end)

  defp clear_name(%Samen.Type.FullName{first: first, last: last}), do: String.trim("#{first} #{last}")

  defp clear_name(name) when is_binary(name) do
    case Jason.decode(name) do
      {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
      _ -> name
    end
  end

  defp clear_name(other), do: other

  defp chat_mount(opts) do
    plane =
      case Keyword.get(opts, :plane, :tenant) do
        :operator ->
          Samen.Web.Plane.operator("op-1", Keyword.fetch!(opts, :target_org_id), "test-session")

        _ ->
          Samen.Web.Plane.tenant()
      end

    Mount.new(:chat, Samen.WebTest.Chat, Samen.WebTest.Repo, plane: plane)
  end
end

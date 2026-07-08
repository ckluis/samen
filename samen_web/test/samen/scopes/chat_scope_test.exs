defmodule Samen.Scopes.ChatScopeTest do
  @moduledoc """
  The Chat scope blueprint gate (ADR-012 §2.2) — asserts the four resources materialize with the
  SAME kernel machinery every other scope inherits: vault routing on the 🔒 fields
  (participant `full_name`, message `body`), `OrgScope` on reads, and catalog registration. This
  proves the chat scope is a THIN blueprint over the untouched kernel, not a fork — a vertical
  that mounts it inherits chat + unfurl + the identity model by construction.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.WebTest.Chat.{ChatDisclosureSetting, ChatMessage, ChatParticipant, ChatThread}

  test "the four resources are catalogued Ash resources in the host namespace" do
    for mod <- [ChatThread, ChatParticipant, ChatMessage, ChatDisclosureSetting] do
      assert Ash.Resource.Info.resource?(mod)
    end
  end

  test "message body + participant full_name are vault-routed PII (masked on the operator plane)" do
    org_id = Ash.UUID.generate()
    chat = Seeds.seed_chat(org_id)

    op_actor = %{
      id: "o",
      org_id: org_id,
      role: :member,
      kind: :operator,
      plane: :operator,
      impersonation: %{session_id: "s"}
    }

    [msg] = Samen.Api.PiiResolution.resolve([reselect(chat.message, [:body])], ChatMessage, op_actor, repo: Samen.WebTest.Repo)
    [part] = Samen.Api.PiiResolution.resolve([reselect(chat.tenant_participant, [:full_name])], ChatParticipant, op_actor, repo: Samen.WebTest.Repo)

    assert match?(%Samen.Masked{}, msg.body)
    assert match?(%Samen.Masked{}, part.full_name)
  end

  test "message body + participant full_name are CLEAR on the tenant plane (own org)" do
    org_id = Ash.UUID.generate()
    chat = Seeds.seed_chat(org_id)

    tenant_actor = %{id: "t", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}

    [msg] = Samen.Api.PiiResolution.resolve([reselect(chat.message, [:body])], ChatMessage, tenant_actor, repo: Samen.WebTest.Repo)
    [part] = Samen.Api.PiiResolution.resolve([reselect(chat.tenant_participant, [:full_name])], ChatParticipant, tenant_actor, repo: Samen.WebTest.Repo)

    assert is_binary(msg.body)
    assert msg.body =~ "CHAT-BODY-SENTINEL"
    # The vaulted composite resolves clear on the tenant plane (a FullName struct or its
    # revealed JSON) — either way the real name is present and NOT masked.
    refute match?(%Samen.Masked{}, part.full_name)
    assert clear_name(part.full_name) =~ "Cordelia"
  end

  test "OrgScope narrows chat reads to the actor's org (a cross-org thread is invisible)" do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    chat_a = Seeds.seed_chat(org_a)
    _chat_b = Seeds.seed_chat(org_b)

    require Ash.Query
    scope_b = %Samen.Scope{actor: %{id: "b", org_id: org_b, role: :member, kind: :tenant, plane: :tenant}}

    rows =
      ChatThread
      |> Ash.Query.filter(id == ^chat_a.thread.id)
      |> Ash.read!(scope: scope_b)

    # Org B cannot read org A's thread — zero rows (OrgScope), no leak.
    assert rows == []
  end

  defp clear_name(%Samen.Type.FullName{first: f, last: l}), do: String.trim("#{f} #{l}")
  defp clear_name(name) when is_binary(name), do: name
  defp clear_name(other), do: inspect(other)

  # Re-read a just-created record with the given (vaulted) attributes selected, so they arrive
  # as their `%Masked{}` token value (a create returns them `%Ash.NotLoaded{}`). The real reads
  # layer does this via `ensure_selected`; this mirrors it for the direct-resolve assertions.
  defp reselect(record, attrs) do
    require Ash.Query

    record.__struct__
    |> Ash.Query.ensure_selected(attrs)
    |> Ash.Query.filter(id == ^record.id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end
end

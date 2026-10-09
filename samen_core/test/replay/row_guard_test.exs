defmodule Samen.Replay.RowGuardTest do
  @moduledoc """
  ADR-052 §2.2.1 (gate fix) — the replay tables' LAST LINE is on the resources, not only in
  `Samen.Replay.Store`. The gate wrote a frame whose payload held `"Aurelia Sentinelson"` and a
  session whose `view` was that name with a direct `Ash.create(authorize?: false)` — both
  stored, because the frame-schema check lived only in the store's code path. Now
  `Samen.Replay.RowGuard` runs on every `:record` create (single or bulk, authorized or not).

  Each refusal pairs with a positive control (the same call with a kernel-shaped row succeeds),
  and the raw tables are scanned for the sentinel.
  """
  use ExUnit.Case, async: false

  alias Samen.Replay.{FrameSchema, Frame, Kept, Redacted, RowGuard, Session}

  @repo SamenCore.TestRepo
  @name "Aurelia Sentinelson"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    %{org: Ash.UUID.generate()}
  end

  defp session_attrs(org, extra \\ %{}) do
    Map.merge(
      %{
        org_id: org,
        view: "Samen.Web.CRM.ContactsLive",
        view_md5: String.duplicate("ab", 16),
        actor_ref: String.duplicate("0f", 32),
        started_at: DateTime.utc_now()
      },
      extra
    )
  end

  defp create_session(attrs) do
    Session
    |> Ash.Changeset.for_create(:record, attrs)
    |> Ash.create(authorize?: false)
  end

  defp create_frame(org, session_id, payload, extra \\ %{}) do
    Frame
    |> Ash.Changeset.for_create(
      :record,
      Map.merge(
        %{org_id: org, session_id: session_id, seq: 1, kind: :render, at_ms: 0, payload: payload},
        extra
      )
    )
    |> Ash.create(authorize?: false)
  end

  defp raw do
    %{rows: rows} =
      @repo.query!(
        "SELECT rpf_payload::text FROM replay_frame UNION ALL " <>
          "SELECT row_to_json(s)::text FROM replay_session s"
      )

    rows |> List.flatten() |> Enum.join("\n")
  end

  defp encoded(assigns),
    do: FrameSchema.encode({1, 0, :render, %{assigns: assigns}}).payload

  test "a frame with a bare string in its tree is refused on a direct, unauthorized create", ctx do
    {:ok, session} = create_session(session_attrs(ctx.org))

    # Positive control: a kernel-shaped (encoded, sanitized) payload is accepted.
    good = encoded(%{n: 1, t: %Redacted{kind: :string, length: 19}, title: %Kept{value: "Inbox"}})
    assert {:ok, _} = create_frame(ctx.org, session.id, good)

    assert {:error, %Ash.Error.Invalid{} = err} =
             create_frame(ctx.org, session.id, %{"assigns" => %{"x" => @name}}, %{seq: 2})

    refute inspect(err) =~ "Aurelia"

    # An undeclared payload field, a kind outside the schema and a free-string marker body.
    assert {:error, _} = create_frame(ctx.org, session.id, %{"leak" => 1}, %{seq: 3})

    assert {:error, _} =
             create_frame(ctx.org, session.id, %{"assigns" => %{"$id" => %{"value" => @name}}}, %{
               seq: 4
             })

    refute raw() =~ "Aurelia"
  end

  test "bulk_create (the store's own path) is guarded too", ctx do
    {:ok, session} = create_session(session_attrs(ctx.org))

    rows =
      for {payload, seq} <- [{encoded(%{n: 1}), 1}, {%{"assigns" => %{"x" => @name}}, 2}] do
        %{org_id: ctx.org, session_id: session.id, seq: seq, kind: :render, at_ms: 0, payload: payload}
      end

    result = Ash.bulk_create(rows, Frame, :record, authorize?: false, return_errors?: true)
    assert result.error_count == 1
    refute raw() =~ "Aurelia"
  end

  test "a session's strings must be what the kernel writes", ctx do
    assert {:ok, _} = create_session(session_attrs(ctx.org))
    # A nil actor (no live subject key) and a nil MD5 are allowed.
    assert {:ok, _} = create_session(session_attrs(ctx.org, %{actor_ref: nil, view_md5: nil}))

    for {field, value} <- [
          view: @name,
          view: nil,
          view_md5: "not-a-digest",
          actor_ref: Ash.UUID.generate(),
          actor_ref: "aurelia@example.com",
          actor_ref: String.duplicate("AB", 32)
        ] do
      assert {:error, %Ash.Error.Invalid{}} =
               create_session(session_attrs(ctx.org, %{field => value})),
             "#{field} accepted #{inspect(value)}"
    end

    refute raw() =~ "Aurelia"
    refute raw() =~ "aurelia@"
  end

  test "init/1 accepts only the two row kinds" do
    assert {:ok, _} = RowGuard.init(row: :frame)
    assert {:ok, _} = RowGuard.init(row: :session)
    assert {:error, _} = RowGuard.init(row: :other)
  end
end

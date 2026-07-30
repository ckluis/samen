defmodule Samen.Scopes.ChatRetentionRosterTest do
  @moduledoc """
  ADR-040 §5.6 (T37g — retention integration + archived-count sweep, closing out the
  T37 adoption sweep after T36 + T37a–f all shipped DONE+CONFIRMED). Chat is the
  `samen_web` rider on T37e's primitives item (ADR-040 §5.9's "primitives+chat" row):
  `ChatThread` (cascade parent) plus `ChatParticipant`/`ChatMessage` (cascade
  children, substrate-only — see `chat_scope_archival_leak_red_path_test.exs` for
  their `forbid_if(always())` direct-archive lock, which does NOT gate the
  `:destroy_permanently`/`:archived` actions retention rides) all flip
  `archivable: true`. This file closes the roster-coverage gap
  `demo/test/retention_archived_roster_test.exs` leaves open — demo does not mount
  the Chat scope.

  Proves, by WALKING the domain's catalog (`Samen.Retention.archivable_specs/2`,
  never a hand-maintained resource list): every chat archivable resource gets a
  `Retention.Spec{timestamp_field: :archived_at}` entry; and end-to-end on a REAL
  adopted resource (`ChatThread`, not a kernel pilot): an archived thread past its
  retention window is truly purged (`:destroy_permanently`), one within the window
  is retained, and the archived-count sweep report is accurate.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Retention
  alias Samen.Retention.Spec
  alias Samen.WebTest.Chat.ChatThread

  @now ~U[2026-07-29 12:00:00Z]

  defp mk_thread(org_id, subject) do
    {:ok, t} =
      ChatThread
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        subject: "#{subject}-#{:rand.uniform(999_999)}",
        kind: :cross_plane,
        status: :open,
        disclosure_mode: :masked
      })
      |> Ash.create(authorize?: false)

    t
  end

  defp backdate!(table, id_col, col, id, age_days, now) do
    ts = DateTime.add(now, -age_days * 24 * 60 * 60, :second) |> DateTime.truncate(:microsecond)
    Repo.query!("UPDATE #{table} SET #{col} = $1 WHERE #{id_col} = $2", [ts, Ecto.UUID.dump!(id)])
  end

  describe "archivable_specs/2 walks the Chat domain's catalog (§5.6)" do
    test "ChatThread/ChatParticipant/ChatMessage each get a spec; ChatDisclosureSetting does not" do
      specs = Retention.archivable_specs(Samen.WebTest.Chat)

      archivable_resources =
        Samen.WebTest.Chat
        |> Samen.Catalog.resource_modules()
        |> Enum.filter(&Samen.Info.archivable?/1)
        |> MapSet.new()

      spec_resources = specs |> Enum.map(& &1.resource) |> MapSet.new()

      assert spec_resources == archivable_resources
      assert Enum.all?(specs, &(&1.timestamp_field == :archived_at))

      assert MapSet.member?(spec_resources, Samen.WebTest.Chat.ChatThread)
      assert MapSet.member?(spec_resources, Samen.WebTest.Chat.ChatParticipant)
      assert MapSet.member?(spec_resources, Samen.WebTest.Chat.ChatMessage)

      # ChatDisclosureSetting is the roster's named exclusion (a live per-org config
      # row — delete is delete) — never picked up by the catalog walk.
      refute MapSet.member?(spec_resources, Samen.WebTest.Chat.ChatDisclosureSetting)
    end
  end

  describe "end-to-end sweep on a REAL adopted resource — ChatThread (§5.6)" do
    test "archived thread past its window is truly purged; one within the window is retained; report is accurate" do
      org = Ash.UUID.generate()
      stale = mk_thread(org, "stale")
      fresh = mk_thread(org, "fresh")

      {:ok, _} = Samen.Archival.archive(stale, authorize?: false)
      {:ok, _} = Samen.Archival.archive(fresh, authorize?: false)

      backdate!("wct_thread", "wct_id", "wct_archived_at", stale.id, 400, @now)

      spec = %Spec{
        resource: ChatThread,
        ttl_seconds: 365 * 24 * 60 * 60,
        action: :delete,
        timestamp_field: :archived_at
      }

      report = Retention.sweep([spec], now: @now)

      assert report.swept == 1
      assert report.archived == 1
      assert [%{resource: ChatThread, action: :delete, swept: 1, archived: 1}] = report.by_spec

      %{rows: [[n]]} =
        Repo.query!("SELECT count(*) FROM wct_thread WHERE wct_id = $1", [Ecto.UUID.dump!(stale.id)])

      assert n == 0

      archived_ids =
        ChatThread |> Ash.Query.for_read(:archived) |> Ash.read!(authorize?: false) |> Enum.map(& &1.id)

      assert fresh.id in archived_ids
      refute stale.id in archived_ids
    end
  end
end

defmodule Samen.Web.SavedViewsTest do
  @moduledoc """
  G10 saved views (T58) — the framework saved-views capability (`Samen.Web.SavedViews` over
  the host-owned `Views.SavedView` resource). Proves the six adversarial properties:

    (a) SAVE + RESTORE round-trips a view's TYPE + params for every WS-G view type;
    (b) CRUD — create / rename / delete;
    (c) ORG-SCOPE — a user in org B cannot read/load/update/delete a saved view in org A
        (2-org, sabotage-refutable by the org-A positive control);
    (d) PER-USER — user2 cannot read/modify/delete user1's private view in the SAME org
        (sabotage-refutable by the user1 positive control);
    (e) STORED-FILTER PII — a FILTER/SORT reference to a vault-routed (🔒) field is REFUSED,
        never persisted as plaintext;
    (f) RESTORE UNTRUSTED — a tampered params blob (org_id override, a vaulted/unseen field,
        an injected raw query) does NOT escape org-scope or load another org's data.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.ListState
  alias Samen.Web.SavedViews
  alias Samen.Web.SavedViews.{Params, Whitelist}
  alias Samen.WebTest.Crm.Person
  alias Samen.WebTest.Views.SavedView

  @surface "crm.person"

  defp whitelist do
    Whitelist.new(Person,
      sortable: [:display_name, :job_title, :inserted_at],
      filter_fields: [:display_name, :job_title],
      groupable: [:job_title],
      date_fields: [:inserted_at],
      columns: [:display_name, :job_title, :full_name]
    )
  end

  # A whitelist that (mis)includes VAULTED fields in the sort/filter role lists — proving the
  # vault gate refuses persisting them EVEN when a misconfigured whitelist would otherwise
  # admit them (the vault check is the last line, independent of whitelist membership).
  defp pii_whitelist do
    Whitelist.new(Person,
      sortable: [:display_name, :full_name],
      filter_fields: [:display_name, :emails],
      columns: [:display_name, :full_name]
    )
  end

  defp uid, do: Ash.UUID.generate()

  # ==========================================================================
  # (a) round-trip: TYPE + params, every WS-G view type (table-driven)
  # ==========================================================================

  @roundtrip_cases [
    {:table, %ListState{sort: {:display_name, :asc}, filter: "acme", page_size: 25},
     %{columns: [:display_name, :job_title]}},
    {:board, %ListState{sort: {:job_title, :desc}},
     %{group_by: :job_title, caps: %{per_group: 20, max_groups: 10}}},
    {:kanban, %ListState{}, %{group_by: :job_title}},
    {:calendar, %ListState{},
     %{date_field: :inserted_at, window: %{start: ~D[2026-01-01], end: ~D[2026-02-01]}}},
    {:timeline, %ListState{}, %{date_field: :inserted_at}},
    {:gantt, %ListState{}, %{date_field: :inserted_at}},
    {:gallery, %ListState{sort: {:display_name, :asc}, page_size: 12},
     %{columns: [:display_name, :full_name]}},
    {:tree, %ListState{}, %{caps: %{sibling_limit: 25, max_depth: 3}}},
    {:chart, %ListState{}, %{group_by: :job_title, caps: %{max_points: 8}}},
    {:dashboard, %ListState{filter: "x"}, %{}}
  ]

  for {view_type, state, view_params} <- @roundtrip_cases do
    @tag view_type: view_type
    test "round-trips a #{view_type} view's type + params" do
      org = uid()
      user = uid()
      state = unquote(Macro.escape(state))
      view_params = unquote(Macro.escape(view_params))
      view_type = unquote(view_type)

      {:ok, sv} =
        SavedViews.save(
          SavedView,
          org,
          user,
          %{
            name: "rt-#{view_type}",
            surface: @surface,
            view_type: view_type,
            list_state: state,
            view_params: view_params
          },
          whitelist()
        )

      {:ok, loaded} = SavedViews.get(SavedView, org, user, sv.id)
      {rt_type, rt_state, rt_params} = SavedViews.apply(loaded, whitelist())

      # TYPE round-trips (from the enum-constrained column).
      assert rt_type == view_type

      # ListState fields round-trip.
      assert rt_state.sort == state.sort
      assert rt_state.filter == state.filter

      # view-type params round-trip (only the keys this case set).
      if gb = view_params[:group_by], do: assert(rt_params.group_by == gb)
      if df = view_params[:date_field], do: assert(rt_params.date_field == df)
      if cols = view_params[:columns], do: assert(rt_params.columns == cols)

      if win = view_params[:window] do
        assert rt_params.window[:start] == win.start
        assert rt_params.window[:end] == win.end
      end

      if caps = view_params[:caps] do
        for {k, v} <- caps, do: assert(rt_params.caps[to_string(k)] == v)
      end
    end
  end

  # ==========================================================================
  # (b) CRUD — create / rename / delete
  # ==========================================================================

  test "create / rename / delete a saved view" do
    org = uid()
    user = uid()

    {:ok, sv} =
      SavedViews.save(SavedView, org, user, %{name: "First", surface: @surface}, whitelist())

    assert [%{name: "First"}] = SavedViews.list(SavedView, org, user, @surface)

    {:ok, _} = SavedViews.rename(SavedView, org, user, sv.id, "Renamed")
    assert [%{name: "Renamed"}] = SavedViews.list(SavedView, org, user, @surface)

    assert :ok = SavedViews.delete(SavedView, org, user, sv.id)
    assert [] = SavedViews.list(SavedView, org, user, @surface)
  end

  # ==========================================================================
  # (c) ORG-SCOPE — 2-org isolation (sabotage-refutable positive control)
  # ==========================================================================

  test "a user in org B cannot read/load/rename/delete a saved view in org A" do
    org_a = uid()
    org_b = uid()
    user = uid()

    {:ok, sv} =
      SavedViews.save(SavedView, org_a, user, %{name: "OrgA only", surface: @surface}, whitelist())

    # POSITIVE control: the org-A owner sees it (proves the red assertions are refutable).
    assert [%{name: "OrgA only"}] = SavedViews.list(SavedView, org_a, user, @surface)
    assert {:ok, _} = SavedViews.get(SavedView, org_a, user, sv.id)

    # RED: org B (even the same user id) sees nothing and cannot touch it.
    assert [] = SavedViews.list(SavedView, org_b, user, @surface)
    assert {:error, :not_found} = SavedViews.get(SavedView, org_b, user, sv.id)
    assert {:error, :not_found} = SavedViews.rename(SavedView, org_b, user, sv.id, "hijack")
    assert {:error, :not_found} = SavedViews.delete(SavedView, org_b, user, sv.id)

    # The org-A row is untouched after org B's attempts.
    assert {:ok, %{name: "OrgA only"}} = SavedViews.get(SavedView, org_a, user, sv.id)
  end

  # ==========================================================================
  # (d) PER-USER — same-org user isolation (private view stays private)
  # ==========================================================================

  test "user2 cannot read/rename/delete user1's private saved view in the same org" do
    org = uid()
    user1 = uid()
    user2 = uid()

    {:ok, sv} =
      SavedViews.save(SavedView, org, user1, %{name: "User1 private", surface: @surface}, whitelist())

    # POSITIVE control: user1 (the owner) sees it.
    assert [%{name: "User1 private"}] = SavedViews.list(SavedView, org, user1, @surface)
    assert {:ok, _} = SavedViews.get(SavedView, org, user1, sv.id)

    # RED: user2 in the SAME org sees nothing and cannot touch it.
    assert [] = SavedViews.list(SavedView, org, user2, @surface)
    assert {:error, :not_found} = SavedViews.get(SavedView, org, user2, sv.id)
    assert {:error, :not_found} = SavedViews.rename(SavedView, org, user2, sv.id, "hijack")
    assert {:error, :not_found} = SavedViews.delete(SavedView, org, user2, sv.id)

    # user1's row is untouched after user2's attempts.
    assert {:ok, %{name: "User1 private"}} = SavedViews.get(SavedView, org, user1, sv.id)
  end

  test "a create cannot spoof a foreign owner_id (policy-enforced)" do
    org = uid()
    user1 = uid()
    user2 = uid()

    # Attempt to create a row OWNED by user2 while acting as user1 → OwnerOnly forbids.
    result =
      SavedView
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org, owner_id: user2, name: "spoof", surface: @surface, view_type: :table},
        scope: SavedViews.owner_scope(org, user1)
      )
      |> Ash.create()

    assert {:error, _} = result
    # Nothing was written for either user.
    assert [] = SavedViews.list(SavedView, org, user1, @surface)
    assert [] = SavedViews.list(SavedView, org, user2, @surface)
  end

  # ==========================================================================
  # (e) STORED-FILTER PII — a vaulted field reference is REFUSED, never persisted
  # ==========================================================================

  test "a structured FILTER on a vaulted (🔒) field is refused and not persisted" do
    org = uid()
    user = uid()

    result =
      SavedViews.save(
        SavedView,
        org,
        user,
        %{
          name: "leaky",
          surface: @surface,
          view_params: %{filters: %{emails: "alice@example.com"}}
        },
        pii_whitelist()
      )

    assert {:error, {:vaulted_field, :emails}} = result
    # No row was persisted — the plaintext PII never reached the params column.
    assert [] = SavedViews.list(SavedView, org, user, @surface)
  end

  test "a SORT on a vaulted (🔒) field is refused" do
    org = uid()
    user = uid()

    result =
      SavedViews.save(
        SavedView,
        org,
        user,
        %{name: "s", surface: @surface, list_state: %ListState{sort: {:full_name, :asc}}},
        pii_whitelist()
      )

    assert {:error, {:vaulted_field, :full_name}} = result
    assert [] = SavedViews.list(SavedView, org, user, @surface)
  end

  test "a reference to a NON-whitelisted field is refused" do
    org = uid()
    user = uid()

    assert {:error, {:field_not_whitelisted, {:group, :ssn}}} =
             SavedViews.save(
               SavedView,
               org,
               user,
               %{name: "n", surface: @surface, view_params: %{group_by: :ssn}},
               whitelist()
             )

    assert [] = SavedViews.list(SavedView, org, user, @surface)
  end

  # ==========================================================================
  # (f) RESTORE UNTRUSTED — a tampered params blob cannot escape scope / inject
  # ==========================================================================

  test "restore SANITIZES a tampered params blob (org override, vaulted/unseen fields, injection)" do
    wl = whitelist()

    tampered = %{
      "view_type" => "table",
      # org_id override attempt — an unknown key; restore never reads it and the read
      # always re-applies OrgScope from the actor, so it is inert.
      "org_id" => uid(),
      # sort on a VAULTED field → dropped.
      "sort" => ["emails", "asc"],
      # structured predicates: a vaulted key AND an org_id override key → both dropped.
      "filters" => %{"emails" => "leak@x.com", "org_id" => "other-org", "display_name" => "ok"},
      # group by an UNSEEN field → dropped.
      "group_by" => "secret_field",
      # columns: an unseen "evil" column dropped; the whitelisted (vaulted-but-display) one kept.
      "columns" => ["full_name", "evil_col"],
      # raw-query injection attempt in the freeform box → kept as an inert parameterized string.
      "filter" => "'; DROP TABLE wvs_saved_view; --",
      # page size well above the max → clamped.
      "page_size" => 9_999_999
    }

    {view_type, state, view_params} = Params.restore(tampered, wl)

    assert view_type == :table
    # vaulted sort dropped.
    assert state.sort == nil
    # the freeform string survives verbatim but only ever drives a parameterized `contains`
    # over NON-vaulted filter_fields — it is inert as SQL.
    assert state.filter == "'; DROP TABLE wvs_saved_view; --"
    # page size clamped to the bound.
    assert state.page_size == Samen.Web.Reads.max_page_size()

    # structured filters: only the whitelisted, non-vaulted key survives; the vaulted key
    # and the org_id override are gone.
    assert view_params.filters == %{display_name: "ok"}
    refute Map.has_key?(view_params.filters, :emails)
    refute Map.has_key?(view_params.filters, :org_id)

    # unseen group field dropped; only the whitelisted column survives.
    assert view_params.group_by == nil
    assert view_params.columns == [:full_name]

    # The restored triple carries NO org_id — org-scope is the actor's, not the blob's.
    refute Map.has_key?(Map.from_struct(state), :org_id)
  end

  test "loading + restoring a tampered row stays org+user scoped (no cross-org data reachable)" do
    org_a = uid()
    org_b = uid()
    user = uid()
    wl = whitelist()

    # Seed a tampered row DIRECTLY (bypassing the strict save) in org A, whose blob tries to
    # pin org B.
    {:ok, sv} =
      SavedView
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_a,
          owner_id: user,
          name: "tampered",
          surface: @surface,
          view_type: :table,
          params: %{"org_id" => org_b, "sort" => ["emails", "asc"]}
        },
        authorize?: false
      )
      |> Ash.create()

    # An org-B actor cannot even LOAD it (org-scope) — the tampered org_id in the blob is
    # irrelevant; scope comes from the actor.
    assert {:error, :not_found} = SavedViews.get(SavedView, org_b, user, sv.id)

    # The legitimate org-A owner loads + restores it; the blob's org override is dropped and
    # the vaulted sort is dropped — the restored state cannot reach org B's data.
    {:ok, loaded} = SavedViews.get(SavedView, org_a, user, sv.id)
    {_vt, state, _vp} = SavedViews.apply(loaded, wl)
    assert state.sort == nil
  end
end

defmodule Samen.Web.KeysetSortParityTest do
  @moduledoc """
  ARCH-4 — the tenant keyset index is `(org_id, <keyset_sort>, id)`, and `keyset_sort` is declared on
  the RESOURCE (`use Samen.Resource, keyset_sort: :name`) while the page that walks it names its own
  `default_sort` in the LiveView (`use Samen.Web.ListLive, default_sort: {:name, :asc}`). Two
  declarations of one fact drift; this test pins them together so the index always matches the page.

  It discovers every compiled `ListLive` view (so a new list view without a matching declaration
  fails here, not in production), resolves its `resource:` through each test-host namespace, and
  asserts that every ORG-SCOPED resource that name resolves to declares `keyset_sort ==` the view's
  default sort field (`nil` for a view that sorts by `id`).

  Anti-tautology: the discovery is asserted to find the known views, and a deliberately wrong
  declaration is shown to be caught by the comparison.
  """
  use ExUnit.Case, async: true

  @namespaces [
    Samen.WebTest.Crm,
    Samen.WebTest.Billing,
    Samen.WebTest.Support,
    Samen.WebTest.Work,
    Samen.WebTest.Marketing,
    Samen.WebTest.Operator,
    Samen.WebTest.Primitives,
    Samen.WebTest.Automation
  ]

  # Not org-scoped keyset reads, so no org keyset index applies. Each reason is literal.
  @excluded %{
    # reads the operator's own account book through `Reads.page_operator!/3`; `Org` is read via
    # `OrgIsSelf`, not `OrgScope` (`Samen.Indexing.classify/1` => :not_org_scoped)
    Samen.Web.Operator.AccountsLive => "Org is not OrgScope-read"
  }

  defp views do
    {:ok, mods} = :application.get_key(:samen_web, :modules)

    for m <- mods, Code.ensure_loaded?(m), function_exported?(m, :__list_config__, 0), do: m
  end

  defp org_scoped_candidates(name) do
    for ns <- @namespaces,
        mod = Module.concat(ns, name),
        Code.ensure_loaded?(mod) and Ash.Resource.Info.resource?(mod),
        Samen.Indexing.classify(mod) == :org_scoped,
        do: mod
  end

  defp expected_sort({:id, _dir}), do: nil
  defp expected_sort({field, _dir}), do: field

  # The comparison itself: nil when the declared `keyset_sort` is the one the view pages by, else
  # the message naming the drift. `declared` is a parameter so the refutability test can run a
  # WRONG declaration through exactly this function.
  defp mismatch(view, config, resource, declared) do
    if declared == expected_sort(config.default_sort) do
      nil
    else
      "#{inspect(view)} sorts by #{inspect(config.default_sort)} but #{inspect(resource)} declares " <>
        "keyset_sort #{inspect(declared)}: the index (org_id, <sort>, id) would not " <>
        "serve the page. Change `keyset_sort:` in the scope blueprint or the view's `default_sort`."
    end
  end

  test "the known list views are discovered (the sweep is not vacuous)" do
    names = views() |> Enum.map(&Module.split/1) |> Enum.map(&List.last/1)
    assert "ContactsLive" in names and "TicketsLive" in names and "TasksLive" in names
    assert length(views()) >= 15
  end

  test "every shipped list view's default sort is the keyset_sort of the resources it pages" do
    for view <- views(), not Map.has_key?(@excluded, view) do
      config = view.__list_config__()
      candidates = org_scoped_candidates(config.resource)

      assert candidates != [],
             "#{inspect(view)} pages `#{inspect(config.resource)}`, which no test namespace resolves to an " <>
               "org-scoped resource — the index contract cannot be checked for it"

      for resource <- candidates do
        assert mismatch(view, config, resource, Samen.Info.keyset_sort(resource)) == nil
      end
    end
  end

  test "the comparison is refutable: a wrong declaration is caught, the right one is not" do
    view = Samen.Web.CRM.ContactsLive
    config = view.__list_config__()
    [person | _] = org_scoped_candidates(config.resource)

    right = Samen.Info.keyset_sort(person)
    assert mismatch(view, config, person, right) == nil

    for wrong <- [:job_title, nil] do
      message = mismatch(view, config, person, wrong)
      assert is_binary(message)
      assert message =~ "would not serve the page"
      assert message =~ "declares keyset_sort #{inspect(wrong)}"
    end
  end

  test "the newest-first message window (`Reads.newest_window/3`, inserted_at DESC, id DESC) matches Message's keyset_sort" do
    assert Samen.Info.keyset_sort(Samen.WebTest.Support.Message) == :inserted_at
  end
end

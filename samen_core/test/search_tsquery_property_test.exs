defmodule Samen.SearchTsqueryPropertyTest do
  @moduledoc """
  WS-F4 QA property — `Samen.Search.query/3` is ROBUST to arbitrary user input,
  including the tsquery special/operator characters (`& | ! : ( ) * ' " \\ <->`).

  The engine funnels every term through Postgres `websearch_to_tsquery` (NOT the raw
  `to_tsquery`, which RAISES a `SyntaxError` on an unbalanced `(` / a bare `&`). The
  property proves the choice holds end-to-end against a REAL Postgres DB: for arbitrary
  strings — random printable text, and text deliberately salted with tsquery operator
  characters — `query/3` NEVER raises and always returns a proper result list. A
  regression to `to_tsquery` (or any hand-built tsquery string) would surface here as a
  raised `Postgrex.Error` under an unlucky generated term.

  Companion to `search_engine_test.exs` (the behavioural gate) — this is the fuzz twin.
  Pattern reference: `abbrev_property_test.exs` (StreamData over the real production path).
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Samen.Files
  alias Samen.Files.Storage.Local
  alias Samen.Search
  alias SamenCore.TestRepo
  alias SamenCore.Support.NotificationFixture.File, as: FileResource
  alias SamenCore.Support.NotificationFixture.SearchIndex

  @file_name inspect(FileResource)

  # The tsquery operator/special characters that make a HAND-BUILT `to_tsquery` string
  # blow up. `websearch_to_tsquery` must swallow every one of them.
  @tsquery_specials [
    "&", "|", "!", ":", "(", ")", "<", ">", "-", "*", "'", "\"", "\\",
    "+", "=", "@", "[", "]", "{", "}", "~", "`", "^", "%", "<->"
  ]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

    root = Path.join(System.tmp_dir!(), "search_tsq_prop_#{System.unique_integer([:positive])}")
    Elixir.File.rm_rf!(root)
    on_exit(fn -> Elixir.File.rm_rf!(root) end)

    org = Ash.UUID.generate()
    register!(org, "filename")

    {:ok, _} =
      Files.upload(
        %{org_id: org, actor_id: Ash.UUID.generate()},
        %{filename: "quarterly invoice report.pdf", content_type: "application/pdf", binary: "x"},
        file_module: FileResource,
        repo: TestRepo,
        storage: Local,
        storage_config: %{root: root},
        max_bytes: 1_000_000,
        allowed_content_types: ~w(text/plain application/pdf)
      )

    %{org: org}
  end

  defp register!(org_id, field) do
    SearchIndex
    |> Ash.Changeset.for_create(:create, %{
      resource_name: @file_name,
      field_name: field,
      vector_column: "nef_search_vector",
      enabled: true,
      ts_config: "english",
      org_id: org_id
    })
    |> Ash.create!(authorize?: false)
  end

  defp scope(org_id), do: %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}

  defp search_opts, do: [resources: [FileResource], search_index: SearchIndex, repo: TestRepo]

  # A term = random printable text interleaved with a run of tsquery special chars, so
  # generated terms routinely contain unbalanced parens, bare operators, quotes, etc.
  defp fuzz_term do
    gen all(
          words <- StreamData.list_of(StreamData.string(:alphanumeric, min_length: 0, max_length: 6), max_length: 4),
          specials <- StreamData.list_of(StreamData.member_of(@tsquery_specials), max_length: 6),
          extra <- StreamData.string(:printable, max_length: 12)
        ) do
      (words ++ specials ++ [extra]) |> Enum.shuffle() |> Enum.join(" ")
    end
  end

  property "query/3 never raises on arbitrary terms salted with tsquery special chars", %{org: org} do
    check all(term <- fuzz_term(), max_runs: 150) do
      results = Search.query(scope(org), term, search_opts())
      assert is_list(results)
      assert Enum.all?(results, &match?(%Search.Result{}, &1))
    end
  end

  property "query/3 never raises on a bare run of ONLY tsquery operator characters", %{org: org} do
    check all(
            specials <- StreamData.list_of(StreamData.member_of(@tsquery_specials), min_length: 1, max_length: 10),
            max_runs: 80
          ) do
      term = Enum.join(specials, "")
      assert is_list(Search.query(scope(org), term, search_opts()))
    end
  end

  test "ANTI-TAUTOLOGY: a plain registered term still matches (the fuzz above is non-vacuous)", %{org: org} do
    assert [%Search.Result{}] = Search.query(scope(org), "invoice", search_opts())
  end
end

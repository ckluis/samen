defmodule Samen.SearchEngineTest do
  @moduledoc """
  WS-E E4.1 — the KERNEL search engine `Samen.Search.query/3` (ADR-027;
  AC-G9-1/2/4/5 · RP-SE-1/3/4). Exercised against a REAL Postgres DB via the
  `ne*`-abbrev `SamenCore.Support.NotificationFixture` mount (`File` = `nef`,
  `SearchIndex` = `nes`) and the REAL `Samen.Files.Storage.Local` adapter, so the
  `websearch_to_tsquery` / `ts_rank` path runs end-to-end on Postgres.

  Guarantees proven (each with a green path AND a red/anti-tautology twin):

    * **AC-G9-1 ranked, registry-driven results** — a term returns the matching File
      rows, ranked by `ts_rank`; the higher-relevance row ranks first.
    * **AC-G9-2 / RP-SE-1 registered-column-only** — only columns in the `SearchIndex`
      registry are searched; a term matching an UNREGISTERED non-PII column returns
      nothing (the column is unsearchable, not silently searchable). Registering a
      second field widens the match — proving the registry, not a hard-coded column
      list, drives the query.
    * **AC-G9-4 / RP-SE-3 org-scoped + bounded** — a search from org A never returns
      org B rows; `:limit` bounds the result set (a dataset larger than the limit
      returns exactly the limit).
    * **AC-G9-5 / RP-SE-4 fail-closed** — a blank term, an org with no registered
      index, and a resource the caller did not offer each return `[]`, never a dump.

  ## Anti-tautology

  The org-scope test seeds a matching row in a SECOND org and asserts it is ABSENT
  (a positive control in org A proves the term itself matches). The
  registered-column-only test proves BOTH directions: unregistered → no match, then
  registered → match (so a query that ignored the registry and searched every column
  would FAIL the first assertion). The bound test seeds `> limit` matches so an
  unbounded read would be DETECTED by the count.
  """
  use ExUnit.Case, async: false

  alias Samen.Files
  alias Samen.Files.Storage.Local
  alias Samen.Search
  alias SamenCore.TestRepo
  alias SamenCore.Support.NotificationFixture.File, as: FileResource
  alias SamenCore.Support.NotificationFixture.SearchIndex

  @file_name inspect(FileResource)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

    root = Path.join(System.tmp_dir!(), "search_test_#{System.unique_integer([:positive])}")
    Elixir.File.rm_rf!(root)
    on_exit(fn -> Elixir.File.rm_rf!(root) end)

    %{storage_config: %{root: root}}
  end

  defp scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}
    }
  end

  defp search_opts, do: [resources: [FileResource], search_index: SearchIndex, repo: TestRepo]

  defp upload!(ctx, org_id, filename, content_type \\ "text/plain") do
    {:ok, file} =
      Files.upload(
        %{org_id: org_id, actor_id: Ash.UUID.generate()},
        %{filename: filename, content_type: content_type, binary: "x"},
        file_module: FileResource,
        repo: TestRepo,
        storage: Local,
        storage_config: ctx.storage_config,
        max_bytes: 1_000_000,
        allowed_content_types: ~w(text/plain application/pdf image/png application/wonderword)
      )

    file
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

  describe "query/3 — ranked, registry-driven results (AC-G9-1)" do
    test "returns matching File rows ranked by ts_rank", ctx do
      org = Ash.UUID.generate()
      register!(org, "filename")

      upload!(ctx, org, "quarterly invoice report.pdf", "application/pdf")
      upload!(ctx, org, "unrelated meeting notes.txt")

      results = Search.query(scope(org), "invoice", search_opts())

      assert [%Search.Result{} = hit] = results
      assert hit.resource == FileResource
      assert hit.resource_name == @file_name
      assert hit.rank > 0.0
      assert hit.record.filename == "quarterly invoice report.pdf"
      # The display allowlist carries the registered non-PII field only.
      assert hit.display == %{filename: "quarterly invoice report.pdf"}
    end

    test "ranks the more-relevant row first", ctx do
      org = Ash.UUID.generate()
      register!(org, "filename")

      upload!(ctx, org, "invoice invoice invoice.pdf", "application/pdf")
      upload!(ctx, org, "one invoice among many other words here.pdf", "application/pdf")

      results = Search.query(scope(org), "invoice", search_opts())

      assert length(results) == 2
      assert [first, second] = results
      assert first.rank >= second.rank
      assert first.record.filename == "invoice invoice invoice.pdf"
    end
  end

  describe "registered-column-only (AC-G9-2 · RP-SE-1)" do
    test "a term matching an UNREGISTERED column returns nothing; registering it widens", ctx do
      org = Ash.UUID.generate()
      # Register ONLY filename. The MIME lexeme lives only in content_type (Postgres
      # FTS tokenizes a MIME type as a single lexeme, so it is a clean unregistered token).
      register!(org, "filename")

      upload!(ctx, org, "secret document.txt", "application/wonderword")

      # The content_type lexeme is NOT registered → no match.
      assert Search.query(scope(org), "application/wonderword", search_opts()) == []
      # Positive control: the registered column DOES match.
      assert [_] = Search.query(scope(org), "secret", search_opts())

      # Registering content_type widens the match — the registry drives the query.
      register!(org, "content_type")
      assert [_] = Search.query(scope(org), "application/wonderword", search_opts())
    end
  end

  describe "org-scoped + bounded (AC-G9-4 · RP-SE-3)" do
    test "a search from org A never returns org B rows", ctx do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      register!(org_a, "filename")
      register!(org_b, "filename")

      upload!(ctx, org_a, "shared keyword alpha.txt")
      upload!(ctx, org_b, "shared keyword beta.txt")

      results = Search.query(scope(org_a), "shared", search_opts())

      assert [hit] = results
      assert hit.record.filename == "shared keyword alpha.txt"
      assert hit.record.org_id == org_a
    end

    test "the result set is bounded by :limit", ctx do
      org = Ash.UUID.generate()
      register!(org, "filename")

      for i <- 1..6, do: upload!(ctx, org, "bounded token doc #{i}.txt")

      results = Search.query(scope(org), "bounded", Keyword.put(search_opts(), :limit, 3))

      assert length(results) == 3
    end
  end

  describe "fail-closed (AC-G9-5 · RP-SE-4)" do
    test "a blank term returns []", ctx do
      org = Ash.UUID.generate()
      register!(org, "filename")
      upload!(ctx, org, "anything at all.txt")

      assert Search.query(scope(org), "", search_opts()) == []
      assert Search.query(scope(org), "   ", search_opts()) == []
      assert Search.query(scope(org), nil, search_opts()) == []
    end

    test "an org with no registered index returns []", ctx do
      org = Ash.UUID.generate()
      upload!(ctx, org, "invoice with no registry.txt")

      assert Search.query(scope(org), "invoice", search_opts()) == []
    end

    test "a resource the caller did not offer returns []", ctx do
      org = Ash.UUID.generate()
      register!(org, "filename")
      upload!(ctx, org, "offered nowhere.txt")

      # No :resources → nothing is searched (deny-by-default).
      assert Search.query(scope(org), "offered", search_index: SearchIndex, repo: TestRepo, resources: []) ==
               []
    end
  end
end

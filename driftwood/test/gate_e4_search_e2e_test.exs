defmodule Driftwood.GateE4SearchE2ETest do
  @moduledoc """
  GATE PROBE (WS-E E4.4) — the ⌘K search engine end-to-end on a REAL host (Driftwood):
  the `samen_search_routes` macro mount + the KERNEL `Samen.Search` engine over
  Driftwood's Primitives (`File` + `SearchIndex`), plus the E4 tsvector trigger. Proves:

    * ranked, org-scoped results over the real vertical's registered non-PII column
      (AC-G9-1/4);
    * the E4 tsvector-populate TRIGGER materializes `ffl_search_vector` on upload
      (the framework-owned searchable column);
    * a search from org A never returns org B rows (org-scoped by construction).

  A gate artifact, not part of the shipped suites.
  """
  use Driftwood.DataCase, async: false

  alias Samen.Files
  alias Samen.Search
  alias Samen.Web.Plane

  alias Driftwood.Primitives.{File, SearchIndex}

  defp scope(org_id), do: Plane.scope(Plane.tenant(), org_id)

  defp register!(org_id, field \\ "filename") do
    SearchIndex
    |> Ash.Changeset.for_create(:create, %{
      resource_name: inspect(File),
      field_name: field,
      vector_column: "ffl_search_vector",
      enabled: true,
      ts_config: "english",
      org_id: org_id
    })
    |> Ash.create!(authorize?: false)
  end

  defp upload!(org_id, filename) do
    root = Path.join(System.tmp_dir!(), "gate_e4_#{System.unique_integer([:positive])}")
    on_exit(fn -> Elixir.File.rm_rf!(root) end)

    {:ok, file} =
      Files.upload(
        %{org_id: org_id},
        %{filename: filename, content_type: "application/pdf", binary: "x"},
        file_module: File,
        repo: Driftwood.Repo,
        storage_config: %{root: root},
        allowed_content_types: ~w(application/pdf)
      )

    file
  end

  defp opts,
    do: [resources: [File], search_index: SearchIndex, repo: Driftwood.Repo]

  test "ranked, org-scoped search over the real vertical; the E4 trigger materializes the tsvector" do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    register!(org_a)
    register!(org_b)

    file = upload!(org_a, "quarterly invoice report.pdf")
    upload!(org_a, "unrelated meeting notes.pdf")
    upload!(org_b, "invoice for another org.pdf")

    # The E4 tsvector-populate trigger materialized ffl_search_vector on insert.
    [[vector]] =
      Ecto.Adapters.SQL.query!(
        Driftwood.Repo,
        "SELECT ffl_search_vector FROM ffl_file WHERE ffl_id = $1",
        [Ecto.UUID.dump!(file.id)]
      ).rows

    assert is_binary(vector)
    assert vector =~ "invoic"

    # Ranked + org-scoped: org A's match only, org B never leaks.
    assert [%Search.Result{} = hit] = Search.query(scope(org_a), "invoice", opts())
    assert hit.record.filename == "quarterly invoice report.pdf"
    assert hit.record.org_id == org_a
    assert hit.rank > 0.0
  end
end

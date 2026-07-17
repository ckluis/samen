defmodule Samen.Web.SearchSurfaceTest do
  @moduledoc """
  WS-E E4.3 — the ⌘K SEARCH surface (`Samen.Web.Search.SearchLive` +
  `Samen.UI.command_palette`; ADR-027; AC-G9-1). Proves the framework page renders the
  KERNEL engine's ranked, org-scoped results through the palette — with ZERO authored
  search LiveViews (the vertical mounts one macro). Rendered via the established
  Endpoint-less harness (`render_live/3`), the SAME code path the mounted route runs.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Files
  alias Samen.Web.Mount
  alias Samen.Web.Plane

  alias Samen.WebTest.Primitives.{File, SearchIndex}

  defp search_mount do
    Mount.new(:search, Samen.WebTest.Primitives, Samen.WebTest.Repo,
      plane: Plane.tenant(),
      labels: %{title: "Test Org"}
    )
  end

  defp register!(org_id, field \\ "filename") do
    SearchIndex
    |> Ash.Changeset.for_create(:create, %{
      resource_name: inspect(File),
      field_name: field,
      vector_column: "wnf_search_vector",
      enabled: true,
      ts_config: "english",
      org_id: org_id
    })
    |> Ash.create!(authorize?: false)
  end

  defp upload!(org_id, filename) do
    root = Path.join(System.tmp_dir!(), "search_surface_#{System.unique_integer([:positive])}")
    on_exit(fn -> Elixir.File.rm_rf!(root) end)

    {:ok, _} =
      Files.upload(
        %{org_id: org_id, actor_id: Ash.UUID.generate()},
        %{filename: filename, content_type: "application/pdf", binary: "x"},
        file_module: File,
        repo: Samen.WebTest.Repo,
        storage_config: %{root: root},
        allowed_content_types: ~w(application/pdf)
      )
  end

  test "the search page renders ranked, org-scoped results through the palette" do
    org = Ash.UUID.generate()
    register!(org)
    upload!(org, "quarterly invoice report.pdf")
    upload!(org, "unrelated meeting notes.pdf")

    html = render_live(Samen.Web.Search.SearchLive, search_mount(), [org, "invoice"])

    # The matching file's display value renders; the non-match does not.
    assert html =~ "quarterly invoice report.pdf"
    refute html =~ "unrelated meeting notes.pdf"
    # The palette shell is present.
    assert html =~ "cmdk"
  end

  test "a search from org A never renders org B rows (org-scoped surface)" do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    register!(org_a)
    register!(org_b)
    upload!(org_a, "shared keyword alpha.pdf")
    upload!(org_b, "shared keyword beta.pdf")

    html = render_live(Samen.Web.Search.SearchLive, search_mount(), [org_a, "shared"])

    assert html =~ "shared keyword alpha.pdf"
    refute html =~ "shared keyword beta.pdf"
  end

  test "an empty term renders the palette with no result rows (fail-closed surface)" do
    org = Ash.UUID.generate()
    register!(org)
    upload!(org, "anything here.pdf")

    html = render_live(Samen.Web.Search.SearchLive, search_mount(), [org, ""])

    assert html =~ "cmdk"
    refute html =~ "anything here.pdf"
  end
end

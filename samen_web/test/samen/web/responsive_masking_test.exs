defmodule Samen.Web.ResponsiveMaskingTest do
  @moduledoc """
  WS-E E6.3 (ADR-030; AC-G20-2 / RP-RE-1) — MASKING SURVIVES THE RESPONSIVE PASS.

  The responsive kit change is CSS + value-blind kit markup only: the masking
  invariant lives in the VALUE layer (`Samen.Api.PiiResolution` → `%Samen.Masked{}`
  → `••••` via `Phoenix.HTML.Safe`), which the responsive `data_table`/`list_view`/
  `app_shell`/`skeleton` never touch. This test proves that a `%Samen.Masked{}`
  handed through the RESPONSIVE markup renders `••••` — the same at every width —
  with the vault token and any plaintext ABSENT (mask-by-omission), and that the
  scan is REFUTABLE (a modeled leaked render IS caught).

  Consumer of `Samen.MaskingCase` (E2i.1) — the same green/refutable discipline as
  the file-preview, search, CSV-export, and profile masking red-paths.

  The one refutable CODE seam E6 introduces is `list_view/1`'s `loading` state
  (the skeleton must render INSTEAD OF the record rows — records are not painted
  mid-load). That render-contract is bound to the committed sabotage
  `scripts/sabotages/15-e6-list-loading-paints-rows.patch` (flips the
  `loading-contract` test below).
  """
  use ExUnit.Case, async: true
  use Samen.MaskingCase

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Samen.Web.Page

  # A %Masked{} whose vault token MUST NEVER reach the DOM at any width, plus the
  # plaintext it stands in for (never rendered — the mask-by-omission target).
  @token "vt_RESPONSIVE_SECRET_should_never_render"
  @plaintext "Jane Vaulted Secret"
  @masked %Samen.Masked{token: @token, label: :pii_name}

  defp head_slot,
    do: [%{inner_block: fn _, _ -> Phoenix.HTML.raw(~s(<th scope="col">Name</th>)) end}]

  # -- data_table: a masked cell survives the responsive (.table-scroll) markup --

  test "a %Masked{} cell renders •••• through the responsive data_table (no token, no plaintext)" do
    html =
      render_component(&Samen.UI.data_table/1, %{
        head: head_slot(),
        inner_block: [%{inner_block: fn _, _ -> safe_row(~s(<tr><td>), @masked, "</td></tr>") end}]
      })

    # The value survived the new .table-scroll wrapper untouched.
    assert html =~ ~s(class="table-scroll")
    assert_masked_dom!(html, [@plaintext])
  end

  # -- list_view: a masked row survives at rest -------------------------------

  test "a %Masked{} row renders •••• through list_view at rest (no token)" do
    html =
      render_component(&Samen.UI.list_view/1, %{
        page: %Page{items: [%{id: "r1", name: @masked}], page_size: 5},
        head: head_slot(),
        row: [%{inner_block: fn _, item -> safe_row("<td>", item.name, "</td>") end}]
      })

    assert html =~ "<table>"
    assert_masked_dom!(html, [@plaintext])
  end

  # -- refutable twin: a modeled leaked render IS detected (anti-tautology) ------

  test "the mask scan is refutable — a modeled leaked render exposes the plaintext" do
    leaked =
      render_component(&Samen.UI.data_table/1, %{
        head: head_slot(),
        # A BROKEN resolver would hand a raw plaintext string to the cell.
        inner_block: [%{inner_block: fn _, _ -> Phoenix.HTML.raw("<tr><td>#{@plaintext}</td></tr>") end}]
      })

    assert_leak_detected!(leaked, @plaintext)
  end

  # -- loading-contract (SABOTAGE-BOUND: 15-e6) ---------------------------------

  test "loading-contract: list_view renders the skeleton INSTEAD OF the record rows" do
    html =
      render_component(&Samen.UI.list_view/1, %{
        page: %Page{items: [%{id: "r1", name: @masked}], page_size: 5},
        loading: true,
        head: head_slot(),
        row: [
          %{inner_block: fn _, item -> safe_row(~s(<td data-live-cell="1">), item.name, "</td>") end}
        ]
      })

    # The skeleton placeholder shows…
    assert html =~ ~s(class="skeleton")
    assert html =~ "list-loading"
    # …and the record rows are NOT painted mid-load (no leaked struct, no cell).
    refute html =~ "data-live-cell"
    refute html =~ @token
    refute html =~ @plaintext
  end

  # -- source scope guard: the responsive additions carry no unmasking path -----

  test "the responsive-touched Samen.UI kit carries no unmasking path" do
    # Drop each file's moduledoc prose (which legitimately DESCRIBES the no-reveal
    # posture); scan the code body only, mirroring Samen.UI.MaskingTest's
    # kit_code_only/0. `Samen.UI` is now a FACADE over `Samen.UI.*` family submodules,
    # so scan ui.ex AND every submodule under lib/samen/ui/ (table-scroll, def skeleton,
    # and nav-toggle-cb now live in Samen.UI.Table/Feedback/Shell respectively).
    dir = Path.join([File.cwd!(), "lib", "samen"])

    code =
      [Path.join(dir, "ui.ex") | Path.wildcard(Path.join([dir, "ui", "*.ex"]))]
      |> Enum.map(&File.read!/1)
      |> Enum.map(fn full ->
        case String.split(full, "use Phoenix.Component", parts: 2) do
          [_doc, body] -> body
          [only] -> only
        end
      end)
      |> Enum.join("\n")

    # The E6 responsive surface shipped…
    assert code =~ "table-scroll"
    assert code =~ "def skeleton"
    assert code =~ "nav-toggle-cb"
    # …and introduced no reveal / token-unwrap seam (mirrors the ui_masking scan).
    refute code =~ "Vault.reveal"
    refute code =~ ~r/%Samen\.Masked\{\s*token:/
  end

  # Build a single {:safe, iodata} cell/row from raw markup + a value, rendering
  # the value through `Phoenix.HTML.Safe` (the SAME protocol seam the kit renders
  # through) — a %Masked{} becomes `••••`, never its token. Wrapping in {:safe, …}
  # (rather than a bare list holding the struct) keeps `Phoenix.HTML.Safe.List`
  # from rejecting the struct in a keyed comprehension.
  defp safe_row(open, value, close) do
    {:safe, [open, Phoenix.HTML.Safe.to_iodata(value), close]}
  end
end

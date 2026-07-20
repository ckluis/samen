defmodule Samen.UI.MaskingTest do
  @moduledoc """
  The LOAD-BEARING masking-invariant tests for `Samen.UI` (ADR-009 §4.3, moved + renamed from
  the ADR-008 kit tests). A `%Samen.Masked{}` handed straight to a component renders `••••`
  via `Phoenix.HTML.Safe`, and the vault token string is ABSENT from the output. The kit has
  no unmasking path — it renders whatever value it is handed.
  """
  use ExUnit.Case, async: true
  use Samen.MaskingCase

  import Phoenix.LiveViewTest, only: [render_component: 2]

  # A %Masked{} carrying a token that MUST NOT appear in any rendered output.
  @token "vt_SECRET_TOKEN_should_never_render"
  @masked %Samen.Masked{token: @token, label: :pii_email}

  test "pill/1 renders a %Masked{} as •••• and never leaks the token" do
    html = render_component(&Samen.UI.pill/1, %{variant: "info", inner_block: masked_block()})

    assert html =~ "••••"
    refute html =~ @token
  end

  test "a data_table cell renders a %Masked{} as •••• and never leaks the token" do
    html =
      render_component(&Samen.UI.data_table/1, %{
        head: head_block(),
        inner_block: masked_row_block()
      })

    assert html =~ "••••"
    refute html =~ @token
  end

  test "progress/1 label renders a %Masked{} as •••• and never leaks the token" do
    html = render_component(&Samen.UI.progress/1, %{value: 50, label: @masked})

    assert html =~ "••••"
    refute html =~ @token
  end

  test "metric/1 value renders a %Masked{} as •••• and never leaks the token" do
    html = render_component(&Samen.UI.metric/1, %{label: "Secret", value: @masked})

    assert html =~ "••••"
    refute html =~ @token
  end

  test "ANTI-TAUTOLOGY: the token-leak scan is REFUTABLE — a RAW value renders verbatim" do
    # Every `refute html =~ @token` above passes because a %Masked{} renders •••• (never
    # the token). But the kit renders WHATEVER value it is handed — so a broken resolver
    # that handed the kit a raw token string (instead of wrapping PII in %Masked{}) WOULD
    # leak. Prove it: hand `pill/1` the raw token and confirm the leak scan catches it.
    html = render_component(&Samen.UI.pill/1, %{variant: "info", inner_block: raw_block()})
    assert_leak_detected!(html, @token)
  end

  test "the kit source CODE has no unmasking path (no Vault.reveal, no token unwrap)" do
    # Strip the moduledoc/prose (which legitimately DESCRIBES what the kit does NOT do) so we
    # scan the actual code body for a call to the vault or a token unwrap.
    code = kit_code_only()

    refute code =~ "Vault.reveal"
    refute code =~ "Samen.Vault"
    # The kit never pattern-matches a %Masked{} to pull a token out.
    refute code =~ "%Samen.Masked{token"
    refute code =~ ".token"
  end

  # The lib source with the leading @moduledoc heredoc removed (everything before
  # `use Phoenix.Component` is doc/prose).
  defp kit_code_only do
    src = File.read!(Path.join([File.cwd!(), "lib", "samen", "ui.ex"]))
    [_doc, code] = String.split(src, "use Phoenix.Component", parts: 2)
    code
  end

  # -- slot builders (a %Masked{} inner block) --------------------------------

  defp masked_block do
    [%{inner_block: fn _, _ -> @masked end}]
  end

  # A RAW token string (NOT a %Masked{}) — models a resolver that failed to wrap PII.
  defp raw_block do
    [%{inner_block: fn _, _ -> @token end}]
  end

  defp head_block do
    [%{inner_block: fn _, _ -> Phoenix.HTML.raw("<th>Value</th>") end}]
  end

  defp masked_row_block do
    [%{inner_block: fn _, _ -> Phoenix.HTML.html_escape(@masked) end}]
  end
end

defmodule Samen.ScopeMaskCase do
  @moduledoc """
  The **scope-mask** test harness (ADR-044 §16.3) — the SECOND, distinct mask class
  Amendment 1 introduces, a sibling to `Samen.MaskingCase` (the vault/plane mask), NOT
  a consumer of it.

  ## Why this is a separate harness (§16.3, stated so it can't be misread)

  The two mask classes differ on every axis:

  | | **vault/plane mask** (`Samen.MaskingCase`) | **scope mask** (this harness) |
  |---|---|---|
  | axis | the actor's **plane** (tenant / operator / operator-with-grant) | the viewer's **account scope** within one product |
  | data | a vault-routed 🔒 field, resolved via `Samen.Api.PiiResolution` | a plain `:string` of **SaaS-owned** data (a tenant's display name) |
  | masked form | `%Samen.Masked{}` → `••••`; a `vt_*` token must never appear | the row carries **no name AND no handle** — mask by OMISSION, no `••••` |

  So `MaskingCase`'s plane helpers (`resolve_on_plane/4`, `assert_plane_clear!/2`,
  `assert_plane_masked!/2`, `assert_two_plane!/3`) do **not** apply — they take a value
  resolved on a plane from a vault-routed field. What transfers is the **plaintext /
  handle absence-scan discipline** ("assert on the DOM, not on the assigns") and
  `Samen.MaskingCase.assert_leak_detected!/2` for refutability. The scope-mask masked
  form has **no `••••`**, so `assert_masked_dom!/2`'s mask-string assertion is
  deliberately NOT reused here — reaching for it is exactly the `MaskingCase`-misfit
  §16.3 warns about.

  ## The helpers

    * `assert_scope_masked!/3` — a masked tier-2 row (a scoped-out or `:none` viewer):
      the render contains **none** of `names` AND **none** of `handles`, the latter
      including inside DOM attribute values (`data-*`, `phx-value-*`, `href`) — the
      §16.4a "no handle in any attribute" ruling, asserted rather than left to the
      renderer. Anti-vacuous handle scan.
    * `assert_scope_resolved!/2` — a resolved row (an in-scope viewer): the render
      **does** contain the expected `names`, so a green proof cannot pass vacuously on
      an empty render (the anti-tautology half).

  The mixed-render case (§16.3) — one table with named rows and masked rows for the
  same salesperson viewer — is asserted by calling BOTH against a SINGLE render (the
  helpers take lists so one call covers the whole table).

  `use Samen.ScopeMaskCase` imports these plus `assert_leak_detected!/2`.
  """

  import ExUnit.Assertions

  defmacro __using__(_opts) do
    quote do
      import Samen.ScopeMaskCase
      import Samen.MaskingCase, only: [assert_leak_detected!: 2]
    end
  end

  @doc """
  RED half (mask by omission): a masked tier-2 row shows **none** of `names` and
  **none** of `handles`. The handle scan covers attribute values too (`data-`/
  `phx-value-`/`href`), the §16.4a DOM ruling — a masked row carries no name, no deep
  link, and no handle anywhere in the DOM (or in a CSV/API projection string).

  Both lists are wrapped, so one call asserts a whole table's masked rows. Returns the
  html (chainable). Anti-vacuous: an EMPTY `names`+`handles` pair is refused — a mask
  proof over nothing is meaningless.
  """
  @spec assert_scope_masked!(String.t(), [String.t()] | String.t(), [String.t()] | String.t()) ::
          String.t()
  def assert_scope_masked!(html, names, handles) when is_binary(html) do
    names = List.wrap(names)
    handles = List.wrap(handles)

    refute names == [] and handles == [],
           "assert_scope_masked!/3 was called with no names AND no handles — a mask assertion " <>
             "over nothing is vacuous; give it the names/handles the row must NOT contain"

    Enum.each(names, fn name ->
      refute html =~ name,
             "scope-mask by omission FAILED: tenant name #{inspect(name)} leaked into a row the " <>
               "viewer is not scoped to (§16.2/§16.3)"
    end)

    Enum.each(handles, fn handle ->
      refute html =~ handle,
             "scope-mask by omission FAILED: handle #{inspect(handle)} reached the client on a " <>
               "masked row (§16.4a: no name, no deep link, no handle in any DOM attribute)"
    end)

    html
  end

  @doc """
  GREEN half (anti-vacuous): a resolved tier-2 row shows the expected tenant display
  `names` inline. Refuses an EMPTY `names` list — the whole point is that a green proof
  cannot pass on an empty render. Returns the html.
  """
  @spec assert_scope_resolved!(String.t(), [String.t()] | String.t()) :: String.t()
  def assert_scope_resolved!(html, names) when is_binary(html) do
    names = List.wrap(names)

    refute names == [],
           "assert_scope_resolved!/2 was called with no names — a resolution proof that asserts " <>
             "nothing would pass on an empty render, the exact vacuity this helper exists to refuse"

    Enum.each(names, fn name ->
      assert html =~ name,
             "expected the resolved render to show the in-scope tenant name #{inspect(name)} " <>
               "inline, but it was absent (a resolution proof must not pass on an empty render)"
    end)

    html
  end
end

defmodule Samen.Scopes.Views do
  @moduledoc """
  The **Views** universal scope (G10 saved views, T58). Ships as a **library-authored
  blueprint** (ADR-004), same shape as `Samen.Scopes.Tags`/`Samen.Scopes.Docs`:
  `use`-ing this module inside a host's Ash domain expands into one host-owned resource
  in the host's namespace, a normal `use Samen.Resource` with the host's `otp_app`,
  `repo`, and `domain`.

  ## Resource — `saved_view`

  - **`SavedView`** — a per-user, org-scoped, NAMED snapshot of a list/view surface's UI
    state (the chosen view TYPE + a serialized, non-secret params blob). PRIVATE to its
    owner within its org (two-axis isolation: `Samen.Policy.OrgScope` +
    `Samen.Policy.OwnerOnly`). See `Samen.Scopes.Views.Blueprint`.

  ## Framework-first, ≈0-LOC adoption

  A list surface already declaring its bounded field lists (via `Samen.Web.ListLive`)
  adopts saved views by mounting this scope in ONE `use` line and calling
  `Samen.Web.SavedViews.{save,list,apply}/*` — no per-vertical resource, migration, or
  policy is re-authored. The samen_web test host mount (`Samen.WebTest.Views`) is the
  reference adopter.

  ## Mounting the Views scope (the host side)

      defmodule Demo.Views do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Views,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.Views,
          abbrevs: %{saved_view: "dvs"}
      end

  This defines, in the host's namespace:

    * `Demo.Views.SavedView`

  ## Abbrevs (permanent, registry-checked)

  Each host takes a fresh allocator-proposed abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name via
  `mix samen.abbrev.reserve` (ADR-023 — the macro does NOT invent abbrevs). No
  scope-default (mirrors Docs/Tags's "no pre-claimed default"):

    * `Samen.WebTest.Views.SavedView` → `wvs`
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    abbrevs = resolve_abbrevs(Keyword.fetch!(opts, :abbrevs), __CALLER__)

    saved_view_mod = Module.concat(namespace, SavedView)

    quote do
      require Samen.Scopes.Views.Blueprint

      resources do
        resource(unquote(saved_view_mod))
      end

      Samen.Scopes.Views.Blueprint.define_saved_view(
        unquote(saved_view_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.saved_view)
      )
    end
  end

  # No scope-default: `abbrevs:` is REQUIRED (mirrors Docs/Tags — every host takes a
  # fresh allocator-proposed abbrev).
  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    Map.new(pairs, fn {k, v} -> {Macro.expand(k, caller), Macro.expand(v, caller)} end)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Views, abbrevs: must be a compile-time map literal " <>
            "(%{saved_view: \"wvs\"}). Got: #{Macro.to_string(other)}"
  end
end

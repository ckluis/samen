defmodule Samen.Fleet.Assignment do
  @moduledoc """
  The **operator-account assignment** blueprint (ADR-044 §16.5 #1, operator ruling
  R-A) — the dedicated per-product resource that answers *"which tenant accounts is
  THIS operator scoped to, in THIS product?"*, the data source `scope_of/2` reads.

  ## Why this exists (the R-A correction)

  Amendment 1 makes a tenant's display **name** per-viewer-resolvable and — under
  ruling R-B (§16.4a) — gates tier-3 drill-in ENTRY on the same account scope. The
  first draft derived that scope from "the CRM owner field on the operator-plane
  account record", **a primitive that does not exist** (`owner_id` lives only on
  tenant-plane scopes and means *a tenant user owns a tenant record*). Ruling R-A
  withdraws that and replaces it with this dedicated model:

    * a small per-product resource mapping an **operator principal × `app_scope` → a
      set of tenant account org ids** — product-owned (it lives in the product's DB
      alongside the orgs it references), **token-blind** (operator id + account org
      ids are bounded uuids; the product slug is a bounded lowercase atom-slug; NO
      names, NO PII of any kind — enforced by `Samen.Verifiers.NoPiiColumns`, INV-2);
    * `scope_of/2` (via a host resolver, `Samen.Fleet.Resolution`) is its only reader;
    * **absent any row ⇒ `:none`** — a newly-added operator starts with no name
      visibility and no scoped drill-in access until someone assigns them. Fail-closed
      by ABSENCE, not by configuration.

  It is **not** a tenant-facing concept and **not** a CRM ownership model; it governs
  operator visibility/entry only. Broad roles (`:operator_admin` / `:operator_support`
  / `:operator_break_glass`) never need a row — they resolve `:all` (today's
  behaviour, unchanged); this resource scopes only the assignable roles.

  ## Mounting (a product with operator drill-ins adopts it, cockpit or not)

  Ships as a library-authored blueprint (ADR-004), the same shape as
  `Samen.Fleet.Scope` — `use`-ing it inside a host Ash domain expands into ONE
  host-owned resource in the host namespace, a normal `use Samen.Aggregate.Resource`
  with the host's `otp_app`/`repo`/`domain`:

      defmodule MyApp.OperatorScope do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Fleet.Assignment,
          otp_app: :my_app,
          repo: MyApp.Repo,
          namespace: MyApp.OperatorScope,
          abbrev: "moa"
      end

  A product with drill-ins but NO cockpit still mounts this (unlike
  `Samen.Fleet.Scope`, which is cockpit-only) — the R-B drill-in gate is
  fleet-independent (§16.4a).

  ## The minimal admin surface

  Create/revoke assignments run through `Samen.Fleet.Assignments` (this module's
  context), gated `:operator_admin` by `Samen.Policy.OperatorAdminOnly`. Deliberately
  minimal per R-A: no bulk import, no hierarchy, no delegation — speculative until
  someone asks. `scope_of/2`'s read path runs `authorize?: false` (the framework
  reading its own scope data to answer an already-authenticated operator's request,
  the `next_key_version` precedent).
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module
    abbrev = Keyword.fetch!(opts, :abbrev) |> Macro.expand(__CALLER__)

    unless is_binary(abbrev) do
      raise ArgumentError,
            "use Samen.Fleet.Assignment, abbrev: must be a compile-time 3-letter string " <>
              "literal reserved via `mix samen.abbrev.reserve` (ADR-023). Got: #{inspect(abbrev)}"
    end

    assignment_mod = Module.concat(namespace, Assignment)

    quote do
      require Samen.Fleet.Assignment.Blueprint

      resources do
        resource(unquote(assignment_mod))
      end

      Samen.Fleet.Assignment.Blueprint.define_assignment(
        unquote(assignment_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrev)
      )
    end
  end
end

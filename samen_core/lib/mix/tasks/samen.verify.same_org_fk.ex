defmodule Mix.Tasks.Samen.Verify.SameOrgFk do
  @shortdoc "Verify every tenant-plane org-scoped belongs_to FK carries a SameOrgFk guard."

  @moduledoc """
  `mix samen.verify.same_org_fk` — the **same-org-FK** fail-closed verifier (Phase-4
  gate carry F3.5; Gate-3 report §F3.5).

  Turns the scope-authoring guide's §10 rule ("`Samen.Policy.SameOrgFk` belongs on
  **every** resource with a `belongs_to` FK") from a prose checklist item into a
  **gated invariant**. The guide-vs-code drift that Gate-3 found (≈26 unwired FKs
  across CMS/CRM/Marketing/Support/Billing/Identity) is silent without this check —
  nothing in CI enforced it, so a scope author could omit the guard and no test
  would catch it.

  ## What it flags

  For every resource in every configured Ash domain, it fails when the resource is
  **tenant-plane org-scoped** (see below) and declares a `belongs_to` relationship —
  whose destination is *also* org-scoped (has an `org_id` attribute) — that is NOT
  covered by a `Samen.Policy.SameOrgFk` change.

  A `belongs_to` is "covered" when the resource has a `change {Samen.Policy.SameOrgFk,
  relationships: [...]}` whose relationship list includes the FK's name — or a bare
  `change Samen.Policy.SameOrgFk` (no `:relationships` opt), which validates EVERY
  `belongs_to` on the resource (the change's own safe default).

  ## Why the "destination is org-scoped" gate

  `Samen.Policy.SameOrgFk` is a no-op when the FK targets a row that has no `org_id`
  (an org-less anchor like `Identity.Org` — the change returns `:target_has_no_org_id`
  and passes). Requiring the guard on such an FK would be a false positive: there is
  no same-org invariant to enforce against an org-less target. So the verifier only
  requires the guard on FKs whose destination carries an `org_id` — exactly the FKs
  where a cross-tenant reference is meaningful.

  ## What "tenant-plane org-scoped" means

  A resource that (a) has an `org_id` attribute AND (b) references
  `Samen.Policy.OrgScope` in at least one of its policies. This is precisely the
  set the scope-authoring guide's template governs. Operator-plane resources (the
  aggregate actor's `NoPiiColumns` domain, org-less anchors like `Identity.Org`
  which use `OrgIsSelf`, and non-Ash resources) are excluded — they do not use
  `OrgScope` and are not subject to the same-org-FK idiom.

  ## Usage

      mix samen.verify.same_org_fk
      mix samen.verify.same_org_fk --domain MyApp.Crm

  ## Exit code

  Exits 0 on success, 1 on any violation (fail-closed via `Samen.Verifier`). This
  is a demo/ci.sh gate step.
  """
  use Mix.Task

  @task_name "samen.verify.same_org_fk"
  @same_org_fk Samen.Policy.SameOrgFk

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _} = OptionParser.parse(args, strict: [domain: :keep])

    Samen.Verifier.halt_if_violations(@task_name, violations(opts))
  end

  @doc """
  Compute the list of unguarded-FK violation strings. Separated from `run/1` so
  tests can assert on it without halting the VM.
  """
  def violations(opts \\ []) do
    domains(opts)
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.filter(&org_scoped_tenant_resource?/1)
    |> Enum.flat_map(&resource_violations/1)
  end

  # -------------------------------------------------------------------------

  defp resource_violations(resource) do
    covered = same_org_fk_coverage(resource)

    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&(&1.type == :belongs_to))
    |> Enum.filter(&org_scoped_destination?/1)
    |> Enum.reject(fn rel -> covered == :all or rel.name in covered end)
    |> Enum.map(fn rel ->
      "#{inspect(resource)} declares belongs_to #{inspect(rel.name)} → " <>
        "#{inspect(rel.destination)} (an org-scoped target) with no matching " <>
        "`change {Samen.Policy.SameOrgFk, relationships: [#{inspect(rel.name)}, ...]}` — " <>
        "the scope-authoring guide §10 mandates a SameOrgFk guard on every org-scoped " <>
        "belongs_to FK (F3.5). A cross-org FK write would otherwise store a dangling " <>
        "cross-tenant reference."
    end)
  end

  # Returns `:all` if a bare (opt-less) SameOrgFk change is present (covers every
  # belongs_to), otherwise the set of relationship names covered by any
  # `{SameOrgFk, relationships: [...]}` change on the resource.
  defp same_org_fk_coverage(resource) do
    changes =
      resource
      |> Ash.Resource.Info.changes()
      |> Enum.map(& &1.change)
      |> Enum.filter(fn
        {@same_org_fk, _opts} -> true
        @same_org_fk -> true
        _ -> false
      end)

    cond do
      changes == [] ->
        []

      Enum.any?(changes, &bare_same_org_fk?/1) ->
        :all

      true ->
        changes
        |> Enum.flat_map(fn {@same_org_fk, opts} -> Keyword.get(opts, :relationships, []) end)
        |> MapSet.new()
        |> MapSet.to_list()
    end
  end

  # A SameOrgFk change with no `:relationships` opt (or an empty/nil one) validates
  # EVERY belongs_to — the change's documented safe default.
  defp bare_same_org_fk?(@same_org_fk), do: true

  defp bare_same_org_fk?({@same_org_fk, opts}) do
    case Keyword.get(opts, :relationships) do
      nil -> true
      [] -> true
      list when is_list(list) -> false
    end
  end

  defp bare_same_org_fk?(_), do: false

  # A resource is a tenant-plane, org-scoped resource when it has an `org_id`
  # attribute AND at least one policy references `Samen.Policy.OrgScope`.
  defp org_scoped_tenant_resource?(resource) do
    has_org_id?(resource) and uses_org_scope?(resource)
  end

  defp org_scoped_destination?(rel) do
    is_atom(rel.destination) and Ash.Resource.Info.resource?(rel.destination) and
      has_org_id?(rel.destination)
  end

  defp has_org_id?(resource) do
    Ash.Resource.Info.attribute(resource, :org_id) != nil
  end

  # Scan the resource's policies for a reference to `Samen.Policy.OrgScope`. We
  # inspect the policy structs (rather than reaching into their internal shape,
  # which varies across Ash versions) and match the module name — the same robust
  # approach the scope-review used.
  defp uses_org_scope?(resource) do
    resource
    |> Ash.Policy.Info.policies()
    |> Enum.any?(fn policy -> inspect(policy) =~ "OrgScope" end)
  rescue
    # A resource without the policy authorizer / policies section.
    _ -> false
  end

  defp domains(opts) do
    case Keyword.get_values(opts, :domain) do
      [] ->
        otp_app = Mix.Project.config()[:app]
        Application.get_env(otp_app, :ash_domains, [])

      names ->
        Enum.map(names, &Module.concat([&1]))
    end
  end
end

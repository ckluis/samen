defmodule Mix.Tasks.Samen.Verify.AiPromptMasking do
  @shortdoc "INV-7 structural gate: no vault-routed field is embeddable; no Prompt body carries a vt_ token."

  @moduledoc """
  `mix samen.verify.ai_prompt_masking` — the D2 verifier tier (ADR-043 §3.4, T65). The
  **structural** half of the `ai_prompt_masking` gate that proves INV-7 (no-PII-egress); the
  **runtime** half is the permanent canary red-team ExUnit suite
  (`samen_core/test/ai/ai_prompt_masking_test.exs`, RP-AI-9/10), which runs under the
  `samen_core` `mix test` gate and asserts a seeded PII canary NEVER appears at any egress
  class EG1–EG6 (prompt, tool args, embedding, MCP, grounding, and the EG6 log/telemetry/error
  shadow), sabotage-refutable.

  This task mirrors the house verifier shape (`run/1` → `Samen.Verifier.halt_if_violations/2`;
  `violations/1` callable without halting) and is wired into the demo/vertical `ci.sh` step
  lists + the `ci_sh.eex` generator template + the root gate.

  ## What it checks (the persisted-egress structural invariants — §3.4)

    * **(b) no vault-routed field is embeddable** (§7.2): a resource that declares an
      embeddable field (the T67 `embeddable_fields/0` seam) whose column is vault-routed
      (`Samen.Pii.Info.vault_routed_columns/1`) or catalog-flagged `pii: true` is a violation
      — a vector persists beyond any grant window and is invertible, so vault-routed values
      must never enter vector space (grants never unlock embedding). The chokepoint ALSO
      refuses such an input fail-closed at runtime; this is the compile-time backstop.
    * **(c) no Prompt-resource template body carries a `vt_` sentinel** (§7.5): a managed
      Prompt template (the T68 `samen_ai_prompt_template_bodies/1` seam) whose body contains a
      `vt_` vault-token sentinel is a violation — a committed template must never embed a raw
      vault FK token (EG5, authored-under-the-same-scrub).

  T67 (embeddings plane) lands the `embeddable_fields/0` declaration and T68 lands the Prompt
  resource, at which point (b)/(c) become non-vacuous on real resources; the seams are read
  defensively here so the gate is green-and-real today and binds automatically as those tasks
  ship. The load-bearing INV-7 proof for T65 is the runtime red-team.
  """

  use Mix.Task

  @task_name "samen.verify.ai_prompt_masking"

  # A vault FK token sentinel (`Samen.Vault.generate_token/0` mints `"vt_" <> 32 hex`). A
  # Prompt body must never contain one; refuse on the prefix (most fail-closed).
  @vt_sentinel "vt_"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _rest, _} = OptionParser.parse(args, strict: [domain: :keep])
    Samen.Verifier.halt_if_violations(@task_name, violations(opts))
  end

  @doc """
  Compute the INV-7 structural violations (list of human-readable strings), without halting —
  the test-callable seam.
  """
  @spec violations(keyword()) :: [String.t()]
  def violations(opts \\ []) do
    resources = opts |> domains() |> Enum.flat_map(&Ash.Domain.Info.resources/1) |> Enum.uniq()

    embeddable_vault_violations(resources) ++ prompt_body_vt_violations(resources)
  end

  # --- (b) no vault-routed field is embeddable -------------------------------------------

  @doc "The (b) cross-check over a resource list (public for the unit test)."
  @spec embeddable_vault_violations([module()]) :: [String.t()]
  def embeddable_vault_violations(resources) do
    for resource <- resources,
        field <- embeddable_fields(resource),
        vault_routed?(resource, field) do
      "#{inspect(resource)}: embeddable field #{inspect(field)} is vault-routed (🔒) — " <>
        "a vault-routed value must never enter vector space (grants never unlock embedding; " <>
        "ADR-043 §7.2). Drop the field from the embeddable set or de-vault it."
    end
  end

  # The T67 embeddable-field seam: a resource opts in by exporting `embeddable_fields/0`.
  # Absent (today) ⇒ no embeddable fields ⇒ nothing to cross-check (green-and-real).
  defp embeddable_fields(resource) do
    if exports?(resource, :embeddable_fields, 0) do
      List.wrap(resource.embeddable_fields())
    else
      []
    end
  end

  defp vault_routed?(resource, field) do
    routed = safe(fn -> Samen.Pii.Info.vault_routed_columns(resource) end, [])
    pii = safe(fn -> Enum.map(Samen.Pii.Info.pii_attributes(resource), & &1.name) end, [])
    field in routed or field in pii
  end

  # --- (c) no Prompt template body carries a vt_ token -----------------------------------

  @doc "The (c) scan over a resource list (public for the unit test)."
  @spec prompt_body_vt_violations([module()]) :: [String.t()]
  def prompt_body_vt_violations(resources) do
    for resource <- resources,
        {name, body} <- prompt_template_bodies(resource),
        is_binary(body),
        String.contains?(body, @vt_sentinel) do
      "#{inspect(resource)}: Prompt template #{inspect(name)} body contains a `vt_` vault-token " <>
        "sentinel — a committed template must never embed a raw vault FK token (ADR-043 §7.5)."
    end
  end

  # The T68 Prompt-resource seam: a Prompt resource exports
  # `samen_ai_prompt_template_bodies/0 :: [{name, body_string}]`. Absent (today) ⇒ [].
  defp prompt_template_bodies(resource) do
    if exports?(resource, :samen_ai_prompt_template_bodies, 0) do
      List.wrap(resource.samen_ai_prompt_template_bodies())
    else
      []
    end
  end

  # --- helpers ---------------------------------------------------------------------------

  # `function_exported?/3` returns false for a not-yet-loaded module; ensure it is loaded first
  # so the seam detection is race-free (async tests / cold verifier runs).
  defp exports?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
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

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  end
end

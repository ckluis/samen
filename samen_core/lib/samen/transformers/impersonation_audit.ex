defmodule Samen.Transformers.ImpersonationAudit do
  @moduledoc """
  Adds the P7-F1 impersonation-write audit change (`Samen.Audit.ImpersonationWrite`) to
  EVERY Samen resource as a resource-level global change (ADR-040 §6.6).

  Mirrors `Samen.Transformers.MaterializePii`'s injection of `Samen.Vault.Change` /
  `Samen.Pii.WriteGuard` — `Ash.Resource.Builder.build_change/1` +
  `Transformer.add_entity(dsl_state, [:changes], change)`. A resource-level change
  applies to every create/update/destroy action, so every write path (single AND bulk)
  runs the change. The change is a no-op for non-impersonated writes (it fires only when
  the acting actor carries the `:impersonation` marker), so this is the chokepoint that
  makes the impersonation-write audit attach REGARDLESS of the target resource's
  `versioned`/E7 opt-in — the impersonation context is the enforcement point.

  Unconditional (unlike MaterializePii, which gates on PII attributes): the audit
  obligation attaches to every resource because an operator can be impersonating over any
  tenant resource.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    # `on: [:create, :update, :destroy]` is load-bearing: Ash global changes default to
    # create+update ONLY, so without `:destroy` the audit hook never fires for destroy
    # actions — the actual reason bulk_destroy (and atomic single :destroy/
    # :destroy_permanently) escaped the audit. Registered for :destroy, `atomic/3` fires
    # per destroyed record with the operator marker on `context.actor`, so destroys are
    # audited IN-TRANSACTION and fail-closed exactly like create/update.
    {:ok, change} =
      Ash.Resource.Builder.build_change(Samen.Audit.ImpersonationWrite,
        on: [:create, :update, :destroy]
      )

    {:ok, Transformer.add_entity(dsl_state, [:changes], change)}
  end
end

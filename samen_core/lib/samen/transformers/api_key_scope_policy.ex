defmodule Samen.Transformers.ApiKeyScopePolicy do
  @moduledoc """
  Enforces an API key's declared scopes on every resource exposed over JSON:API, by construction.

  For a resource that carries the `AshJsonApi.Resource` extension this prepends, ahead of every policy the
  resource declares:

      policy always() do
        forbid_unless Samen.Policy.ApiKeyScope
        authorize_if always()
      end

  Ash requires every applicable policy to authorize, so the key's scopes and the resource's own policies (its
  role and org rules) are both conjuncts: a key can do what BOTH allow. It is the first policy, so a `bypass`
  the resource declares after it cannot skip it. A resource not exposed over JSON:API is untouched.

  The resource must use `Ash.Policy.Authorizer`: an exposed resource without one would serve a key's request
  with no policy at all, so compilation raises instead.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @json_api Module.concat(["AshJsonApi", "Resource"])

  # Runs after `Samen.Transformers.RevealActions`, whose probe rule inspects the policies a resource DECLARES for
  # a reveal action. The policy added here only ever narrows (it authorizes everything but a key request the
  # key's scopes do not cover, and every other policy must still authorize), so it is not one of those.
  @impl true
  def after?(Samen.Transformers.RevealActions), do: true
  def after?(_), do: false

  @impl true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    extensions = Transformer.get_persisted(dsl_state, :spark_extensions, [])

    if @json_api in extensions do
      unless Ash.Policy.Authorizer in extensions do
        raise Spark.Error.DslError,
          module: Transformer.get_persisted(dsl_state, :module),
          path: [:policies],
          message:
            "a resource exposed over JSON:API must use `authorizers: [Ash.Policy.Authorizer]`: " <>
              "an API key's scopes are enforced by a policy, and a resource with no policies would serve its requests unchecked"
      end

      always = Ash.Policy.Check.Builtins.always()

      {:ok, check} =
        Transformer.build_entity(Ash.Policy.Authorizer, [:policies, :policy], :forbid_unless,
          check: {Samen.Policy.ApiKeyScope, []}
        )

      {:ok, allow} =
        Transformer.build_entity(Ash.Policy.Authorizer, [:policies, :policy], :authorize_if, check: always)

      {:ok, policy} =
        Transformer.build_entity(Ash.Policy.Authorizer, [:policies], :policy,
          condition: always,
          description: "an API key's declared scopes permit this action",
          policies: [check, allow]
        )

      {:ok, Transformer.add_entity(dsl_state, [:policies], policy)}
    else
      {:ok, dsl_state}
    end
  end
end

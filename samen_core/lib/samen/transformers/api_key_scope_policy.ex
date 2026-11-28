defmodule Samen.Transformers.ApiKeyScopePolicy do
  @moduledoc """
  Enforces an API key's declared scopes on every resource exposed over JSON:API, by construction.

  For a resource that carries the `AshJsonApi.Resource` extension this prepends, ahead of every policy the
  resource declares:

      policy Samen.Policy.ApiKeyScopeRefused do
        forbid_if always()
      end

  The condition is true only for a key request whose scopes do not permit the action, so for that request the
  policy forbids, and for every other request (a person, a system actor, `nil`, a key whose scopes cover the
  action) it does not apply. It never authorizes: whether an action is allowed is decided by the policies the
  resource declares alone, an action none of them covers stays forbidden, and a key can do what BOTH its scopes and
  those policies allow. It is the first policy, so a `bypass` the resource declares after it cannot skip it. A
  resource not exposed over JSON:API is untouched.

  The resource must use `Ash.Policy.Authorizer`: an exposed resource without one would serve a key's request
  with no policy at all, so compilation raises instead.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @json_api Module.concat(["AshJsonApi", "Resource"])

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

      check_family!(dsl_state)

      always = Ash.Policy.Check.Builtins.always()

      {:ok, forbid} =
        Transformer.build_entity(Ash.Policy.Authorizer, [:policies, :policy], :forbid_if, check: always)

      {:ok, policy} =
        Transformer.build_entity(Ash.Policy.Authorizer, [:policies], :policy,
          condition: {Samen.Policy.ApiKeyScopeRefused, []},
          description: "an API key's declared scopes do not permit this action",
          policies: [forbid]
        )

      {:ok, Transformer.add_entity(dsl_state, [:policies], policy)}
    else
      {:ok, dsl_state}
    end
  end

  # A scope `family.type` is read by splitting on the dot, so a family that contains one would be taken for a
  # family and a type: a domain's `samen_api_family/0` may not return one.
  defp check_family!(dsl_state) do
    domain = Transformer.get_persisted(dsl_state, :domain)

    if is_atom(domain) and not is_nil(domain) and Code.ensure_compiled(domain) == {:module, domain} and
         function_exported?(domain, :samen_api_family, 0) do
      family = to_string(domain.samen_api_family())

      if String.contains?(family, ".") do
        raise Spark.Error.DslError,
          module: Transformer.get_persisted(dsl_state, :module),
          path: [:json_api],
          message:
            "the API scope family #{inspect(family)} of #{inspect(domain)} (its `samen_api_family/0`) contains a dot: " <>
              "a scope `family.type` is split on the dot, so a family may not contain one"
      end
    end
  end
end

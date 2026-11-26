defmodule Samen.RevealProbeAuthzTest do
  @moduledoc """
  authz-6 review 2, item F: every generic `reveal_*` probe action ("does THAT id hold a live reveal grant on this
  subject?") took an `actor_id` ARGUMENT and was `authorize_if(always())`, so any code path, with any actor or none,
  could ask about anyone's grants. They are now ONE implementation (`Samen.Reveal.GrantProbe`): the grant is checked
  for the actor that RUNS the action, there is no identity argument, a missing actor is denied, and the policy is
  `authorize_if(actor_present())`. `Samen.Reveal.ProbeGuard` (a compile-time rule in `Samen.Transformers.RevealActions`)
  refuses a reveal action that regresses either way, on every host and generated app.

  Representatives here: the CRM scope (core blueprint), the automation fixture (a hand-written resource), and the
  three generator templates (text pin; the generated apps themselves compile in `gen_*_probe`). The chat scope
  (`samen_web`) and the three hosts carry their own copy of the same test.
  """
  use ExUnit.Case, async: false

  alias Samen.Reveal.ProbeGuard
  alias SamenCore.Support.AutomationFixture.Subject
  alias SamenCore.Support.CrmScopeFixture.Person

  defmodule OperatorOneGrant do
    @moduledoc false
    # The grant model, reduced to its question: is THIS actor `operator-1`?
    @behaviour Samen.Reveal.Grant

    @impl true
    def granted?(%Samen.Reveal.Context{actor: %{id: id}}), do: id == "operator-1"
    def granted?(%Samen.Reveal.Context{actor: id}) when is_binary(id), do: id == "operator-1"
    def granted?(_), do: false
  end

  defmodule ApproveAll do
    @moduledoc false
    # The most permissive checker: even a missing actor is "granted" by it, so only the probe/policy can refuse.
    @behaviour Samen.Reveal.Grant

    @impl true
    def granted?(_ctx), do: true
  end

  setup do
    Samen.TestSandbox.shared!(SamenCore.TestRepo)
    prev = Application.get_env(:samen_core, :reveal_grant)
    Application.put_env(:samen_core, :reveal_grant, OperatorOneGrant)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_core, :reveal_grant, prev),
        else: Application.delete_env(:samen_core, :reveal_grant)
    end)

    :ok
  end

  defp scope(role, id) do
    org = Ash.UUID.generate()
    %Samen.Scope{actor: %{id: id, org_id: org, role: role, kind: :tenant, plane: :tenant}}
  end

  defp run_probe(resource, action, args, opts) do
    resource |> Ash.ActionInput.for_action(action, args, opts) |> Ash.run_action()
  end

  @roles [:viewer, :member, :admin, :owner]

  for {resource, action} <- [{Person, :reveal_person}, {Subject, :reveal_subject}] do
    describe "#{inspect(resource)}.#{action}" do
      test "naming another id rides nothing; the holder asking as itself is granted" do
        resource = unquote(resource)
        action = unquote(action)
        subject = Ash.UUID.generate()

        for role <- @roles do
          result = run_probe(resource, action, %{actor_id: "operator-1", subject_id: subject}, scope: scope(role, "u-#{role}"))
          refute match?({:ok, %{status: "granted"}}, result), "#{role} rode operator-1's grant: #{inspect(result)}"
        end

        # no argument names anybody: an actor without a grant of its own gets nothing
        assert {:error, _} = run_probe(resource, action, %{subject_id: subject}, scope: scope(:owner, "u-owner"))

        # positive control: the holder, asking as itself
        assert {:ok, %{status: "granted", subject_id: ^subject}} =
                 run_probe(resource, action, %{subject_id: subject}, scope: scope(:member, "operator-1"))
      end

      test "no actor at all gets no answer, even from a checker that approves everything" do
        resource = unquote(resource)
        action = unquote(action)
        subject = Ash.UUID.generate()
        Application.put_env(:samen_core, :reveal_grant, ApproveAll)

        # the policy refuses the actor-less call; with authorization OFF the probe's own guard still does
        for args <- [%{actor_id: "operator-1", subject_id: subject}, %{subject_id: subject}],
            opts <- [[], [authorize?: false]] do
          result = run_probe(resource, action, args, opts)
          refute match?({:ok, _}, result), "an actor-less call was answered (#{inspect(opts)}): #{inspect(result)}"
        end

        # positive control: the same checker answers once there IS an actor
        assert {:ok, %{status: "granted"}} =
                 run_probe(resource, action, %{subject_id: subject}, scope: scope(:viewer, "anyone"))
      end

      test "the action takes no identity argument and its policy is not always()" do
        resource = unquote(resource)
        action = unquote(action)
        arg_names = resource |> Ash.Resource.Info.action(action) |> Map.fetch!(:arguments) |> Enum.map(& &1.name)
        assert arg_names == [:subject_id]
        assert action in Samen.Pii.Info.reveal_probes_examined(resource)
      end
    end
  end

  describe "the generator templates emit the same probe" do
    @templates [
      "priv/templates/vertical_ex.eex",
      "priv/templates/vertical_ex_api.eex"
    ]

    defp template_sources do
      files = for rel <- @templates, do: {rel, File.read!(Application.app_dir(:samen_core, rel))}
      files ++ [{"Samen.Gen.PostTemplates.resource_module/0", Samen.Gen.PostTemplates.resource_module()}]
    end

    test "no template takes an actor_id, answers always(), or carries its own copy of the probe" do
      sources = template_sources()
      assert length(sources) == 3

      for {name, src} <- sources do
        assert src =~ "run({Samen.Reveal.GrantProbe, label: :secret})", "#{name} lost the shared probe"
        refute src =~ "actor_id", "#{name} takes an actor_id"
        refute src =~ "grant_checker()", "#{name} carries its own probe"
        assert src =~ ~r/policy action\(:reveal_<%= abbrev %>\) do\s+authorize_if\(actor_present\(\)\)/, "#{name}: reveal policy is not actor_present()"
      end
    end
  end

  describe "ProbeGuard (the compile-time rule)" do
    defp fake_policy(condition, type, check), do: %{condition: condition, policies: [%{type: type, check: check}]}
    @always {Ash.Policy.Check.Static, [result: true]}

    test "an identity argument is flagged; subject_id is not" do
      for name <- [:actor_id, :actor, :user_id, :requestor_id, :operator_id, :principal_id] do
        assert ProbeGuard.identity_argument?(name), "#{name} not flagged"
      end

      for name <- [:subject_id, :org_id, :label, :reason], do: refute(ProbeGuard.identity_argument?(name))
    end

    test "violations: identity argument, always() by name, always() by action_type; clean passes (positive control)" do
      clean = %{name: :reveal_x, arguments: [%{name: :subject_id}]}
      ok_policy = fake_policy([{Ash.Policy.Check.Action, [action: [:reveal_x]]}], :authorize_if, {Ash.Policy.Check.Builtins, []})
      assert [] = ProbeGuard.violations([:reveal_x], [clean], [ok_policy])

      assert [{:reveal_x, "takes the identity argument :actor_id" <> _}] =
               ProbeGuard.violations([:reveal_x], [%{name: :reveal_x, arguments: [%{name: :actor_id}]}], [ok_policy])

      open = fake_policy([{Ash.Policy.Check.Action, [action: [:reveal_x]]}], :authorize_if, @always)
      assert [{:reveal_x, "is `authorize_if(always())`" <> _}] = ProbeGuard.violations([:reveal_x], [clean], [open])

      open_type = fake_policy([{Ash.Policy.Check.ActionType, [type: [:action]]}], :authorize_if, @always)
      assert [{:reveal_x, _}] = ProbeGuard.violations([:reveal_x], [clean], [open_type])

      # a policy for ANOTHER action, or a forbid, is not a violation
      other = fake_policy([{Ash.Policy.Check.Action, [action: [:other]]}], :authorize_if, @always)
      assert [] = ProbeGuard.violations([:reveal_x], [clean], [other])
    end
  end

  describe "the transformer refuses a regressed reveal action" do
    alias Spark.Dsl.Transformer

    # The compiled `RevealPerson` fixture's own DSL state (a registered abbrev, so no throwaway module needs one),
    # edited the way a regressed declaration would read, then run through the SAME transformer the build runs.
    @resource SamenCore.Support.RevealDomain.RevealPerson

    defp dsl, do: @resource.spark_dsl_config()

    defp with_argument(dsl, name) do
      action = dsl |> Transformer.get_entities([:actions]) |> Enum.find(&(&1.name == :reveal_email))
      arg = %Ash.Resource.Actions.Argument{name: name, type: Ash.Type.String, allow_nil?: false}
      Transformer.replace_entity(dsl, [:actions], %{action | arguments: [arg | action.arguments]}, &(&1.name == :reveal_email))
    end

    defp with_policy(dsl, type, check) do
      policy = %Ash.Policy.Policy{
        condition: [{Ash.Policy.Check.Action, [action: [:reveal_email]]}],
        policies: [%Ash.Policy.Check{type: type, check: check}]
      }

      Transformer.add_entity(dsl, [:policies], policy)
    end

    test "positive control: the clean declaration passes and records that it examined it" do
      assert {:ok, out} = Samen.Transformers.RevealActions.transform(dsl())
      assert [:reveal_email] = Transformer.get_persisted(out, Samen.Transformers.RevealActions.examined_key())
    end

    test "an identity argument fails the build" do
      for name <- [:actor_id, :user_id] do
        assert {:error, %Spark.Error.DslError{message: msg}} =
                 dsl() |> with_argument(name) |> Samen.Transformers.RevealActions.transform()

        assert msg =~ "identity argument #{inspect(name)}"
      end
    end

    test "authorize_if(always()) fails the build; a policy that is not always() passes" do
      always = {Ash.Policy.Check.Static, [result: true]}

      assert {:error, %Spark.Error.DslError{message: msg}} =
               dsl() |> with_policy(:authorize_if, always) |> Samen.Transformers.RevealActions.transform()

      assert msg =~ "authorize_if(always())"

      assert {:ok, _} =
               dsl()
               |> with_policy(:authorize_if, {Ash.Policy.Check.Builtins, []})
               |> Samen.Transformers.RevealActions.transform()
    end
  end
end

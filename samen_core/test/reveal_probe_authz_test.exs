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
    @probe {Samen.Reveal.GrantProbe, [label: :x]}
    @present Ash.Policy.Check.ActorPresent
    defp fake_policy(condition, type, check, extra \\ []),
      do: struct(Ash.Policy.Policy, [condition: condition, policies: [%{type: type, check: check}]] ++ extra)

    defp gate(name \\ :reveal_x),
      do: fake_policy([{Ash.Policy.Check.Action, [action: [name]]}], :authorize_if, @present)

    defp clean_action(extra \\ []),
      do: Map.merge(%{name: :reveal_x, type: :action, run: @probe, arguments: [%{name: :subject_id}]}, Map.new(extra))

    @always {Ash.Policy.Check.Static, [result: true]}

    test "an identity argument is flagged; subject_id is not" do
      for name <- [:actor_id, :actor, :user_id, :requestor_id, :operator_id, :principal_id] do
        assert ProbeGuard.identity_argument?(name), "#{name} not flagged"
      end

      for name <- [:subject_id, :org_id, :label, :reason], do: refute(ProbeGuard.identity_argument?(name))
    end

    test "violations: identity argument, always() by name, always() by action_type; clean passes (positive control)" do
      clean = clean_action()
      assert [] = ProbeGuard.violations([:reveal_x], [clean], [gate()])

      assert [{:reveal_x, "takes the identity argument :actor_id" <> _}] =
               ProbeGuard.violations([:reveal_x], [clean_action(arguments: [%{name: :actor_id}])], [gate()])

      open = fake_policy([{Ash.Policy.Check.Action, [action: [:reveal_x]]}], :authorize_if, @always)
      assert [{:reveal_x, "authorize_if(" <> _} | _] = ProbeGuard.violations([:reveal_x], [clean], [gate(), open])

      open_type = fake_policy([{Ash.Policy.Check.ActionType, [type: [:action]]}], :authorize_if, @always)
      assert [{:reveal_x, _} | _] = ProbeGuard.violations([:reveal_x], [clean], [gate(), open_type])

      # a policy for ANOTHER action is not a violation; neither is a forbid
      other = fake_policy([{Ash.Policy.Check.Action, [action: [:other]]}], :authorize_if, @always)
      forbid = fake_policy([{Ash.Policy.Check.Action, [action: [:reveal_x]]}], :forbid_if, @always)
      assert [] = ProbeGuard.violations([:reveal_x], [clean], [gate(), other, forbid])
    end

    test "the shape is positive: a reveal action with no actor_present gate, another run, or other arguments fails" do
      assert [{:reveal_x, "has no `policy action(:reveal_x)`" <> _}] = ProbeGuard.violations([:reveal_x], [clean_action()], [])

      assert [{:reveal_x, "does not `run(" <> _}] =
               ProbeGuard.violations([:reveal_x], [clean_action(run: {Some.Other, []})], [gate()])

      assert [{:reveal_x, "takes the arguments [:subject_id, :as]" <> _}] =
               ProbeGuard.violations([:reveal_x], [clean_action(arguments: [%{name: :subject_id}, %{name: :as}])], [gate()])
    end

    test "a bypass or policy_group that can reach the action is refused; the AshOban bypass is allow-listed" do
      clean = clean_action()
      oban = Ash.Policy.Check.Static && {AshOban.Checks.AshObanInteraction, []}

      assert [] = ProbeGuard.violations([:reveal_x], [clean], [gate(), fake_policy([oban], :authorize_if, oban, bypass?: true)])

      assert [{:reveal_x, "can be authorized by a `bypass`" <> _}] =
               ProbeGuard.violations([:reveal_x], [clean], [gate(), fake_policy([@always], :authorize_if, @always, bypass?: true)])

      # a bypass for another action cannot reach it
      assert [] =
               ProbeGuard.violations([:reveal_x], [clean], [
                 gate(),
                 fake_policy([{Ash.Policy.Check.Action, [action: [:other]]}], :authorize_if, @always, bypass?: true)
               ])

      group = %Ash.Policy.PolicyGroup{
        condition: [{Ash.Policy.Check.Action, [action: [:reveal_x]]}],
        policies: [fake_policy([], :authorize_if, @always)]
      }

      assert [{:reveal_x, "authorize_if(" <> _}] = ProbeGuard.violations([:reveal_x], [clean], [gate(), group])
    end
  end

  describe "the transformer refuses a regressed reveal action" do
    alias Spark.Dsl.Transformer

    # The compiled `RevealPerson` fixture's own DSL state (a registered abbrev, so no throwaway module needs one),
    # edited the way a regressed declaration would read, then run through the SAME transformer the build runs.
    @resource SamenCore.Support.RevealDomain.RevealPerson

    defp dsl, do: @resource.spark_dsl_config()

    defp edit_action(dsl, fun) do
      action = dsl |> Transformer.get_entities([:actions]) |> Enum.find(&(&1.name == :reveal_email))
      Transformer.replace_entity(dsl, [:actions], fun.(action), &(&1.name == :reveal_email))
    end

    defp with_argument(dsl, name) do
      arg = %Ash.Resource.Actions.Argument{name: name, type: Ash.Type.String, allow_nil?: false}
      edit_action(dsl, &%{&1 | arguments: [arg | &1.arguments]})
    end

    defp with_run(dsl, run), do: edit_action(dsl, &%{&1 | run: run})

    defp with_policy(dsl, type, check, extra \\ []) do
      policy =
        struct(
          Ash.Policy.Policy,
          [
            condition: [{Ash.Policy.Check.Action, [action: [:reveal_email]]}],
            policies: [%Ash.Policy.Check{type: type, check: check}]
          ] ++ extra
        )

      Transformer.add_entity(dsl, [:policies], policy)
    end

    defp refused(dsl) do
      assert {:error, %Spark.Error.DslError{message: msg}} = Samen.Transformers.RevealActions.transform(dsl)
      msg
    end

    test "positive control: the clean declaration passes and records that it examined it" do
      assert {:ok, out} = Samen.Transformers.RevealActions.transform(dsl())
      assert [:reveal_email] = Transformer.get_persisted(out, Samen.Transformers.RevealActions.examined_key())
    end

    test "an identity argument fails the build" do
      for name <- [:actor_id, :user_id] do
        assert dsl() |> with_argument(name) |> refused() =~ "identity argument #{inspect(name)}"
      end
    end

    test "authorize_if(always()) fails the build; a second actor_present policy for the action passes" do
      assert dsl() |> with_policy(:authorize_if, {Ash.Policy.Check.Static, [result: true]}) |> refused() =~
               "authorize_if(always())"

      assert {:ok, _} =
               dsl()
               |> with_policy(:authorize_if, Ash.Policy.Check.ActorPresent)
               |> Samen.Transformers.RevealActions.transform()
    end

    test "evasion: an own `run` reading a non-listed argument (`:as`) fails the build" do
      msg = dsl() |> with_run({SomeOwn.Probe, []}) |> with_argument(:as) |> refused()
      assert msg =~ "does not `run("
      assert msg =~ "[:as, :subject_id]"
    end

    test "evasion: an own `run` that uses subject_id as the actor fails the build" do
      assert dsl() |> with_run({SomeOwn.Probe, []}) |> refused() =~ "does not `run("
    end

    test "evasion: `bypass always()` fails the build" do
      always = {Ash.Policy.Check.Static, [result: true]}

      msg =
        dsl()
        |> Transformer.add_entity(
          [:policies],
          struct(Ash.Policy.Policy, bypass?: true, condition: [always], policies: [%Ash.Policy.Check{type: :authorize_if, check: always}])
        )
        |> refused()

      assert msg =~ "`bypass`"

      # positive control: AshOban's own bypass is the one allow-listed shape
      oban = {AshOban.Checks.AshObanInteraction, []}

      assert {:ok, _} =
               dsl()
               |> Transformer.add_entity(
                 [:policies],
                 struct(Ash.Policy.Policy, bypass?: true, condition: [oban], policies: [%Ash.Policy.Check{type: :authorize_if, check: oban}])
               )
               |> Samen.Transformers.RevealActions.transform()
    end

    test "evasion: a policy_group that authorizes always() fails the build" do
      always = {Ash.Policy.Check.Static, [result: true]}

      group = %Ash.Policy.PolicyGroup{
        condition: [{Ash.Policy.Check.Action, [action: [:reveal_email]]}],
        policies: [struct(Ash.Policy.Policy, condition: [], policies: [%Ash.Policy.Check{type: :authorize_if, check: always}])]
      }

      assert dsl() |> Transformer.add_entity([:policies], group) |> refused() =~ "authorize_if("
    end

    test "evasion: expr(true) fails the build" do
      assert dsl() |> with_policy(:authorize_if, {Ash.Policy.Check.Expression, [expr: true]}) |> refused() =~ "authorize_if("
    end

    test "evasion: a policy that is not about the action (a broad always() on its action type) fails the build" do
      broad = {Ash.Policy.Check.Static, [result: true]}

      assert dsl()
             |> Transformer.add_entity(
               [:policies],
               struct(Ash.Policy.Policy,
                 condition: [{Ash.Policy.Check.ActionType, [type: [:action]]}],
                 policies: [%Ash.Policy.Check{type: :authorize_if, check: broad}]
               )
             )
             |> refused() =~ "authorize_if("
    end
  end
end

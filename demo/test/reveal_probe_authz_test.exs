defmodule Demo.RevealProbeAuthzTest do
  @moduledoc """
  authz-6 review 2, item F: `Demo.Crm.Contact.reveal_contact` (a generic reveal probe) used to take an `actor_id`
  ARGUMENT under `authorize_if(always())`, so any code path could ask about anyone's grants. It is now
  `Samen.Reveal.GrantProbe`: the grant is checked for the actor that RUNS the action, a missing actor is denied,
  and there is no identity argument (`Samen.Reveal.ProbeGuard` fails the build on a regression).
  """
  use ExUnit.Case, async: false

  @resource Demo.Crm.Contact
  @action :reveal_contact

  defmodule OperatorOneGrant do
    @moduledoc false
    @behaviour Samen.Reveal.Grant

    @impl true
    def granted?(%Samen.Reveal.Context{actor: %{id: id}}), do: id == "operator-1"
    def granted?(_), do: false
  end

  defmodule ApproveAll do
    @moduledoc false
    @behaviour Samen.Reveal.Grant

    @impl true
    def granted?(_ctx), do: true
  end

  setup do
    prev = Application.get_env(:samen_core, :reveal_grant)
    Application.put_env(:samen_core, :reveal_grant, OperatorOneGrant)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_core, :reveal_grant, prev),
        else: Application.delete_env(:samen_core, :reveal_grant)
    end)

    :ok
  end

  defp run(args, opts), do: @resource |> Ash.ActionInput.for_action(@action, args, opts) |> Ash.run_action()

  defp actor(id), do: %{id: id, org_id: Ash.UUID.generate(), role: :admin, kind: :tenant, plane: :tenant}

  test "naming another id rides nothing; the holder asking as itself is granted" do
    subject = Ash.UUID.generate()

    result = run(%{actor_id: "operator-1", subject_id: subject}, actor: actor("someone-else"))
    refute match?({:ok, %{status: "granted"}}, result), "rode operator-1's grant: #{inspect(result)}"
    assert {:error, _} = run(%{subject_id: subject}, actor: actor("someone-else"))

    # positive control
    assert {:ok, %{status: "granted", subject_id: ^subject}} = run(%{subject_id: subject}, actor: actor("operator-1"))
  end

  test "no actor at all gets no answer, even from a checker that approves everything" do
    subject = Ash.UUID.generate()
    Application.put_env(:samen_core, :reveal_grant, ApproveAll)

    # the policy refuses the actor-less call; with authorization OFF the probe's own guard still does
    for args <- [%{actor_id: "operator-1", subject_id: subject}, %{subject_id: subject}],
        opts <- [[], [authorize?: false]] do
      result = run(args, opts)
      refute match?({:ok, _}, result), "an actor-less call was answered (#{inspect(opts)}): #{inspect(result)}"
    end

    # positive control: the same checker answers once there is an actor
    assert {:ok, %{status: "granted"}} = run(%{subject_id: subject}, actor: actor("anyone"))
  end

  test "the action takes only subject_id, and the compile-time rule examined it" do
    assert @resource |> Ash.Resource.Info.action(@action) |> Map.fetch!(:arguments) |> Enum.map(& &1.name) == [:subject_id]
    assert @action in Samen.Pii.Info.reveal_probes_examined(@resource)
  end
end

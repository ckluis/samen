defmodule Samen.Reveal.GrantProbe do
  @moduledoc """
  The ONE implementation behind every generic `reveal_*` probe action: "does the actor that is running this action hold
  a live reveal grant on this subject?" It answers `{:ok, %{status: "granted", subject_id: id}}` or `{:error, :denied}`;
  it never returns plaintext (that is `Samen.Reveal.reveal/3` / `PiiResolution`, which take the actor from server code).

  The grant is checked for the actor in the action context, NEVER for an id the caller names: a caller-supplied
  `actor_id` argument let any code path ask about anyone's grants, or ride another person's. There is no such argument,
  and no actor means no answer (`{:error, :denied}`; the action's policy is `authorize_if(actor_present())` as well).

  Declare it as

      action :reveal_x, :map do
        argument(:subject_id, :string, allow_nil?: false)
        run({Samen.Reveal.GrantProbe, label: :field})
      end

      policy action(:reveal_x) do
        authorize_if(actor_present())
      end

  `Samen.Transformers.RevealActions` refuses, at compile time, a declared reveal action that is not of this shape (see
  `Samen.Reveal.ProbeGuard`).
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, opts, context) do
    actor = context.actor
    subject_id = input.arguments.subject_id

    ctx = %Samen.Reveal.Context{
      actor: actor,
      subject_id: subject_id,
      resource: input.resource,
      action: input.action.name,
      label: Keyword.fetch!(opts, :label)
    }

    if not is_nil(actor) and Samen.Reveal.grant_checker().granted?(ctx) do
      {:ok, %{status: "granted", subject_id: subject_id}}
    else
      {:error, :denied}
    end
  end
end

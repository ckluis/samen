defmodule Mix.Tasks.Samen.Ai.Smoke do
  @shortdoc "AI-plane smoke: keyless deterministic fake, or one REAL completion behind SAMEN_AI_LIVE=1."

  @moduledoc """
  `mix samen.ai.smoke` — the T152 keyless quickstart in one command. Runs a single
  completion through the `Samen.AI` plane and prints an HONEST result banner so a builder
  sees the plane doing one thing end-to-end, and knows exactly whether it was real.

  ## Two lanes (the ADR-043 §4 keyless posture, never a lie)

    * **keyless (default)** — dispatches to the deterministic `Samen.AI.Provider.Fake` and
      prints a banner marked **SIMULATED** (`%Samen.AI.Completion{simulated: true}`). No key,
      no external call, no cost — but clearly NOT a real model answer.
    * **live (`SAMEN_AI_LIVE=1`)** — uses the host-configured provider
      (`config :samen_core, Samen.AI, provider: {..., %{api_key: ...}}`) to transmit a REAL
      request, printing a banner marked **LIVE** (`simulated: false`). With no provider wired
      it stays fail-honest — prints `{:error, :not_configured}` and
      `Samen.AI.configuration_hint/0`. This lane makes the only billable call and is **never**
      run by `./ci.sh`.

  ## Usage

      mix samen.ai.smoke
      mix samen.ai.smoke --prompt "Summarize the samen AI plane in one sentence."
      SAMEN_AI_LIVE=1 mix samen.ai.smoke --prompt "Say hello."

  See `docs/guides/ai-quickstart.md`.
  """

  use Mix.Task

  @default_prompt "Say hello from the Samen AI plane in one short sentence."

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _} = OptionParser.parse(argv, strict: [prompt: :string])
    prompt = Keyword.get(opts, :prompt, @default_prompt)
    live? = System.get_env("SAMEN_AI_LIVE") == "1"

    shell = Mix.shell()
    shell.info("== samen.ai.smoke (#{if live?, do: "LIVE lane", else: "keyless lane"}) ==")
    shell.info("prompt: #{prompt}")

    # Keyless lane: dispatch EXPLICITLY to the deterministic Fake so the demo works in any env
    # (an unwired provider resolves to the Fake only in :test). Live lane: use whatever the host
    # wired — no override — so it is genuinely fail-honest when nothing is configured.
    complete_opts =
      [grounding: %{}] ++
        if live?, do: [], else: [provider: {Samen.AI.Provider.Fake, %{}}]

    case Samen.AI.complete(scope(), prompt, %{}, complete_opts) do
      {:ok, completion} ->
        badge = if completion.simulated, do: "SIMULATED (keyless fake)", else: "LIVE (real model)"
        shell.info("---")
        shell.info("result [#{badge}]  provider=#{inspect(completion.provider)} model=#{inspect(completion.model)}")
        shell.info(completion.text)

      {:error, :not_configured} ->
        shell.info("---")
        shell.error("{:error, :not_configured} — no AI provider is wired.")
        shell.info(Samen.AI.configuration_hint())

      {:error, reason} ->
        shell.info("---")
        shell.error("{:error, #{inspect(reason)}}")
    end
  end

  # A minimal tenant scope. The smoke passes no `:bindings` and an explicit empty `:grounding`,
  # so the scope is used only for resolution plumbing — no DB read is required for the keyless
  # lane. (A host running the live lane calls with its own real scope in application code.)
  defp scope do
    %Samen.Scope{actor: %{id: "smoke", org_id: nil, role: :member, plane: :tenant}}
  end
end

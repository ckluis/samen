defmodule Samen.AI.Agent.Hooks do
  @moduledoc """
  `Samen.AI.Agent.Hooks` — resolution and dispatch for the `Samen.AI.Agent.Hook` chain
  (T181; ADR-047 §10a row 25). The behaviour declares the contract; this module is the
  only thing that enforces it, and the loop calls nothing else.

  Two responsibilities, both narrow:

    * **`resolve/1`** — build the ordered chain for a run: the host-configured hooks
      (`config :samen_core, Samen.AI.Agent, hooks: [...]`) FIRST, then any per-run
      `:hooks` opt. Host policy therefore always gets first say, and a caller-supplied
      hook can never pre-empt it. The host-config source is also the only one the durable
      `Samen.AI.Agent.TurnWorker` can see, so a run resumed by the worker keeps its host
      policy across a batch boundary.

    * **`dispatch/3`** — run the chain at one point and return ONE decision.
      **First-decision-wins:** `Enum.reduce_while/3` stops at the first hook returning
      anything other than `:ok`, so the hooks behind it are never invoked and cannot
      widen, overturn, or soften what was already decided.

  ## Fail closed, structurally

  Every way a hook can misbehave collapses to the same place — the strongest refusal the
  point accepts, tagged `:hook_error` (a block where blocking is honoured, a halt otherwise). Never `:ok`, because `:ok` means "run the tool call unhooked", which is
  exactly the silent degrade this seam exists to prevent:

    * the hook **raises**, **throws**, or **exits** (an unloaded/typo'd module, or one that
      simply does not export `call/2`, included — `UndefinedFunctionError` is rescued like
      any other, which is why the FIRST point such a chain reaches stops the run);
    * the hook returns a decision the point cannot honour (`accepts/1` is a closed set:
      an `:edit` at `:after_tool_execution`, a `:block` at `:session_start`);
    * the hook returns an `{:edit, call}` that changes the tool **identity**, or whose
      `:args` is not a plain map;
    * the hook returns anything not in the contract at all.

  A misconfigured chain is therefore loud (nothing executes) rather than quiet (everything
  executes without its policy).

  ## Bounded reasons

  Block/halt reasons cross into the bounded, token-only turn log, so they are normalized
  here before the loop ever sees them: atoms and binaries only, 64 bytes, `vt_`-free.
  Anything else — a struct, a tuple, a record, a vault token — degrades to `"unbounded"`,
  never an `inspect/1` (the EG6 posture, and the same default-deny shape as
  `Samen.AI.Agent.bounded_meta/1`).
  """

  alias Samen.AI.Agent.Hook

  # Reasons ride the bounded turn-log `meta`; this is the ceiling, in BYTES.
  @max_reason_bytes 64

  # The vault FK-token sentinel. A reason carrying one is not a reason, it is an egress.
  @vt_sentinel "vt_"

  @degraded_reason "unbounded"
  @error_reason "hook_error"

  @typedoc "The resolved, ordered hook chain."
  @type chain :: [module()]

  @typedoc """
  What `dispatch/3` hands back to the loop. Block and halt carry BOTH the bounded
  `error_kind` the turn/run row records and the bounded reason, so the loop never has to
  infer one from the other: `:hook_blocked` / `:hook_halted` is a hook DECIDING, and
  `:hook_error` is this module refusing on a broken hook's behalf.
  """
  @type decision ::
          :ok
          | {:block, :hook_blocked | :hook_error, String.t()}
          | {:edit, map()}
          | {:halt, :hook_halted | :hook_error, String.t()}

  @doc """
  The ordered chain for this run: host-config hooks, then per-run `opts[:hooks]`.

  Entries are NOT validated here on purpose. An unloadable or non-exporting module stays
  in the chain and refuses at dispatch time (fail closed) rather than being quietly
  dropped, which would run the loop with less policy than the host configured.
  """
  @spec resolve(keyword()) :: chain()
  def resolve(opts) when is_list(opts) do
    configured = Application.get_env(:samen_core, Samen.AI.Agent, [])[:hooks]
    listify(configured) ++ listify(Keyword.get(opts, :hooks))
  end

  def resolve(_opts), do: []

  defp listify(nil), do: []
  defp listify(hooks) when is_list(hooks), do: hooks
  defp listify(one), do: [one]

  @doc """
  Run `chain` at `point` with `ctx` and return the FIRST decision, or `:ok` when every
  hook deferred.

  `ctx` is a bounded, token-only map. At `:before_tool_call` it carries at least `:kind`
  (the resolved tool kind) and `:args` (the already-validated args) — `:kind` is what an
  `{:edit, call}` is checked against, since tool identity is immutable.
  """
  @spec dispatch(chain(), Hook.point(), Hook.ctx()) :: decision()
  def dispatch([], _point, _ctx), do: :ok

  def dispatch(chain, point, ctx) when is_list(chain) and is_map(ctx) do
    Enum.reduce_while(chain, :ok, fn hook, :ok ->
      case safe_call(hook, point, ctx) do
        :ok -> {:cont, :ok}
        raw -> {:halt, interpret(point, ctx, raw)}
      end
    end)
  end

  def dispatch(_chain, _point, _ctx), do: :ok

  # A hook that raises/throws/exits does not get to leave the loop running unhooked.
  # `:__hook_error__` is a private sentinel — it is not part of the public contract and
  # a hook returning it verbatim is treated exactly like any other malformed return.
  defp safe_call(hook, point, ctx) do
    hook.call(point, ctx)
  rescue
    _ -> :__hook_error__
  catch
    _kind, _value -> :__hook_error__
  end

  defp interpret(point, _ctx, {:block, reason}) do
    if Hook.accepts?(point, :block),
      do: {:block, :hook_blocked, bounded_reason(reason)},
      else: refuse(point)
  end

  defp interpret(point, _ctx, {:halt, reason}) do
    if Hook.accepts?(point, :halt),
      do: {:halt, :hook_halted, bounded_reason(reason)},
      else: refuse(point)
  end

  defp interpret(point, ctx, {:edit, call}) do
    with true <- Hook.accepts?(point, :edit),
         {:ok, args} <- normalize_edit(ctx, call) do
      {:edit, %{kind: Map.get(ctx, :kind), args: args}}
    else
      _ -> refuse(point)
    end
  end

  defp interpret(point, _ctx, _malformed_or_error), do: refuse(point)

  # The strongest refusal the point can honour. `:block` keeps the run alive under its
  # budgets with an honest refusal turn; where blocking is not a thing the point can do,
  # the only fail-closed answer left is to stop the run.
  defp refuse(point) do
    if Hook.accepts?(point, :block),
      do: {:block, :hook_error, @error_reason},
      else: {:halt, :hook_error, @error_reason}
  end

  # Tool IDENTITY is immutable across an edit: an edit may narrow the ARGS of the call the
  # model asked for, and may not turn it into a call to some other tool (the Alloy
  # id/name-immutability rule, `findings/034` item 2, re-implemented natively). Omitting
  # `:kind` is the ordinary spelling; supplying a DIFFERENT one is a fail-closed refusal.
  defp normalize_edit(ctx, call) when is_map(call) and not is_struct(call) do
    requested = Map.get(ctx, :kind)
    args = Map.get(call, :args)

    if Map.get(call, :kind, requested) == requested and is_map(args) and not is_struct(args) do
      {:ok, args}
    else
      :error
    end
  end

  defp normalize_edit(_ctx, _call), do: :error

  @doc """
  Normalize a hook-supplied reason to the bounded, token-only shape the turn log accepts:
  an atom or binary, at most #{@max_reason_bytes} bytes, never carrying a `vt_` vault
  token. Anything else degrades to `"#{@degraded_reason}"` — never an `inspect/1`.
  """
  @spec bounded_reason(term()) :: String.t()
  def bounded_reason(reason) when is_atom(reason) and not is_nil(reason),
    do: reason |> Atom.to_string() |> bound()

  def bounded_reason(reason) when is_binary(reason), do: bound(reason)
  def bounded_reason(reason) when is_integer(reason), do: Integer.to_string(reason)
  def bounded_reason(_reason), do: @degraded_reason

  defp bound(string) do
    cond do
      String.contains?(string, @vt_sentinel) -> @degraded_reason
      byte_size(string) <= @max_reason_bytes -> string
      true -> trim_valid(binary_part(string, 0, @max_reason_bytes))
    end
  end

  # Truncation happens in BYTES, so the tail may be a split codepoint: shave until the
  # remainder is valid UTF-8 (a persisted column never takes an invalid binary).
  defp trim_valid(""), do: @degraded_reason

  defp trim_valid(bin) do
    if String.valid?(bin),
      do: bin,
      else: trim_valid(binary_part(bin, 0, byte_size(bin) - 1))
  end
end

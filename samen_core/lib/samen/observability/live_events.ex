defmodule Samen.Observability.LiveEvents do
  @moduledoc """
  The bounded `event` value of a LiveView wide event (ADR-052 §2.1, red path R2).

  `handle_event/3`'s first argument is a string the **client** sends. It is attacker
  controlled: turning it into an atom would let a client exhaust the atom table (atoms are
  never garbage-collected), and recording it verbatim would let any string — a name, an
  email typed into a `phx-click` payload by a hostile client — reach the trace sink. So the
  client string is NEVER converted, interned or recorded. It is only ever used as a
  **lookup key** into a set the server already owns.

  ## The bounded set: the view's own static event literals

  The set of events a view can meaningfully receive is the set its code handles. For a
  module, `events/1` returns `%{"save" => :save, …}` built from the developer-authored
  string literals in the first argument of its `handle_event/3` clauses:

      def handle_event("save", params, socket)            # → "save"   => :save
      def handle_event("sort" = ev, params, socket)       # → "sort"   => :sort
      def handle_event("row:" <> id, params, socket)      # prefix — not a literal → :other
      def handle_event(event, params, socket)             # catch-all  → :other

  Atoms are minted ONLY from those literals (bounded by the code, created once per loaded
  module version) and only when the literal is a short, identifier-shaped label
  (1–64 chars of `[A-Za-z0-9_.:-]`) that is not PII-shaped. `resolve/2` maps a
  client string to the literal's atom with a plain `Map.fetch/2` — or `:other`. There is no
  code path from the client string to `String.to_atom/1`.

  ## Where the literals come from

    1. `__samen_live_events__/0`, if the module defines it — an explicit declaration
       (a list of strings), for views whose events are not plain literals, and for
       releases built without debug info.
    2. Otherwise the module's compiled **debug info** (the Elixir definitions in the BEAM's
       `Dbgi` chunk): the clause heads of `handle_event/3`. Read once per module version and
       memoized in `:persistent_term` keyed by the module's MD5.
    3. Neither available (a stripped release BEAM, a cover-compiled module) → the empty
       set, so every event is `:other`. Fail-safe: less detail, never more.

  `mix release` strips `Dbgi` by default (`strip_beams: true`); a release that wants event
  names in production keeps it (`strip_beams: [keep: ["Dbgi"]]`) or declares
  `__samen_live_events__/0`.
  """

  @other :other

  @doc "The value an unknown / non-literal / non-string event resolves to."
  @spec other() :: :other
  def other, do: @other

  @doc """
  Resolve a client-sent `event` for `module` to a bounded atom: the module's own literal's
  atom if `event` is one of its statically handled events, else `:other`.

  Never creates an atom from `event`.
  """
  @spec resolve(module() | term(), term()) :: atom()
  def resolve(module, event) when is_atom(module) and is_binary(event) do
    case Map.fetch(events(module), event) do
      {:ok, atom} -> atom
      :error -> @other
    end
  end

  def resolve(_module, _event), do: @other

  @doc """
  The `%{literal => atom}` map of `module`'s statically handled events (memoized per
  module version). Empty when the module is not loaded or carries no readable clauses.
  """
  @spec events(module()) :: %{String.t() => atom()}
  def events(module) when is_atom(module) do
    case md5(module) do
      nil ->
        %{}

      md5 ->
        key = {__MODULE__, module, md5}

        case :persistent_term.get(key, :miss) do
          :miss ->
            map = compute(module)
            :persistent_term.put(key, map)
            map

          map ->
            map
        end
    end
  end

  @doc false
  # The pure literal → atom step, exposed for tests. Only label-shaped, non-PII-shaped
  # developer literals are kept.
  @spec to_map([term()]) :: %{String.t() => atom()}
  def to_map(literals) do
    for literal <- literals,
        is_binary(literal),
        label?(literal),
        not Samen.PiiValueShape.pii_shaped_id?(literal),
        into: %{},
        # The literal is developer code, not client input — bounded by the module's size.
        do: {literal, String.to_atom(literal)}
  end

  # ---------------------------------------------------------------------------

  # A short, identifier-shaped label (a regex is not stored in a module attribute: OTP 28+
  # cannot escape a compiled regex into the module).
  defp label?(literal), do: Regex.match?(~r/\A[a-z0-9_.:\-]{1,64}\z/i, literal)

  defp md5(module) do
    if Code.ensure_loaded?(module), do: module.module_info(:md5), else: nil
  rescue
    _ -> nil
  end

  defp compute(module) do
    module |> literals() |> to_map()
  rescue
    _ -> %{}
  end

  defp literals(module) do
    if function_exported?(module, :__samen_live_events__, 0) do
      List.wrap(module.__samen_live_events__())
    else
      debug_info_literals(module)
    end
  end

  defp debug_info_literals(module) do
    with path when is_list(path) <- :code.which(module),
         {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(path, [:debug_info]),
         {:ok, %{definitions: defs}} <- backend.debug_info(:elixir_v1, module, data, []) do
      for {{:handle_event, 3}, _kind, _meta, clauses} <- defs,
          {_meta, [first | _], _guards, _body} <- clauses,
          literal <- [literal(first)],
          literal != nil,
          uniq: true,
          do: literal
    else
      _ -> []
    end
  end

  # A clause's first argument as a string literal: `"save"` or `"save" = var` / `var = "save"`.
  defp literal(bin) when is_binary(bin), do: bin
  defp literal({:=, _, [left, right]}), do: literal(left) || literal(right)
  defp literal(_), do: nil
end

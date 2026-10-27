defmodule Samen.Signals.NoPii do
  @moduledoc """
  No PII in an `Ash.Signals` signal (issue #96 D2) — the check behind
  `mix samen.verify.signals_no_pii`.

  A signal's arguments are its payload. With the default inline delivery they stay in
  memory, but a listener may choose its own delivery (`AshOban.Signals` runs it in a job),
  and that serialises the payload into `oban_jobs.args` — a sink the ADR-037 §5.9 /
  ADR-039 §4.3 rule keeps to bounded ids and enums, never attribute values or `vt_*`
  tokens. The emitter cannot know which delivery its listeners pick (a listener can switch
  to a job without the emitter changing), so the rule holds for EVERY signal, whatever its
  listeners do today.

  ## What it refuses

    1. **A signal argument whose type classifies `:pii`** under
       `Samen.Pii.Classification` — the same mask-unknown-by-default oracle the column
       verifiers use. A vault/PII type is refused, and so is any type not provably
       non-PII: a free `:string` (a laundered name has nowhere to land), a map, an
       unknown custom type. The only way out is the existing two-party type clearance
       (ADR-034); this check adds no allow-list of its own. `{:array, inner}` is judged
       by `inner`.
    2. **An `emit` that copies a declared PII attribute into a signal**, by the same
       name or through `fields:`. This catches what (1) cannot: a `pii_attribute`
       declared with a scalar type that does classify `:non_pii` (an integer tax id),
       whose value would otherwise ride a well-typed argument.

  An `emit ..., dynamic?: true` builds its payload in code; (1) still binds it, because the
  payload is cast into the signal's typed struct. Generic actions source fields from their
  own arguments and result, not attributes, so (2) does not apply to them.
  """

  alias Samen.Pii.Classification

  @doc """
  Every violation across `resources`: the arguments of each signal module they emit or
  listen to, plus each of their `emit`s.
  """
  @spec violations([module()]) :: [String.t()]
  def violations(resources) do
    argument_violations = Enum.flat_map(signal_modules(resources), &argument_violations/1)
    argument_violations ++ Enum.flat_map(resources, &emit_violations/1)
  end

  @doc "The signal modules `resources` emit to or listen to, sorted and unique."
  @spec signal_modules([module()]) :: [module()]
  def signal_modules(resources) do
    resources
    |> Enum.flat_map(fn resource ->
      Ash.Resource.Info.signals_out(resource) ++
        Enum.map(Ash.Resource.Info.signal_listeners(resource), & &1.signal_module)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Rule (1): the arguments of `signal_module`'s signals whose type classifies `:pii`."
  @spec argument_violations(module()) :: [String.t()]
  def argument_violations(signal_module) do
    for signal <- Ash.Signals.Info.signals(signal_module),
        argument <- signal.arguments,
        Classification.pii?(element_type(argument.type)) do
      "#{inspect(signal_module)} :#{signal.name} argument :#{argument.name} — type " <>
        "#{inspect(argument.type)} classifies :pii; a signal argument must be a bounded " <>
        "non-PII type (ids, enums, numbers, booleans, timestamps), because a listener may " <>
        "serialise it into oban_jobs.args"
    end
  end

  @doc "Rule (2): `resource`'s `emit`s that take a signal field from a declared PII attribute."
  @spec emit_violations(module()) :: [String.t()]
  def emit_violations(resource) do
    for action <- Ash.Resource.Info.actions(resource),
        action.type != :action,
        emit <- Map.get(action, :emits, []),
        {field, attribute} <- attribute_sources(resource, emit),
        Samen.Pii.Info.vault_routed?(resource, attribute) do
      "#{inspect(resource)} action :#{action.name} emits #{inspect(emit.signal_module)} " <>
        ":#{emit.signal} — signal field :#{field} is taken from the PII attribute " <>
        ":#{attribute}; a PII value must never ride a signal"
    end
  end

  # The {signal_field, attribute} pairs an emit reads from the record: every `fields:`
  # mapping, plus each signal argument with no `fields:`/`values:` entry that names an
  # attribute of the resource (Ash takes those implicitly, by name).
  defp attribute_sources(resource, emit) do
    arguments =
      case Ash.Signals.Info.signal(emit.signal_module, emit.signal) do
        nil -> []
        signal -> Enum.map(signal.arguments, & &1.name)
      end

    explicit = Map.new(emit.fields)
    set_by_value = emit.values |> Keyword.keys() |> MapSet.new()

    implicit =
      for name <- arguments,
          not Map.has_key?(explicit, name),
          not MapSet.member?(set_by_value, name),
          Ash.Resource.Info.attribute(resource, name),
          do: {name, name}

    Enum.sort(Map.to_list(explicit) ++ implicit)
  end

  defp element_type({:array, inner}), do: element_type(inner)
  defp element_type(type), do: type
end

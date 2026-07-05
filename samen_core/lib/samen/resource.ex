defmodule Samen.Resource do
  @moduledoc """
  The Samen base macro (plan A1). Every resource in the foundry is declared with
  `use Samen.Resource` — one macro wires self-qualifying storage, the injected
  universal columns, the PII/catalog extensions, and (optionally) single-table
  fragment composition.

  ## Two shapes

      # a plain resource
      use Samen.Resource,
        otp_app: :my_app,
        domain: MyApp.Crm,
        data_layer: AshPostgres.DataLayer,
        abbrev: "com"

      # a resource that folds in a shared fragment (single-table composition)
      use Samen.Resource,
        otp_app: :my_app,
        domain: MyApp.Clinical,
        data_layer: AshPostgres.DataLayer,
        abbrev: "pat",
        base: Core.Person

  ## What the macro does

    1. **Validates the abbrev caller-side** (a friendly `CompileError` at the
       resource's own `use` line) and injects a first-class
       `samen do abbrev "com" end` section (S0.2 note F4 — introspectable via
       `Samen.Info.abbrev/1`, survives fragment folding) rather than a bare module
       attribute. `use Samen.Resource, abbrev: "com"` is sugar for that section.
    2. **Wires the fixed Samen extension allow-list** — `Samen.Extension` (the
       `samen` section + abbrev transformer + registry verifier + core-column
       injection), `Samen.Pii`, and `Samen.Catalog`.
    3. **Injects the universal columns** `id` / `org_id` / `inserted_at` /
       `updated_at` on every resource (via `Samen.Transformers.CoreAttributes`),
       each prefixed with the resource abbrev.
    4. **Prefixes every physical column** with `<abbrev>_` (via
       `Samen.Transformers.AbbrevStorage`) while logical `:name` is untouched.
    5. **Enforces the abbrev registry** (`Samen.Verifiers.AbbrevRegistry`):
       permanent, 3-letter-lowercase, collision-free, never-recycled.
    6. **Folds a `base:` fragment** into one physical table, guarded by the
       extension allow-list (below).

  ## Fragment composition & the extension allow-list gate (Gate-0 fix task #3)

  `base:` folds a `Spark.Dsl.Fragment` into the resource via Spark's `fragments:`
  mechanism → ONE physical table (never Postgres `INHERITS`). A fragment declares
  the extensions whose DSL it uses. Spark's own behaviour *silently unions* those
  extensions into the composing resource — so a fragment could smuggle in a DSL
  section (and its guarantees) the base macro never wired. `Samen.Resource` refuses:
  if a fragment declares a **Samen-namespace** extension outside the provided
  allow-list (`#{inspect([Samen.Extension, Samen.Pii, Samen.Catalog])}`), the
  composing resource fails to compile at its own `use` line with a clear diagnostic.

  The gate uses `Code.ensure_compiled/1` (NOT `ensure_loaded?/1`): the fragment's
  `extensions/0` is only defined at its `@before_compile`, so `ensure_loaded?/1`
  would race with compile ordering. `ensure_compiled/1` forces the fragment to
  compile first.
  """

  @abbrev_pattern ~r/\A[a-z]{3}\z/

  # The Samen extensions the base macro provides to every resource. A fragment may
  # declare (use DSL from) only these; any other Samen-namespace extension is a
  # fragment asking for a capability the base macro did not wire → fail closed.
  @provided_samen_extensions [Samen.Extension, Samen.Pii, Samen.Catalog]

  defmacro __using__(opts) do
    {abbrev, opts} = Keyword.pop(opts, :abbrev)
    {base, ash_opts} = Keyword.pop(opts, :base)

    # Validate caller-side so the diagnostic points at the resource's own `use`
    # line. Abbrev shape first, then the fragment extension gate (Gate-0 fix #3 —
    # independent of the abbrev), then the committed registry (permanence/collision).
    validate_abbrev!(abbrev, __CALLER__)

    # RED PATH gate (Gate-0 fix #3): a fragment may only require provided extensions.
    if base do
      Samen.Resource.verify_fragment_extensions!(base, __CALLER__)
    end

    validate_registry!(abbrev, __CALLER__)

    ash_opts =
      ash_opts
      |> Keyword.update(:extensions, provided_samen_extensions(), fn exts ->
        Enum.uniq(provided_samen_extensions() ++ List.wrap(exts))
      end)
      |> maybe_put_fragments(base)

    quote do
      use Ash.Resource, unquote(ash_opts)

      # First-class `samen do abbrev "..." end` section (F4). This is the source
      # of truth for the abbrev, introspectable via Samen.Info.abbrev/1.
      samen do
        abbrev(unquote(abbrev))
      end
    end
  end

  @doc false
  def provided_samen_extensions, do: @provided_samen_extensions

  @doc """
  Reads the resource's abbrev out of DSL state, fail-closed.

  Called by `Samen.Transformers.AbbrevStorage`. Reads the first-class `samen`
  section (F4). Raises `Spark.Error.DslError` naming the offending module if the
  abbrev is missing or malformed — self-qualifying storage is not optional. (The
  base macro's caller-side check catches the common case with a friendlier message;
  this is the defense-in-depth second line for resources built without the macro.)
  """
  def fetch_abbrev!(dsl_state) do
    module = Spark.Dsl.Transformer.get_persisted(dsl_state, :module)
    abbrev = Spark.Dsl.Extension.get_opt(dsl_state, [:samen], :abbrev, nil)

    if is_binary(abbrev) and Regex.match?(@abbrev_pattern, abbrev) do
      abbrev
    else
      raise Spark.Error.DslError,
        module: module,
        path: [:samen, :abbrev],
        message:
          "Samen.Resource requires a 3-letter lowercase `abbrev:` (e.g. " <>
            "`abbrev: \"com\"`). Self-qualifying storage is not optional: every " <>
            "column carries its resource's permanent abbrev. Got: " <> inspect(abbrev)
    end
  end

  @doc false
  # RED PATH enforcement (Gate-0 fix #3). Verifies every Samen extension the
  # fragment declares is one the base macro provides.
  def verify_fragment_extensions!(base, caller) do
    fragment = Macro.expand(base, caller)

    # Force the fragment to compile first (compile-time dependency): the fragment's
    # extensions/0 is only defined at its @before_compile, so ensure_loaded?/1 can
    # race with compile ordering. ensure_compiled/1 blocks until it is available.
    loaded? =
      is_atom(fragment) and
        match?({:module, ^fragment}, Code.ensure_compiled(fragment)) and
        function_exported?(fragment, :extensions, 0)

    unless loaded? do
      raise %CompileError{
        file: caller.file,
        line: caller.line,
        description:
          "use Samen.Resource, base: #{inspect(fragment)} — `base:` must be a " <>
            "compiled Spark.Dsl.Fragment (defining extensions/0). Got: #{inspect(fragment)}"
      }
    end

    declared = fragment.extensions()

    # Only police Samen-namespace extensions; Ash's own defaults are always present
    # and are not ours to gate.
    missing =
      declared
      |> Enum.filter(&samen_extension?/1)
      |> Enum.reject(&(&1 in @provided_samen_extensions))

    unless missing == [] do
      raise %CompileError{
        file: caller.file,
        line: caller.line,
        description:
          "Fragment #{inspect(fragment)} declares extension(s) #{inspect(missing)} " <>
            "that `use Samen.Resource` does not provide. A composed resource cannot " <>
            "fold in a fragment whose DSL the base macro never wired — self-qualifying " <>
            "storage, catalog, and PII routing are the only Samen extensions provided " <>
            "(#{inspect(@provided_samen_extensions)}). Either drop the extension from " <>
            "the fragment or extend Samen.Resource to provide it."
      }
    end

    :ok
  end

  defp samen_extension?(module) when is_atom(module) do
    case Atom.to_string(module) do
      "Elixir.Samen." <> _ -> true
      _ -> false
    end
  end

  defp samen_extension?(_), do: false

  defp maybe_put_fragments(ash_opts, nil), do: ash_opts

  defp maybe_put_fragments(ash_opts, base) do
    Keyword.update(ash_opts, :fragments, [base], fn frags ->
      Enum.uniq([base | List.wrap(frags)])
    end)
  end

  # Caller-side abbrev REGISTRY enforcement (permanent / 3-letter / collision-free
  # / never-recycled). Done in the macro (not only the Spark verifier) because a
  # Spark verifier raising during `Code.compile_string` does NOT reliably abort the
  # compile in this Ash/Spark version, whereas a raise here hard-fails at the `use`
  # line — the fail-closed guarantee the registry needs. The verifier remains as
  # defense-in-depth + introspection.
  defp validate_registry!(abbrev, caller) do
    module = caller.module

    if is_binary(abbrev) and is_atom(module) and not is_nil(module) do
      registry = Samen.AbbrevRegistry.load()

      case Samen.AbbrevRegistry.validate(registry, abbrev, inspect(module)) do
        :ok ->
          :ok

        {:error, reason} ->
          raise %CompileError{file: caller.file, line: caller.line, description: reason}
      end
    end
  end

  # Caller-local abbrev validation with a friendly message. `nil` (no abbrev given)
  # and a malformed abbrev both fail here; the registry verifier is the durable
  # backstop that also enforces permanence/collision.
  defp validate_abbrev!(abbrev, caller) do
    unless is_binary(abbrev) and Regex.match?(@abbrev_pattern, abbrev) do
      raise %CompileError{
        file: caller.file,
        line: caller.line,
        description:
          "use Samen.Resource requires `abbrev: \"xxx\"` (3 lowercase letters). " <>
            "Self-qualifying storage is mandatory — every column is prefixed with " <>
            "its resource abbrev. Got: #{inspect(abbrev)}"
      }
    end
  end
end

defmodule Samen.Extension do
  @moduledoc """
  Spark DSL extension carrying the Samen abbrev storage transformer.

  Copied from the S0.2 spike. In the real foundry `Samen.Resource` wires several
  extensions (catalog, PII vault, verifiers); S0.3 wires the abbrev transformer
  (this module) plus `Samen.Pii` and `Samen.Catalog`.
  """
  use Spark.Dsl.Extension, transformers: [Samen.Transformers.AbbrevStorage]
end

defmodule Samen.Resource do
  @moduledoc """
  Base macro for Samen resources (S0.3 spike scope: abbrev storage + fragment
  single-table composition).

  Two shapes:

      # a plain composed resource
      use Samen.Resource, domain: ..., data_layer: AshPostgres.DataLayer, abbrev: "cpy"

      # a resource that folds in a shared fragment (single-table composition)
      use Samen.Resource, domain: ..., abbrev: "pat", base: Core.Person

  `base:` folds a `Spark.Dsl.Fragment` (e.g. `Core.Person`) into the resource via
  Spark's `fragments:` mechanism. The fragment's shared attributes and its `pii`
  section become attributes/columns of the composed resource. Because the
  fragment has no data layer of its own, it has **no table**; each composing
  resource compiles to **one physical table**, and the abbrev transformer
  prefixes every folded-in column with the *composing* resource's abbrev
  (`pat_*`, `stf_*`). This is Ash resource/fragment composition — explicitly NOT
  Postgres `CREATE TABLE … INHERITS` (a footgun Samen never emits).

  ## Provided extensions

  `Samen.Resource` injects a fixed allow-list of Samen extensions into every
  resource: `Samen.Extension` (abbrev transformer), `Samen.Pii` (vault-routing
  DSL / `pii do` section), and `Samen.Catalog`. Any fragment folded in via
  `base:` may only *use* DSL from that allow-list.

  ## Fail-closed contract (S0.3 RED PATH)

  A `Spark.Dsl.Fragment` declares the extensions whose DSL it uses
  (`use Spark.Dsl.Fragment, of: Ash.Resource, extensions: [Samen.Pii, ...]`).
  If a fragment declares a **Samen** extension that the composing resource does
  NOT provide (i.e. one outside the allow-list above), `use Samen.Resource,
  base: <fragment>` raises a `CompileError` at the composing resource's own
  `use` line. The resource cannot compile — a fragment cannot smuggle in a DSL
  section (and its guarantees) the base macro never wired. This is defense in
  depth over Spark's own behaviour, which would otherwise silently union the
  extra extension into the resource.
  """

  @abbrev_pattern ~r/\A[a-z][a-z0-9]{1,4}\z/

  # The Samen extensions `Samen.Resource` provides to every resource. A fragment
  # may declare (use DSL from) only these; anything else in the Samen namespace
  # is a fragment asking for a capability the base macro did not wire → fail.
  @provided_samen_extensions [Samen.Extension, Samen.Pii, Samen.Catalog]

  defmacro __using__(opts) do
    {abbrev, opts} = Keyword.pop(opts, :abbrev)
    {base, ash_opts} = Keyword.pop(opts, :base)

    # Validate here (caller's compile) so the diagnostic points at the resource's
    # own `use Samen.Resource` line. The transformer re-checks (defense in depth).
    validate_abbrev!(abbrev, __CALLER__)

    # RED PATH gate: a fragment may only require extensions we provide.
    if base do
      Samen.Resource.verify_fragment_extensions!(base, __CALLER__)
    end

    ash_opts =
      ash_opts
      |> Keyword.update(:extensions, provided_samen_extensions(), fn exts ->
        Enum.uniq(provided_samen_extensions() ++ List.wrap(exts))
      end)
      |> maybe_put_fragments(base)

    quote do
      Module.register_attribute(__MODULE__, :samen_abbrev, persist: false)
      Module.put_attribute(__MODULE__, :samen_abbrev, unquote(abbrev))

      use Ash.Resource, unquote(ash_opts)
    end
  end

  @doc false
  def provided_samen_extensions, do: @provided_samen_extensions

  @doc false
  # Called by the abbrev transformer. Reads the abbrev the macro stashed.
  # Fail-closed second line of defense (the macro catches the common case).
  def fetch_abbrev!(dsl_state) do
    module = Spark.Dsl.Transformer.get_persisted(dsl_state, :module)
    abbrev = module && Module.get_attribute(module, :samen_abbrev)

    cond do
      is_binary(abbrev) and Regex.match?(@abbrev_pattern, abbrev) ->
        abbrev

      true ->
        raise Spark.Error.DslError,
          module: module,
          path: [:samen, :abbrev],
          message:
            "Samen.Resource requires an `abbrev:` option (2-5 lowercase chars, " <>
              "e.g. `abbrev: \"pat\"`). Self-qualifying storage is not optional. Got: " <>
              inspect(abbrev)
    end
  end

  @doc false
  # RED PATH enforcement. Verifies every extension the fragment declares is one
  # the base macro provides. A fragment requiring a Samen extension outside the
  # allow-list (a capability we never wired) fails the composing resource's
  # compile with a clear diagnostic.
  def verify_fragment_extensions!(base, caller) do
    fragment = Macro.expand(base, caller)

    # Force the fragment to be compiled first (compile-time dependency): the
    # fragment's `extensions/0` is only defined at its @before_compile, so
    # ensure_loaded? can race with compile ordering. ensure_compiled/1 blocks
    # until the fragment is available (or truly missing).
    loaded? =
      is_atom(fragment) and
        match?({:module, ^fragment}, Code.ensure_compiled(fragment)) and
        function_exported?(fragment, :extensions, 0)

    unless loaded? do
      raise %CompileError{
        file: caller.file,
        line: caller.line,
        description:
          "use Samen.Resource, base: #{inspect(fragment)} — `base:` must be a compiled " <>
            "Spark.Dsl.Fragment (defining extensions/0). Got: #{inspect(fragment)}"
      }
    end

    declared = fragment.extensions()

    # Only police Samen-namespace extensions; Ash's own defaults (Ash.Resource.Dsl
    # etc.) are always present and are not ours to gate.
    missing =
      declared
      |> Enum.filter(&samen_extension?/1)
      |> Enum.reject(&(&1 in @provided_samen_extensions))

    unless missing == [] do
      raise %CompileError{
        file: caller.file,
        line: caller.line,
        description:
          "Fragment #{inspect(fragment)} declares extension(s) " <>
            "#{inspect(missing)} that `use Samen.Resource` does not provide. " <>
            "A composed resource cannot fold in a fragment whose DSL the base " <>
            "macro never wired — self-qualifying storage, catalog, and PII " <>
            "routing are the only Samen extensions provided " <>
            "(#{inspect(@provided_samen_extensions)}). Either drop the extension " <>
            "from the fragment or extend Samen.Resource to provide it."
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

  # Compile-time (caller-local) abbrev validation with a friendly message.
  defp validate_abbrev!(abbrev, caller) do
    unless is_binary(abbrev) and Regex.match?(@abbrev_pattern, abbrev) do
      raise %CompileError{
        file: caller.file,
        line: caller.line,
        description:
          "use Samen.Resource requires `abbrev: \"xxx\"` (2-5 lowercase alnum, " <>
            "starting with a letter). Self-qualifying storage is mandatory — " <>
            "every column is prefixed with its resource abbrev. Got: #{inspect(abbrev)}"
      }
    end
  end
end

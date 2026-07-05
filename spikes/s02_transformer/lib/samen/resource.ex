defmodule Samen.Extension do
  @moduledoc """
  Spark DSL extension that carries the Samen abbrev storage transformer.

  In the real foundry `Samen.Resource` wires several extensions (catalog, PII
  vault, verifiers). For the S0.2 spike we only need the storage transformer.
  """
  use Spark.Dsl.Extension, transformers: [Samen.Transformers.AbbrevStorage]
end

defmodule Samen.Resource do
  @moduledoc """
  Prototype base macro for Samen resources (S0.2 spike scope).

      defmodule Crm.Contact do
        use Samen.Resource,
          otp_app: :s02_transformer,
          domain: S02Transformer.Crm,
          data_layer: AshPostgres.DataLayer,
          abbrev: "com"

        postgres do
          table "com_contact"
          repo S02Transformer.Repo
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string, public?: true   # stored as com_name
          attribute :org_id, :uuid, public?: true    # stored as com_org_id
        end
      end

  `use Samen.Resource` requires a 3-letter-ish `abbrev`. It:

    * validates the abbrev (fail-closed: missing abbrev => compile error),
    * stashes it in a module attribute the transformer reads back,
    * delegates to `use Ash.Resource` with the `Samen.Extension` transformer
      layered on.

  The transformer (`Samen.Transformers.AbbrevStorage`) then rewrites each
  attribute's `:source` to `<abbrev>_<name>` so the physical column /
  migration / SQL / catalog all carry the resource abbrev, while app code
  keeps writing the idiomatic logical name.
  """

  @abbrev_pattern ~r/\A[a-z][a-z0-9]{1,4}\z/

  defmacro __using__(opts) do
    {abbrev, ash_opts} = Keyword.pop(opts, :abbrev)

    # We deliberately validate here (in the caller's compile) so the diagnostic
    # points at the resource's own `use Samen.Resource` line. The transformer
    # also re-checks (defense in depth) in case a resource is built without the
    # macro.
    validate_abbrev!(abbrev, __CALLER__)

    quote do
      # Read back by Samen.Resource.fetch_abbrev!/1 inside the transformer.
      Module.register_attribute(__MODULE__, :samen_abbrev, persist: false)
      Module.put_attribute(__MODULE__, :samen_abbrev, unquote(abbrev))

      use Ash.Resource,
          unquote(
            Keyword.update(ash_opts, :extensions, [Samen.Extension], fn exts ->
              [Samen.Extension | List.wrap(exts)]
            end)
          )
    end
  end

  @doc false
  # Called by the transformer. Reads the abbrev the macro stashed on the module.
  # Fail-closed: a Samen resource with no abbrev raises a DslError naming the
  # offending module. (This is the second line of defense; the macro above
  # catches the common case with a caller-local message.)
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
              "e.g. `abbrev: \"com\"`). Self-qualifying storage is not optional: " <>
              "every column must carry its resource's permanent abbrev. Got: " <>
              inspect(abbrev)
    end
  end

  # Compile-time (caller-local) validation with a friendly message.
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

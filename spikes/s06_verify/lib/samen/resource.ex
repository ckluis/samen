defmodule Samen.Extension do
  @moduledoc """
  Spark DSL extension that carries the Samen abbrev storage transformer.
  """
  use Spark.Dsl.Extension, transformers: [Samen.Transformers.AbbrevStorage]
end

defmodule Samen.Resource do
  @moduledoc """
  Prototype base macro for Samen resources (reused from S0.2/S0.4).
  """

  @abbrev_pattern ~r/\A[a-z][a-z0-9]{1,4}\z/

  defmacro __using__(opts) do
    {abbrev, ash_opts} = Keyword.pop(opts, :abbrev)

    validate_abbrev!(abbrev, __CALLER__)

    quote do
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
              "e.g. `abbrev: \"com\"`). Got: " <> inspect(abbrev)
    end
  end

  defp validate_abbrev!(abbrev, caller) do
    unless is_binary(abbrev) and Regex.match?(@abbrev_pattern, abbrev) do
      raise %CompileError{
        file: caller.file,
        line: caller.line,
        description:
          "use Samen.Resource requires `abbrev: \"xxx\"` (2-5 lowercase alnum, " <>
            "starting with a letter). Got: #{inspect(abbrev)}"
      }
    end
  end
end

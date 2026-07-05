defmodule Mix.Tasks.Samen.Catalog.Dump do
  @shortdoc "Emit a deterministic committed schema.dict.json for LLM grounding."

  @moduledoc """
  `mix samen.catalog.dump` — generates `schema.dict.json`, the committed
  machine-readable catalog artifact (plan B3).

  ## What it emits

  A JSON object with two stable-ordered top-level keys:

      {
        "tables": [
          {
            "table_name": "com_contact",
            "resource": "SamenCore.Support.Crm.Contact",
            "fields": [
              {
                "column_name": "com_id",
                "logical_name": "id",
                "type": "UUID"
              },
              ...
            ]
          },
          ...
        ]
      }

  **Stable ordering** (byte-identical across two runs on the same codebase):

    * Tables sorted by `table_name` (ascending).
    * Fields within each table sorted by `column_name` (ascending).

  This ordering means the file can be committed and diffed cleanly — a schema
  change produces a minimal, readable diff.

  ## Output path

  Defaults to `schema.dict.json` in the mix project root. Override with
  `--output <path>`.

  ## Domains

  The task discovers resources by inspecting the `:ash` configured domains for
  the current OTP application, or via `--domain MyApp.SomeDomain` (repeatable).

      mix samen.catalog.dump
      mix samen.catalog.dump --output priv/schema.dict.json
      mix samen.catalog.dump --domain MyApp.Crm --domain MyApp.Billing

  ## Exit code

  Exits 0 on success. Does not require a running database connection — reads only
  from `Ash.Resource.Info` introspection (compile-time metadata).
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [output: :string, domain: [:string, :keep]]
      )

    output_path = Keyword.get(opts, :output, "schema.dict.json")
    domain_args = Keyword.get_values(opts, :domain)

    # Ensure the app is compiled so resources are available.
    Mix.Task.run("compile")

    domains = resolve_domains(domain_args)

    unless domains != [] do
      Mix.raise(
        "No domains found. Either configure :ash, :domains in your app config, " <>
          "or pass --domain MyApp.SomeDomain."
      )
    end

    resources = Samen.Catalog.resource_modules(domains)

    dict = build_dict(resources)
    json = Jason.encode!(dict, pretty: true)

    File.write!(output_path, json <> "\n")
    Mix.shell().info("samen.catalog.dump: wrote #{output_path} (#{length(dict["tables"])} tables)")
  end

  @doc """
  Build the schema dict map from a list of resource modules.

  Separated for testability — callers can pass resource module lists directly
  and compare the structure without touching the filesystem.
  """
  def build_dict(resources) do
    tables =
      resources
      |> Enum.map(fn resource ->
        tam = Samen.Catalog.table(resource)
        flds = Samen.Catalog.fields(resource)

        %{
          "table_name" => tam.table_name,
          "resource" => tam.resource,
          "fields" =>
            Enum.map(flds, fn f ->
              %{
                "column_name" => f.column_name,
                "logical_name" => f.logical_name,
                "type" => f.type
              }
            end)
        }
      end)
      # Stable sort: tables by table_name; fields already sorted in Samen.Catalog.fields/1
      |> Enum.sort_by(& &1["table_name"])

    %{"tables" => tables}
  end

  # Discover domain modules to introspect. Priority:
  #   1. --domain CLI args (explicit)
  #   2. :ash, :domains from the current OTP app config
  defp resolve_domains([]) do
    app = Mix.Project.config()[:app]

    case Application.get_env(:ash, :domains) do
      domains when is_list(domains) ->
        domains

      _ ->
        # Try app-level config as a fallback
        case Application.get_env(app, :ash_domains) do
          domains when is_list(domains) -> domains
          _ -> []
        end
    end
  end

  defp resolve_domains(domain_strings) do
    Enum.map(domain_strings, fn ds ->
      mod = Module.concat([ds])

      case Code.ensure_compiled(mod) do
        {:module, ^mod} ->
          mod

        _ ->
          Mix.raise("Domain module #{inspect(mod)} could not be compiled/loaded.")
      end
    end)
  end
end

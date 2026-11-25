defmodule Samen.Catalog.Domains do
  @moduledoc """
  The ONE resolver of "which Ash domains does this host catalogue", shared by `mix samen.catalog.dump` and
  `mix samen.verify.catalog_meaning` so the dump and the verifier can never look at different sets of resources.

  Priority: `--domain` arguments (explicit, each must compile), else `config :ash, :domains`, else the host app's
  `config <app>, :ash_domains`. Pure of Mix: the caller passes the OTP app name and turns an `{:error, message}` into
  its own raise.
  """

  @doc """
  Resolve the domain modules. `domain_args` are the `--domain` strings (may be empty); `app` is the host's OTP app.
  Returns `{:ok, domains}` (possibly `[]`: the caller decides whether none is fatal) or `{:error, message}` for a
  `--domain` that cannot be compiled/loaded.
  """
  @spec resolve([String.t()], atom() | nil) :: {:ok, [module()]} | {:error, String.t()}
  def resolve([], app), do: {:ok, configured(app)}

  def resolve(domain_strings, _app) when is_list(domain_strings) do
    Enum.reduce_while(domain_strings, {:ok, []}, fn ds, {:ok, acc} ->
      mod = Module.concat([ds])

      case Code.ensure_compiled(mod) do
        {:module, ^mod} -> {:cont, {:ok, acc ++ [mod]}}
        _ -> {:halt, {:error, "Domain module #{inspect(mod)} could not be compiled/loaded."}}
      end
    end)
  end

  defp configured(app) do
    case Application.get_env(:ash, :domains) do
      domains when is_list(domains) ->
        domains

      _ ->
        case Application.get_env(app, :ash_domains) do
          domains when is_list(domains) -> domains
          _ -> []
        end
    end
  end
end

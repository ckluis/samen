defmodule Samen.Approvals.Registry do
  @moduledoc """
  The E3 **kind registry** (ADR-040 §4.4). A config-resolved map
  `kind => {plane, handler_module}` — registration fixes the **plane**
  (`:tenant | :operator`, INV-2 §4.5) and the **handler module** for a kind.
  Unregistered kinds are refused at write (`Samen.Approvals.request/2`), so a caller can
  never open an approval no one can decide, and a kind is never decidable cross-plane.

  ## Wiring (host-configured seam)

      config :samen_core, Samen.Approvals.Registry,
        kinds: %{
          # Face 1 (kernel/non-Ash clients, e.g. reveal in T35):
          "pii_reveal" => {:operator, Samen.Reveal.ApprovalHandler},
          # Face 2 (gated Ash actions) route to the generic Gate handler; the kind
          # string is "<resource-module>:<action>" so the Gate handler can re-derive
          # the resource + action to re-invoke (ADR-040 §4.4 Face 2).
          "Elixir.MyApp.Doc:publish" => {:tenant, Samen.Approvals.Gate}
        }

  Opts win over config (the `Notifications.Engine` convention), so a test can inject a
  registry without touching application env.
  """

  @type plane :: :tenant | :operator
  @type kind :: String.t()

  @doc """
  Resolve `kind` to `{:ok, {plane, handler_module}}` or `{:error, :unregistered_kind}`.
  Called at write time (request) and at decision time (approve/reject).
  """
  @spec resolve(kind(), keyword()) :: {:ok, {plane(), module()}} | {:error, :unregistered_kind}
  def resolve(kind, opts \\ []) when is_binary(kind) do
    case Map.get(kinds(opts), kind) do
      {plane, handler} when plane in [:tenant, :operator] and is_atom(handler) ->
        {:ok, {plane, handler}}

      _ ->
        {:error, :unregistered_kind}
    end
  end

  @doc "The plane a kind is decided on, or `nil` if unregistered."
  @spec plane(kind(), keyword()) :: plane() | nil
  def plane(kind, opts \\ []) do
    case resolve(kind, opts) do
      {:ok, {plane, _}} -> plane
      _ -> nil
    end
  end

  @doc "The handler module for a kind, or `nil` if unregistered."
  @spec handler(kind(), keyword()) :: module() | nil
  def handler(kind, opts \\ []) do
    case resolve(kind, opts) do
      {:ok, {_, handler}} -> handler
      _ -> nil
    end
  end

  @doc "The full registered kind map (opts win over config)."
  @spec kinds(keyword()) :: %{kind() => {plane(), module()}}
  def kinds(opts \\ []) do
    Keyword.get(opts, :kinds) || Keyword.get(config(), :kinds, %{})
  end

  defp config, do: Application.get_env(:samen_core, __MODULE__, [])
end

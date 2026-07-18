defmodule Samen.Web.Settings.Live do
  @moduledoc """
  Shared chrome for the framework SETTINGS LiveViews (WS-E E5; ADR-029) — the sidebar
  nav across the three settings sub-surfaces (Profile · API keys · Security) and the
  small plane helpers each surface reads. Mirrors `Samen.Web.Files.Live`.
  """
  use Phoenix.Component

  import Samen.UI, only: [sidebar: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @doc "Is this mount rendering on the operator (impersonation) plane?"
  def operator_plane?(%Mount{plane: %{kind: :operator}}), do: true
  def operator_plane?(_), do: false

  attr :mount, Mount, default: nil
  attr :org_id, :string, default: nil
  attr :active, :atom, default: :profile
  attr :user_id, :string, default: nil

  @doc "The settings sidebar with the three sub-surface nav links."
  def settings_sidebar(assigns) do
    ~H"""
    <.sidebar
      title={CurrentOrg.name(@mount, @org_id)}
      subtitle="Settings"
      logo={Mount.label(@mount, :glyph, "S")}
    >
      <nav class="module-nav" aria-label="Settings">
        <a href={href("/settings", @org_id, @user_id)} class={nav_class(@active, :profile)} id="settings-nav-profile">
          Profile
        </a>
        <a href={href("/settings/api-keys", @org_id, @user_id)} class={nav_class(@active, :api_keys)} id="settings-nav-api-keys">
          API keys
        </a>
        <a href={href("/settings/security", @org_id, @user_id)} class={nav_class(@active, :security)} id="settings-nav-security">
          Security
        </a>
      </nav>
    </.sidebar>
    """
  end

  defp nav_class(active, active), do: "module-nav-item on"
  defp nav_class(_active, _item), do: "module-nav-item"

  defp href(path, org_id, user_id) do
    query =
      [org: org_id, user: user_id]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> URI.encode_query()

    if query == "", do: path, else: "#{path}?#{query}"
  end
end

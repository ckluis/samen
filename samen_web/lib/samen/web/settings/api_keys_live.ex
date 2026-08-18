defmodule Samen.Web.Settings.ApiKeysLive do
  @moduledoc """
  The framework API-KEYS settings LiveView (WS-E E5.2; ADR-029; AC-G18-3/4) — mounted
  at `/settings/api-keys` by `Samen.Web.Router.samen_settings_routes/3`.

  List own org's keys · mint (show-once) · revoke, over `Samen.Web.Settings.ApiKeys`.
  The raw key is shown EXACTLY ONCE in the mint response and never again — the DB
  stores only `token_digest`. Minted authority is bounded by the minter's role ceiling
  (`effective_scopes/2`). Mint/revoke are tenant-plane, admin-gated (the `ApiKey` create
  policy); an operator-plane view is read-only.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Settings.Live, only: [settings_sidebar: 1, operator_plane?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.Settings.ApiKeys
  alias Samen.Web.Settings.Reads

  @impl true
  def mount(params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    mount = socket.assigns[:samen_mount]
    org_id = CurrentOrg.resolve(mount, params, session)
    user_id = Reads.current_user_id(mount, params, session)

    {:ok,
     socket
     |> assign(return_to: nil, minted_key: nil, mint_error: nil)
     |> load(org_id, user_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    user_id = Samen.Web.Settings.Reads.reresolve_user(socket, params)

    {:noreply,
     socket
     |> assign(return_to: return_path(uri))
     |> load(org_id, user_id)}
  end

  @doc false
  def load(socket, org_id, user_id) do
    mount = socket.assigns.samen_mount
    socket = assign(socket, org_id: org_id, user_id: user_id, keys: [])

    if is_nil(org_id) do
      socket
    else
      scope = Mount.scope(mount, org_id)
      assign(socket, keys: ApiKeys.list(mount, scope))
    end
  end

  @impl true
  def handle_event("mint", %{"key" => params}, socket) do
    %{samen_mount: mount, org_id: org_id, user_id: user_id} = socket.assigns

    if operator_plane?(mount) do
      {:noreply, assign(socket, mint_error: "API keys are minted on the tenant plane.")}
    else
      do_mint(socket, mount, org_id, user_id, params)
    end
  end

  def handle_event("revoke", %{"id" => key_id}, socket) do
    %{samen_mount: mount, org_id: org_id, user_id: user_id} = socket.assigns

    if operator_plane?(mount) do
      {:noreply, socket}
    else
      # PP-6 (Batch 2 TENANT-ROLE): revoke sets `revoked_at` via the admin-gated `ApiKey.:update`
      # policy (`RoleAtLeast(:admin)`). Resolve the REAL per-org membership role — the SAME
      # pattern `do_mint/5` already uses in this file — instead of the synthetic `:member`
      # `Mount.scope/2` default. With the real role a genuine admin/owner CAN revoke a
      # leaked key; a member is correctly denied. (Previously the hardcoded `:member` scope
      # silently DENIED every revoke, for every role including owners.)
      with {:ok, membership} <- membership(mount, org_id, user_id) do
        scope = admin_scope(user_id, org_id, membership.role)
        _ = ApiKeys.revoke(mount, scope, key_id)
      end

      {:noreply, load(assign(socket, minted_key: nil), org_id, user_id)}
    end
  end

  def handle_event("dismiss_key", _params, socket) do
    {:noreply, assign(socket, minted_key: nil)}
  end

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:minted_key, fn -> nil end)
      |> assign_new(:mint_error, fn -> nil end)

    ~H"""
    <div id="settings-api-keys">
      <.app_shell>
        <:sidebar>
          <.settings_sidebar mount={@samen_mount} org_id={@org_id} user_id={@user_id} active={:api_keys} />
        </:sidebar>

        <.topbar title="API keys" crumbs={[CurrentOrg.name(@samen_mount, @org_id), "Settings", "API keys"]}>
          <:actions></:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if is_nil(@org_id) do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <div class="wrap">
            <div id="api-keys-panel">
              <%= if @minted_key do %>
                <div id="api-key-minted" style="border:1px solid #15803D;padding:12px;border-radius:6px;margin-bottom:14px">
                  <strong>Copy your new key now — it is shown only once.</strong>
                  <pre id="api-key-raw" style="margin:8px 0;user-select:all">{@minted_key.raw}</pre>
                  <button type="button" phx-click="dismiss_key" class="btn" id="api-key-dismiss">Done</button>
                </div>
              <% end %>

              <p :if={@mint_error} id="api-key-error" style="color:#B91C1C">{@mint_error}</p>

              <%= if not operator_plane?(@samen_mount) do %>
                <form id="api-key-mint-form" phx-submit="mint" style="margin-bottom:16px">
                  <fieldset style="border:0;padding:0">
                    <legend style="font-weight:600;font-size:13px">Mint a key</legend>
                    <label style="margin-right:12px">
                      <input type="checkbox" name="key[read]" value="1" checked /> read
                    </label>
                    <label style="margin-right:12px">
                      <input type="checkbox" name="key[write]" value="1" /> write
                    </label>
                    <.button type="submit" variant="primary" id="api-key-mint">Mint key</.button>
                  </fieldset>
                  <p style="color:var(--muted);font-size:12px;margin-top:4px">
                    Authority is bounded by your role — a viewer cannot mint a write key.
                  </p>
                </form>
              <% else %>
                <p id="api-key-operator-note" style="color:var(--muted)">
                  Minting and revoking are tenant-plane actions.
                </p>
              <% end %>

              <table id="api-keys-table" class="tbl">
                <thead>
                  <tr>
                    <th scope="col">Key</th>
                    <th scope="col">Plane</th>
                    <th scope="col">Scopes</th>
                    <th scope="col">Minter role</th>
                    <th scope="col">Status</th>
                    <th scope="col"></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={k <- @keys} class="api-key-row" id={"api-key-#{k.id}"}>
                    <td><code>{k.digest_prefix}…</code></td>
                    <td>{k.plane}</td>
                    <td style="font-size:12px">{format_scopes(k.scopes)}</td>
                    <td>{k.minter_role}</td>
                    <td>
                      <span class={if k.revoked?, do: "status-pill status-revoked", else: "status-pill status-active"}>
                        {if k.revoked?, do: "revoked", else: "active"}
                      </span>
                    </td>
                    <td>
                      <button
                        :if={not k.revoked? and not operator_plane?(@samen_mount)}
                        type="button"
                        phx-click="revoke"
                        phx-value-id={k.id}
                        class="btn"
                        id={"api-key-revoke-#{k.id}"}
                      >
                        Revoke
                      </button>
                    </td>
                  </tr>
                  <tr :if={@keys == []}>
                    <td colspan="6" style="color:var(--muted)">No API keys yet.</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- private -----------------------------------------------------------------

  defp do_mint(socket, mount, org_id, user_id, params) do
    with {:ok, membership} <- membership(mount, org_id, user_id),
         scope <- admin_scope(user_id, org_id, membership.role),
         {:ok, raw, row} <-
           ApiKeys.mint(mount, scope,
             membership_id: membership.id,
             minter_role: membership.role,
             plane: :tenant,
             scopes: requested_scopes(params)
           ) do
      {:noreply,
       socket
       |> assign(
         minted_key: %{raw: raw, digest_prefix: String.slice(row.token_digest, 0, 12)},
         mint_error: nil
       )
       |> load(org_id, user_id)}
    else
      {:error, :not_found} ->
        {:noreply, assign(socket, mint_error: "No membership in context — cannot mint.")}

      {:error, _reason} ->
        {:noreply, assign(socket, mint_error: "Mint refused (admin role required).")}
    end
  end

  defp membership(mount, org_id, user_id) when is_binary(org_id) and is_binary(user_id) do
    scope = Mount.scope(mount, org_id)
    Reads.current_membership(mount, scope, user_id, org_id)
  end

  defp membership(_mount, _org_id, _user_id), do: {:error, :not_found}

  # The current admin's own actor — a tenant-plane scope carrying the membership role,
  # so the ApiKey create policy (admin+) sees the real minter authority.
  defp admin_scope(user_id, org_id, role) do
    %Samen.Scope{
      actor: %{
        id: user_id,
        org_id: org_id,
        role: role,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  defp requested_scopes(params) do
    actions =
      [{"read", :read}, {"write", :write}]
      |> Enum.filter(fn {k, _} -> Map.get(params, k) in ["1", "true", "on"] end)
      |> Enum.map(&elem(&1, 1))

    if actions == [], do: %{}, else: %{all: actions}
  end

  defp format_scopes(scopes) when scopes == %{}, do: "—"

  defp format_scopes(scopes) when is_map(scopes) do
    Enum.map_join(scopes, "; ", fn {family, actions} ->
      "#{family}: #{Enum.map_join(actions, ",", &to_string/1)}"
    end)
  end

  defp format_scopes(_), do: "—"
end

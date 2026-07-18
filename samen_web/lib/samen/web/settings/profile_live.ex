defmodule Samen.Web.Settings.ProfileLive do
  @moduledoc """
  The framework PROFILE settings LiveView (WS-E E5.1; ADR-029; AC-G18-2) — mounted at
  `/settings` (+ `/settings/profile`) by `Samen.Web.Router.samen_settings_routes/3`.
  Zero authored settings LiveViews per vertical.

  ## The masking watch-list surface — profile self-edit of own vaulted PII

  A user edits their OWN `full_name`/`emails`/`handle`. The edit is submitted through
  `Samen.Web.Settings.Profile.update/4`, which routes the write through the governed
  `User` update action — `Samen.Pii.WriteGuard` + `Samen.Vault.Change`:

    * **tenant plane** — the write is permitted and vault-routed (`vt_*` at rest);
    * **operator plane (impersonation)** — `WriteGuard` REFUSES a plaintext PII write.
      The kit `form_field/1` ALSO renders a `%Masked{}` value read-only with NO `name`
      (so the masked field cannot even submit) — the render half of the guarantee — and
      the write path is the enforcement half. Sabotaging the chokepoint FAILS the
      per-plane vault red-path (`profile_masking_test.exs` · RP-ST-1).

  Auth is host-owned: the current user is resolved via
  `Samen.Web.Settings.Reads.current_user_id/3` (param → session → host mount label),
  never invented by the framework.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Settings.Live, only: [settings_sidebar: 1, operator_plane?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Masked
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.Settings.Profile
  alias Samen.Web.Settings.Reads

  @impl true
  def mount(params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    mount = socket.assigns[:samen_mount]
    org_id = CurrentOrg.resolve(mount, params, session)
    user_id = Reads.current_user_id(mount, params, session)

    {:ok, load(assign(socket, return_to: nil, flash_ok: nil), org_id, user_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    user_id = Map.get(params, "user") || socket.assigns.user_id

    {:noreply,
     socket
     |> assign(return_to: return_path(uri))
     |> load(org_id, user_id)}
  end

  @doc false
  def load(socket, org_id, user_id) do
    mount = socket.assigns.samen_mount
    assigns = %{org_id: org_id, user_id: user_id, user: nil, form: blank_form()}

    socket = assign(socket, assigns)

    cond do
      is_nil(org_id) or is_nil(user_id) ->
        socket

      true ->
        scope = Mount.scope(mount, org_id)

        case Reads.get_user(mount, scope, user_id) do
          {:ok, user} -> assign(socket, user: user, form: profile_form(user))
          {:error, _} -> socket
        end
    end
  end

  @impl true
  def handle_event("save", %{"profile" => params}, socket) do
    %{samen_mount: mount, org_id: org_id, user_id: user_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    case Profile.update(mount, scope, user_id, attrs_from_params(params)) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> assign(flash_ok: "Profile saved.")
         |> load(org_id, user_id)}

      {:error, _reason} ->
        # An operator-plane plaintext PII write is refused HERE by WriteGuard (the DB
        # unchanged) — surfaced honestly, never silently swallowed.
        {:noreply, assign(socket, flash_ok: nil, save_error: "This change was refused on this plane.")}
    end
  end

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:save_error, fn -> nil end)
      |> assign_new(:flash_ok, fn -> nil end)

    ~H"""
    <div id="settings-profile">
      <.app_shell>
        <:sidebar>
          <.settings_sidebar mount={@samen_mount} org_id={@org_id} user_id={@user_id} active={:profile} />
        </:sidebar>

        <.topbar title="Profile" crumbs={[CurrentOrg.name(@samen_mount, @org_id), "Settings", "Profile"]}>
          <:actions></:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= cond do %>
          <% is_nil(@org_id) -> %>
            <.no_org_card mount={@samen_mount} />

          <% is_nil(@user_id) or is_nil(@user) -> %>
            <div class="wrap">
              <div class="card" id="settings-no-user" style="padding:22px 20px;color:var(--muted)">
                <div style="font-weight:600;color:#2a2b35;margin-bottom:6px">No user in context</div>
                <p style="margin:0">
                  The settings surfaces read the current user from your identity provider
                  (the host wires it); none is set here.
                </p>
              </div>
            </div>

          <% true -> %>
            <div class="wrap">
              <div id="settings-profile-panel">
                <div class="gtitle">
                  <h3>Your profile</h3>
                  <span class="lane">{plane_note(@samen_mount)}</span>
                </div>

                <p :if={@flash_ok} id="settings-profile-ok" style="color:#15803D;margin:8px 0">{@flash_ok}</p>
                <p :if={@save_error} id="settings-profile-error" style="color:#B91C1C;margin:8px 0">{@save_error}</p>

                <.simple_form for={@form} id="settings-profile-form" phx-submit="save">
                  <.form_field field={@form[:handle]} label="Handle" />

                  <%= if operator_plane?(@samen_mount) do %>
                    <.form_field field={@form[:full_name]} label="Full name" />
                    <.form_field field={@form[:emails]} label="Email" />
                  <% else %>
                    <.form_field field={@form[:first]} label="First name" />
                    <.form_field field={@form[:last]} label="Last name" />
                    <.form_field field={@form[:email]} label="Email" type="email" />
                  <% end %>

                  <:actions>
                    <.button type="submit" variant="primary" id="settings-profile-save">Save</.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- form plumbing -----------------------------------------------------------

  defp blank_form, do: to_form(%{}, as: :profile)

  # Build the form values from the plane-resolved user. On the operator plane the
  # vaulted composites come back as %Masked{} — placed verbatim so form_field/1 renders
  # its read-only •••• branch (no name attr → cannot submit plaintext).
  defp profile_form(user) do
    base = %{"handle" => to_form_value(user.handle)}

    fields =
      case {user.full_name, user.emails} do
        {%Masked{} = name, emails} ->
          %{"full_name" => name, "emails" => masked_or(emails)}

        {name, emails} ->
          # The revealed composite arrives in its JSON-serialized vault form (the E3
          # ship-note posture); decode it to split into editable first/last/email.
          decoded_name = decode_composite(name)
          decoded_emails = decode_composite(emails)

          %{
            "first" => to_form_value(first_of(decoded_name)),
            "last" => to_form_value(last_of(decoded_name)),
            "email" => to_form_value(primary_email(decoded_emails))
          }
      end

    to_form(Map.merge(base, fields), as: :profile)
  end

  defp masked_or(%Masked{} = m), do: m
  defp masked_or(_), do: %Masked{token: "vt_masked", label: :emails}

  # A revealed composite vault value is a JSON string (`{"first":…}` / `[{"address":…}]`).
  # Decode it; leave a %Masked{}/struct/nil untouched.
  defp decode_composite(%Masked{} = m), do: m

  defp decode_composite(<<c, _::binary>> = v) when c in [?{, ?[] do
    case Jason.decode(v) do
      {:ok, decoded} -> decoded
      _ -> v
    end
  end

  defp decode_composite(other), do: other

  defp attrs_from_params(params) do
    handle = Map.get(params, "handle")

    # The masked (operator) branch submits no first/last/email names, so only :handle
    # rides through — a non-PII edit. The tenant branch carries the composite parts.
    base = if is_binary(handle), do: %{handle: handle}, else: %{}

    base
    |> maybe_full_name(params)
    |> maybe_emails(params)
  end

  defp maybe_full_name(attrs, %{"first" => first, "last" => last}),
    do: Map.put(attrs, :full_name, %{first: blank_nil(first), last: blank_nil(last)})

  defp maybe_full_name(attrs, _), do: attrs

  defp maybe_emails(attrs, %{"email" => email}) when is_binary(email) do
    case blank_nil(email) do
      nil -> attrs
      addr -> Map.put(attrs, :emails, [%{address: addr}])
    end
  end

  defp maybe_emails(attrs, _), do: attrs

  defp blank_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_nil(_), do: nil

  defp to_form_value(nil), do: ""
  defp to_form_value(v) when is_binary(v), do: v
  defp to_form_value(v), do: to_string(v)

  defp first_of(%{first: first}), do: first
  defp first_of(%{"first" => first}), do: first
  defp first_of(_), do: nil
  defp last_of(%{last: last}), do: last
  defp last_of(%{"last" => last}), do: last
  defp last_of(_), do: nil

  defp primary_email(%Samen.Type.Emails{entries: [%{address: addr} | _]}), do: addr
  defp primary_email(%{entries: [%{address: addr} | _]}), do: addr
  defp primary_email([%{address: addr} | _]), do: addr
  defp primary_email([%{"address" => addr} | _]), do: addr
  defp primary_email(_), do: nil

  defp plane_note(%Mount{plane: %{kind: :operator}}),
    do: "operator plane · vaulted fields masked, plaintext writes refused"

  defp plane_note(_), do: "your account · edit your own profile"
end

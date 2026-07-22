defmodule Samen.Web.Onboarding.WizardLive do
  @moduledoc """
  The framework FIRST-RUN ONBOARDING WIZARD (ADR-035 §5 A8; spec §WS-A A8;
  T08). Mounted at `/onboarding` by `Samen.Web.Router.samen_onboarding_routes/2`
  — tenant plane (ADR-035 §6: own-org writes only), re-entrant, entered after
  first verified sign-in.

  Three framework steps, every generated app inherits the SAME seam:

    1. **Org naming** — writes `Org.name` (`Samen.Web.Onboarding.name_org/4`).
    2. **Plan selection** — the WS-B billing HOOK
       (`Samen.Web.Onboarding.plan_choices/2`): renders real choices when a
       host wires `Mount.label(mount, :plan_labels, {mod, fun, args})`, else
       the HONEST `no_plans_copy/0` empty state — never a fabricated plan
       list (INV-4 spirit).
    3. **Teammate invite** — the A5 surface embedded: this LiveView calls
       `Samen.Web.Settings.Invitations.create/4`, the SAME engine
       `InvitationsLive` calls. No invite logic is reinvented here.

  Every step is SKIPPABLE — the wizard's job is to offer a good default path,
  never to block first use. Each step's write lands immediately (org name /
  plan / invitation rows are ordinary per-org persisted state, not held in
  wizard-local memory), so leaving mid-wizard loses nothing already
  submitted.

  Completing (`"finish"`) calls `Samen.Web.Onboarding.complete!/3`, which
  sets the Tier-0 `Org.onboarded_at` marker. On any LATER visit `load/3`
  re-checks `Onboarding.needed?/3` off that same column and renders the
  "already set up" card instead of the step forms — the wizard never
  re-traps (ADR-035 §5 A8's own moduledoc). Completing lands the actor on
  the plane's landing view in a real host wiring, where the existing
  `Samen.Web.FirstRun` "no data yet" checklist takes over — complementary,
  not duplicated (ADR-035 §5 A8).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.Onboarding
  alias Samen.Web.Settings.Invitations
  alias Samen.Web.Settings.Reads

  @impl true
  def mount(params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    mount = socket.assigns[:samen_mount]
    org_id = CurrentOrg.resolve(mount, params, session)
    user_id = Reads.current_user_id(mount, params, session)

    {:ok,
     socket
     |> assign(step: :org, org_error: nil, invite_error: nil, invited_raw_token: nil, samen_session: session)
     |> load(org_id, user_id)}
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

    socket =
      socket
      |> assign_new(:step, fn -> :org end)
      |> assign(org_id: org_id, user_id: user_id, return_to: Map.get(socket.assigns, :return_to))

    if is_nil(org_id) do
      assign(socket, complete?: false, org: nil, org_form: blank_org_form(), plan_choices: :not_configured)
    else
      scope = Mount.scope(mount, org_id)
      complete? = not Onboarding.needed?(mount, scope, org_id)

      org =
        case Onboarding.org(mount, scope, org_id) do
          {:ok, org} -> org
          {:error, _} -> nil
        end

      assign(socket,
        complete?: complete?,
        org: org,
        org_form: org_form(org),
        plan_choices: Onboarding.plan_choices(mount, org_id)
      )
    end
  end

  # -- step 1: org naming ------------------------------------------------------

  @impl true
  def handle_event("name_org", %{"org" => %{"name" => name}}, socket) do
    %{samen_mount: mount, org_id: org_id, user_id: user_id} = socket.assigns
    name = String.trim(name || "")

    case Onboarding.name_org(mount, actor_scope(mount, org_id, user_id), org_id, name) do
      {:ok, _org} ->
        {:noreply, socket |> assign(step: :plan, org_error: nil) |> load(org_id, user_id)}

      {:error, _reason} ->
        {:noreply, assign(socket, org_error: "Could not save the workspace name — try a shorter one.")}
    end
  end

  def handle_event("skip_org", _params, socket) do
    {:noreply, assign(socket, step: :plan)}
  end

  # -- step 2: plan selection (the WS-B hook) ----------------------------------

  def handle_event("select_plan", %{"plan" => %{"key" => key}}, socket) do
    %{samen_mount: mount, org_id: org_id, user_id: user_id} = socket.assigns

    case Onboarding.select_plan(mount, actor_scope(mount, org_id, user_id), org_id, key) do
      {:ok, _org} -> {:noreply, socket |> assign(step: :invite) |> load(org_id, user_id)}
      {:error, _reason} -> {:noreply, assign(socket, org_error: "Could not save the plan selection.")}
    end
  end

  def handle_event("skip_plan", _params, socket) do
    {:noreply, assign(socket, step: :invite)}
  end

  # -- step 3: teammate invite (the A5 surface, embedded) ----------------------

  def handle_event("invite", %{"invitation" => params}, socket) do
    %{samen_mount: mount, org_id: org_id, user_id: user_id, samen_session: session} = socket.assigns

    with {:ok, membership} <- membership(mount, org_id, user_id),
         scope <- invite_scope(user_id, org_id, membership.role, verified?(mount, session)),
         {:ok, _invitation, raw_token} <-
           Invitations.create(mount, scope, Map.get(params, "email", ""), Map.get(params, "role", "member")) do
      {:noreply, assign(socket, invited_raw_token: raw_token, invite_error: nil)}
    else
      {:error, :not_found} ->
        {:noreply, assign(socket, invite_error: "No membership in context — cannot invite.")}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           invite_error: "Invite refused (admin role required, verified account required, or the invited role outranks yours)."
         )}
    end
  end

  def handle_event("finish", _params, socket) do
    %{samen_mount: mount, org_id: org_id, user_id: user_id} = socket.assigns
    _ = Onboarding.complete!(mount, actor_scope(mount, org_id, user_id), org_id)
    {:noreply, load(socket, org_id, user_id)}
  end

  # -- private -------------------------------------------------------------

  defp blank_org_form, do: to_form(%{"name" => ""}, as: :org)
  defp org_form(nil), do: blank_org_form()
  defp org_form(%{name: name}), do: to_form(%{"name" => name || ""}, as: :org)

  defp membership(mount, org_id, user_id) when is_binary(org_id) and is_binary(user_id) do
    scope = Mount.scope(mount, org_id)
    Reads.current_membership(mount, scope, user_id, org_id)
  end

  defp membership(_mount, _org_id, _user_id), do: {:error, :not_found}

  # A plain own-org actor for the org-naming/plan-selection writes — `Org`'s
  # own policy (`OrgIsSelf`) checks only `actor.org_id == org.id`, no rank
  # ceiling, so the real membership role is not required here the way the
  # invite ceiling needs it (`invite_scope/4` below carries the real role).
  defp actor_scope(_mount, org_id, user_id) do
    %Samen.Scope{actor: %{id: user_id, org_id: org_id, role: :member, kind: :tenant, plane: :tenant, verified?: true}}
  end

  # The SAME "real inviter authority" scope `InvitationsLive` builds — carries
  # the caller's REAL membership role so the `Invitation.:create` rank-ceiling
  # policy sees genuine authority, not a hardcoded `:member`.
  defp invite_scope(user_id, org_id, role, verified?) do
    %Samen.Scope{
      actor: %{id: user_id, org_id: org_id, role: role, kind: :tenant, plane: :tenant, verified?: verified?}
    }
  end

  defp verified?(mount, session) do
    session_mod = Mount.resource(mount, Session)

    case Samen.Web.Auth.resolve_principal(session, %{session: session_mod}) do
      {:ok, %{credential_id: credential_id}} ->
        case Ash.get(Mount.resource(mount, Credential), credential_id, authorize?: false) do
          {:ok, %{verified_at: v}} -> not is_nil(v)
          _ -> false
        end

      _ ->
        true
    end
  rescue
    _ -> true
  end

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:org_error, fn -> nil end)
      |> assign_new(:invite_error, fn -> nil end)
      |> assign_new(:invited_raw_token, fn -> nil end)
      |> assign_new(:samen_acting_as, fn -> false end)

    ~H"""
    <div id="onboarding" class="wrap" style="max-width:480px;margin:60px auto">
      <%= cond do %>
        <% is_nil(@org_id) -> %>
          <.no_org_card mount={@samen_mount} />
        <% @complete? -> %>
          <div id="onboarding-already-done" class="card" style="padding:28px 24px">
            <h2 style="margin:0 0 4px">You're all set</h2>
            <p style="margin:0;color:var(--muted)">
              Setup is already complete for {CurrentOrg.name(@samen_mount, @org_id)} — nothing left to do here.
            </p>
          </div>
        <% true -> %>
          <div id="onboarding-wizard" class="card" style="padding:28px 24px">
            <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />
            <h2 style="margin:0 0 4px">Set up your workspace</h2>
            <p style="margin:0 0 18px;color:var(--muted)">Three quick steps — skip any of them.</p>

            <div :if={@step == :org} id="onboarding-step-org">
              <p :if={@org_error} id="onboarding-org-error" style="color:#B91C1C">{@org_error}</p>
              <.simple_form for={@org_form} id="onboarding-org-form" phx-submit="name_org">
                <.form_field field={@org_form[:name]} label="Workspace name" required />
                <:actions>
                  <.button type="submit" variant="primary" id="onboarding-org-submit">Continue</.button>
                  <button type="button" phx-click="skip_org" id="onboarding-org-skip" class="btn">Skip</button>
                </:actions>
              </.simple_form>
            </div>

            <div :if={@step == :plan} id="onboarding-step-plan">
              <p :if={@org_error} id="onboarding-plan-error" style="color:#B91C1C">{@org_error}</p>
              <%= case @plan_choices do %>
                <% {:ok, choices} -> %>
                  <form id="onboarding-plan-form" phx-submit="select_plan" style="margin-bottom:12px">
                    <fieldset style="border:0;padding:0">
                      <legend style="font-weight:600;font-size:13px">Choose a plan</legend>
                      <div :for={c <- choices} style="margin:6px 0">
                        <label>
                          <input type="radio" name="plan[key]" value={c.key} id={"onboarding-plan-#{c.key}"} required />
                          {c.label}
                        </label>
                      </div>
                    </fieldset>
                    <.button type="submit" variant="primary" id="onboarding-plan-submit">Continue</.button>
                  </form>
                <% :not_configured -> %>
                  <p id="onboarding-plan-empty" style="color:var(--muted)">{Onboarding.no_plans_copy()}</p>
              <% end %>
              <button type="button" phx-click="skip_plan" id="onboarding-plan-skip" class="btn">Skip</button>
            </div>

            <div :if={@step == :invite} id="onboarding-step-invite">
              <p :if={@invited_raw_token} id="onboarding-invite-sent" style="color:#15803D">
                Invite sent — copy this link (shown once): <code>/invite/{@invited_raw_token}</code>
              </p>
              <p :if={@invite_error} id="onboarding-invite-error" style="color:#B91C1C">{@invite_error}</p>

              <form id="onboarding-invite-form" phx-submit="invite" style="margin-bottom:16px">
                <fieldset style="border:0;padding:0">
                  <legend style="font-weight:600;font-size:13px">Invite a teammate</legend>
                  <input type="email" name="invitation[email]" placeholder="teammate@example.com" required id="onboarding-invite-email" />
                  <select name="invitation[role]" id="onboarding-invite-role">
                    <option value="member" selected>member</option>
                    <option value="admin">admin</option>
                    <option value="viewer">viewer</option>
                  </select>
                  <.button type="submit" variant="primary" id="onboarding-invite-submit">Send invite</.button>
                </fieldset>
              </form>

              <.button type="button" phx-click="finish" variant="primary" id="onboarding-finish">Finish setup</.button>
            </div>
          </div>
      <% end %>
    </div>
    """
  end
end

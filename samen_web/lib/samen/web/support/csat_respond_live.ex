defmodule Samen.Web.Support.CsatRespondLive do
  @moduledoc """
  I6 (spec §I6, T79) — the UNAUTHENTICATED CSAT survey-response page, mounted
  at `GET /support/csat/:token` (`samen_module_routes :csat, Host.Support,
  repo: ...`, mirroring `:kb`'s public-portal posture — no auth
  pipeline/on_mount, no session-derived org). The token in the URL path IS the
  entire authorization surface (a 256-bit secret) — org/ticket/agent are
  derived FROM the token match (`Samen.Scopes.Support.CsatSurvey`), NEVER from
  a client-supplied org param.

  ## Honest states

    * valid, pending token → the 1..5 score form (+ optional comments)
    * invalid / expired / already-used token → "This link is no longer
      valid." (ONE generic message — no oracle distinguishing WHY, mirroring
      `Samen.Identity.Invite`/`Confirm`'s anti-replay-oracle posture)
    * after submit → "Thanks for your feedback." (never re-shows the form —
      the token is single-use; reloading the page re-derives the SAME
      already-consumed state via `preview/2` and shows the SAME "no longer
      valid" message, not a duplicate-submission form)

  ## Why there is no double-mount consume risk (unlike `ConfirmLive`)

  `ConfirmLive`'s `GET /verify/:token` consumes the token IN `mount/3` (the
  visit itself IS the action) — T126/ADR-042 had to add a double-mount guard
  for that shape. A CSAT response is inherently POST-shaped (the score is
  user input the visitor chooses): `mount/3` here only PREVIEWS
  (non-mutating, `CsatSurvey.preview/2`); the WRITE
  (`CsatSurvey.respond/4`) fires exclusively from `handle_event("submit_survey",
  ...)`, so a dead+connected double-mount never double-consumes anything.
  """
  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Web.Live, as: SamenLive
  alias Samen.Web.Mount
  alias Samen.Scopes.Support.CsatSurvey

  @impl true
  def mount(%{"token" => token}, session, socket) do
    socket = SamenLive.assign_mount(socket, session)

    {:ok,
     socket
     |> assign(token: token, score: nil, comments: "", error: nil)
     |> assign(state: preview_state(socket.assigns[:samen_mount], token))}
  end

  @impl true
  def handle_event("submit_survey", params, socket) do
    mount = socket.assigns[:samen_mount]
    score = parse_score(Map.get(params, "score"))
    comments = params |> Map.get("comments") |> to_string() |> String.trim() |> nilify()

    case score && mount && CsatSurvey.respond(mods(mount), socket.assigns.token, score, comments) do
      {:ok, _csat} ->
        {:noreply, assign(socket, state: :thanks, error: nil)}

      {:error, :invalid_token} ->
        {:noreply, assign(socket, state: :invalid, error: nil)}

      {:error, :invalid_score} ->
        {:noreply, assign(socket, error: "Pick a score from 1 to 5.")}

      _ ->
        {:noreply, assign(socket, error: "Pick a score from 1 to 5.")}
    end
  end

  # -- private ------------------------------------------------------------------

  defp preview_state(nil, _token), do: :invalid

  defp preview_state(mount, token) do
    case CsatSurvey.preview(mods(mount), token) do
      {:ok, _} -> :form
      {:error, :invalid_token} -> :invalid
    end
  end

  defp mods(mount) do
    %{
      csat_survey_token: Mount.resource(mount, CsatSurveyToken),
      csat: Mount.resource(mount, Csat)
    }
  end

  defp parse_score(score) when is_binary(score) do
    case Integer.parse(score) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_score(score) when is_integer(score), do: score
  defp parse_score(_), do: nil

  defp nilify(""), do: nil
  defp nilify(s), do: s

  @impl true
  def render(assigns) do
    ~H"""
    <div id="csat-respond" class="wrap" style="max-width:520px;margin:0 auto;padding:48px 20px">
      <%= case @state do %>
        <% :form -> %>
          <div class="card" id="csat-form-card" style="padding:24px">
            <div class="gtitle" style="margin-bottom:8px"><h1 style="font-size:20px;margin:0">How did we do?</h1></div>
            <p style="font-size:13px;color:var(--muted);margin:0 0 18px">
              Your support ticket was recently resolved. We'd love to hear how it went.
            </p>

            <form id="csat-score-form" phx-submit="submit_survey">
              <div style="margin-bottom:14px">
                <label for="csat-comments" style="display:block;font-size:12px;color:var(--muted);margin-bottom:4px">
                  Comments (optional)
                </label>
                <textarea
                  id="csat-comments"
                  name="comments"
                  rows="3"
                  placeholder="Tell us more…"
                  style="width:100%;font-size:13px;padding:8px"
                >{@comments}</textarea>
              </div>

              <div :if={@error} id="csat-error" style="color:var(--bad, #b91c1c);font-size:12px;margin-bottom:8px">
                {@error}
              </div>

              <div style="font-size:12px;color:var(--muted);margin-bottom:8px">Pick a score, 1 (poor) to 5 (excellent):</div>
              <div id="csat-score-picker" style="display:flex;gap:8px">
                <.button :for={n <- 1..5} type="submit" name="score" value={n} class="csat-score-btn" style="flex:1">
                  {n}
                </.button>
              </div>
            </form>
          </div>

        <% :thanks -> %>
          <.empty_state
            class="csat-thanks"
            icon="🙏"
            title="Thanks for your feedback."
            body="Your response has been recorded."
          />

        <% :invalid -> %>
          <.empty_state
            class="csat-invalid"
            icon="🔗"
            title="This link is no longer valid."
            body="It may have already been used or expired."
          />
      <% end %>
    </div>
    """
  end
end

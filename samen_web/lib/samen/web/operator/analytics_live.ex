defmodule Samen.Web.Operator.AnalyticsLive do
  @moduledoc """
  Framework OPERATOR / Product analytics page (WS-B / B8, design §4.5; ADR-021) — the
  G12 SEED read surface every vertical inherits at 0 LOC via `samen_operator_routes/2`:

    * **Activation funnel** (signup → first-run → first-record) — cross-tenant
      orgs-reached + distinct-actor counts per stage, read through the bounded
      `Samen.Web.Operator.AnalyticsReads` over the `paf_product_event_rollup` RAW
      table (B8's rollup over the `pae` ledger — never a live event scan).

    * **4-week retention curve** — weekly signup cohorts × offsets W0–W4, the same
      bounded rollup read.

  Both sections are CROSS-TENANT, so the enforced k-anonymity floor runs at the read
  (AC-G12-6, k-anon min 5): a below-floor stage or cohort ARRIVES as
  `%Samen.Aggregate.Suppressed{}` and renders `⊘` — the framework never
  un-suppresses, and never offers a bypass affordance.

  **This is a SEED, not the analytics product** (design §4.5 + §7): one funnel, one
  retention curve — no paths, no arbitrary event exploration, no DAU/MAU dashboards,
  no ClickHouse.

  ## Masking / PII posture

  Every rendered value is a bounded stage label / week bucket / count / percentage —
  the analytics surface is not a PII surface (AC-G12-3: `pae`/`paf` carry no name,
  email, or freeform string; `pae_actor_ref` is an HMAC pseudonym and never renders
  here at all — only counts do). No `Samen.Vault` call, no `%Masked{}` branch, no
  reveal path.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  alias Samen.Web.Operator.AnalyticsReads

  @impl true
  def mount(_params, session, socket) do
    socket = assign_mount(socket, session)
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    socket =
      socket
      |> assign_new(:ask_question, fn -> nil end)
      |> assign_new(:ask_result, fn -> nil end)

    mount = socket.assigns[:samen_mount]

    socket = assign(socket, ask_available: not is_nil(ask_resource(mount)))

    case mount do
      nil ->
        assign(socket, analytics: AnalyticsReads.empty(), funnel_suppressed: 0, retention_suppressed: 0)

      mount ->
        analytics = AnalyticsReads.analytics(mount)

        assign(socket,
          analytics: analytics,
          funnel_suppressed: AnalyticsReads.funnel_suppressed(analytics.funnel),
          retention_suppressed: AnalyticsReads.retention_suppressed(analytics.retention)
        )
    end
  end

  # T149 B2b — the "ask" box wires the EXISTING kernel `Samen.AI.Analytics.ask/4` (D7, the
  # token-blind AGGREGATE-plane NL narration) into the operator UI, AUGMENTING the static
  # SEED read above. The narration runs over a host-supplied aggregate-plane projection (a
  # `use Samen.Aggregate.Resource` module) resolved from the `:analytics_ask_resource` mount
  # label; `ask/4` reads it ONLY through `Samen.Aggregate.read_all/2` (k-anon/l-diversity
  # floored, `suppress: true`), so a suppressed cohort carries no number to narrate. The
  # operator caller IS authorized for the cross-tenant read (T144 platform gate). Keyless in
  # CI (`Provider.Fake`); unconfigured outside `:test` ⇒ the honest `{:error, :not_configured}`
  # state, never a faked narration. NO Ash read on `load/1` (the `analytics_zero_ash_read`
  # invariant holds — the aggregate read fires only on the `ask` event).
  @impl true
  def handle_event("ask", %{"q" => question}, socket) do
    question = String.trim(question || "")
    mount = socket.assigns[:samen_mount]

    result =
      cond do
        question == "" -> {:error, :empty}
        is_nil(ask_resource(mount)) -> {:error, :not_configured}
        true -> ask(ask_resource(mount), question)
      end

    {:noreply, assign(socket, ask_question: question, ask_result: result)}
  end

  # The operator runs the platform analytics on an OPERATOR-plane caller — authorized for the
  # cross-tenant aggregate read (T144). The aggregate itself is still read by the singleton
  # token-blind aggregate actor inside `ask/4`; this scope only satisfies the platform-capability
  # gate + carries grounding metadata to the narration. Any raise (unreachable aggregate table on
  # a host that has not built the projection) normalizes to the honest not-configured state.
  defp ask(resource, question) do
    Samen.AI.Analytics.ask(%Samen.Scope{actor: %{plane: :operator}}, resource, question)
  rescue
    _ -> {:error, :not_configured}
  end

  defp ask_resource(nil), do: nil
  defp ask_resource(mount), do: Samen.Web.Mount.label(mount, :analytics_ask_resource, nil)

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-analytics">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:analytics} />
        </:sidebar>

        <.topbar title="Product analytics" crumbs={["Operator plane", "Analytics"]} />

        <.token_blind_bar chip="no reveal path · k-anon suppressed">
          <b>Cross-tenant floored aggregate.</b>
          Funnel and retention counts summarize HMAC-pseudonymous actors across tenant
          orgs — no <span class="mono">pii_</span> column exists on the
          <span class="mono">pae</span>/<span class="mono">paf</span> path by construction.
          A stage or cohort below the k-anonymity floor is suppressed
          (<span class="mono">⊘</span>); the framework never un-suppresses.
        </.token_blind_bar>

        <div class="wrap">
          <%!-- T149 B2b — the AI "ask" box over the token-blind aggregate plane (augments the
                static SEED below). Fail-honest: no narration is faked. --%>
          <div id="analytics-ask" class="card" style="padding:16px 20px;margin-bottom:16px">
            <div class="gtitle" style="margin:0 0 8px"><h3>Ask (AI · aggregate plane)</h3></div>
            <form phx-submit="ask" id="analytics-ask-form" style="display:flex;gap:8px;align-items:flex-start">
              <input type="text" name="q" id="analytics-ask-input" value={@ask_question || ""}
                placeholder="e.g. Which plan tier drives the most MRR?"
                style="flex:1;padding:8px 10px;border:1px solid #D0D5DD;border-radius:8px;font-size:13px" />
              <.button variant="primary" type="submit" id="analytics-ask-submit">Ask</.button>
            </form>
            <div :if={not @ask_available} id="ask-unwired" style="color:var(--muted);font-size:12px;margin-top:8px">
              No aggregate projection wired for AI narration on this host (set the
              <span class="mono">:analytics_ask_resource</span> mount label to a
              <span class="mono">use Samen.Aggregate.Resource</span> module).
            </div>
            <div :if={@ask_result} id="ask-result" style="margin-top:10px">
              {ask_answer(@ask_result)}
            </div>
          </div>

          <div id="activation-funnel">
            <div class="gtitle">
              <h3>Activation funnel</h3>
              <span class="n">{length(@analytics.funnel)}</span>
              <span class="lane">· signup → first-run → first-record · reads the paf rollup, never a live event scan</span>
            </div>
            <.empty_state
              :if={@analytics.funnel == []}
              class="funnel-empty"
              icon="≋"
              title="No product events yet."
              body="Framework choke points emit the seed events (session.signed_in, first_run.completed, record.created); they roll up here per stage once the ledger has rows."
            />
            <.data_table :if={@analytics.funnel != []}>
              <:head>
                <th style="width:40%">Stage</th>
                <th style="width:30%">Orgs reached</th>
                <th style="width:30%">Actors</th>
              </:head>
              <tr :for={row <- @analytics.funnel} class="funnel-row" id={"funnel-#{row.stage}"}>
                <td class="f-stage" style="font-weight:500;color:#3a3b45">{stage_label(row.stage)}</td>
                <td class="f-orgs" style="color:var(--muted)">{cell(row.org_count)}</td>
                <td class="f-actors">{cell(row.actor_count)}</td>
              </tr>
              <tr :if={@funnel_suppressed > 0}>
                <td colspan="3">
                  <div class="supp">
                    <svg class="lk" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="5" y="11" width="14" height="9" rx="2" /><path d="M8 11V8a4 4 0 0 1 8 0v3" /></svg>
                    {@funnel_suppressed} funnel stages below the k-anonymity floor — suppressed to prevent re-identification.
                  </div>
                </td>
              </tr>
            </.data_table>
          </div>

          <div id="retention-curve" style="margin-top:18px">
            <div class="gtitle">
              <h3>Retention · 4-week curve</h3>
              <span class="n">{length(@analytics.retention)}</span>
              <span class="lane">· weekly signup cohorts · retained % of each cohort's own actors · seed scope, W0–W4 only</span>
            </div>
            <.empty_state
              :if={@analytics.retention == []}
              class="retention-empty"
              icon="▦"
              title="No cohorts yet."
              body="Each signup week becomes a cohort once actors have product events on the ledger; the rollup materializes offsets W0–W4."
            />
            <.data_table :if={@analytics.retention != []}>
              <:head>
                <th>Cohort week</th>
                <th>Size</th>
                <th :for={offset <- 0..4}>W{offset}</th>
              </:head>
              <tr :for={c <- @analytics.retention} class="retention-row" id={"retention-#{c.cohort_week}"}>
                <td class="r-week" style="font-weight:500;color:#3a3b45">{week_label(c.cohort_week)}</td>
                <td class="r-size" style="color:var(--muted)">{cell(c.size)}</td>
                <td :for={offset <- 0..4} class="r-cell">{retention_cell(c.weeks, offset)}</td>
              </tr>
              <tr :if={@retention_suppressed > 0}>
                <td colspan="7">
                  <div class="supp">
                    <svg class="lk" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="5" y="11" width="14" height="9" rx="2" /><path d="M8 11V8a4 4 0 0 1 8 0v3" /></svg>
                    {@retention_suppressed} cohorts below the k-anonymity floor — suppressed to prevent re-identification.
                  </div>
                </td>
              </tr>
            </.data_table>
          </div>
        </div>
      </.app_shell>
    </div>
    """
  end

  # -- helpers -----------------------------------------------------------------

  # Render the AI ask result HONESTLY — the narration text on success (class "ask-narration"),
  # an honest muted status on every error (class "ask-honest"; never a faked answer).
  # `{:error, :not_configured}` is the keyless/unwired fail-honest state (Provider.Fake in CI;
  # no provider or no aggregate projection otherwise). Returns a Phoenix.Component to render.
  defp ask_answer(result) do
    assigns = %{result: result}

    ~H"""
    <div :if={ok?(@result)} class="ask-narration" style="white-space:pre-wrap;font-size:13px;color:#3a3b45">{answer_text(@result)}</div>
    <div :if={not ok?(@result)} class="ask-honest" style="color:var(--muted);font-size:12px">{honest_text(@result)}</div>
    """
  end

  defp ok?(result) do
    case result do
      {:ok, %Samen.AI.Completion{text: text}} when is_binary(text) -> true
      _ -> false
    end
  end

  defp answer_text(result) do
    case result do
      {:ok, %Samen.AI.Completion{text: text}} when is_binary(text) -> text
      _ -> ""
    end
  end

  defp honest_text(result) do
    case result do
      {:error, :empty} -> "Enter a question above."
      {:error, :not_configured} -> "AI analytics is not configured (no provider / aggregate projection wired). No narration was produced."
      {:error, :unauthorized} -> "This caller is not authorized for the cross-tenant aggregate read."
      {:error, reason} -> "AI analytics is unavailable (#{inspect(reason)}). No narration was produced."
      _ -> "No result."
    end
  end

  defp stage_label("signup"), do: "Signed in"
  defp stage_label("first_run"), do: "First run completed"
  defp stage_label("first_record"), do: "First record created"
  defp stage_label(other), do: to_string(other)

  defp week_label(%Date{} = d), do: Calendar.strftime(d, "%Y-%m-%d")
  defp week_label(other), do: to_string(other)

  # Token-blind cell rendering — a %Suppressed{} (or nil) renders ⊘, NEVER the value.
  defp cell(%Samen.Aggregate.Suppressed{}), do: "⊘"
  defp cell(nil), do: "⊘"
  defp cell(n) when is_integer(n), do: Integer.to_string(n)
  defp cell(other), do: to_string(other)

  # A suppressed cohort renders ⊘ in EVERY offset cell — the whole curve is the
  # releasable value the floor replaced; no per-cell partial release.
  defp retention_cell(%Samen.Aggregate.Suppressed{}, _offset), do: "⊘"

  defp retention_cell(weeks, offset) when is_list(weeks) do
    case Enum.find(weeks, &(&1.offset == offset)) do
      nil -> "—"
      %{rate: nil} -> "—"
      %{rate: rate} -> "#{Float.round(rate * 100, 1)}%"
    end
  end

  defp retention_cell(_, _), do: "⊘"
end

defmodule Samen.Web.FirstRun do
  @moduledoc """
  The per-plane FIRST-RUN experience (WS-A design §3.1 / AC-G5-2) — a framework helper +
  card so every vertical inherits the "new org, no data yet" moment with zero lines.

    * **Tenant plane** — `first_run?/2` detects "this org has ZERO rows across the mount's
      core resources"; the plane's landing view renders `first_run_card/1` (the designed
      checklist: *add your first contact · load sample data · invite a teammate*). Once any
      core row exists the card disappears (AC-G5-2's second half).
    * **Operator plane** — n/a by design (§3.1): the operator lands on Accounts, whose
      kit `empty_state/1` (icon + copy + the "New account" CTA) IS the operator first-run
      surface. `first_run?/2` is `false` by construction on the operator plane, so the
      tenant checklist can never render on an impersonation view.

  ## Read posture

  Detection probes are EXISTENCE probes only: `limit(1)` + `select([:id])`, org-scoped,
  through the same `scope:` the page reads with — bounded by construction (A3 posture) and
  PII-free (no field beyond the opaque id is ever selected, so there is nothing to mask
  and nothing to leak). Any probe error fails SAFE: `false` (no card), never a crash on
  the landing view.
  """
  use Phoenix.Component

  import Samen.UI, only: [button: 1]

  require Ash.Query

  alias Samen.Web.Mount

  # The "core resources" whose emptiness means "this org has not started yet" (design
  # §3.1). Per mount kind — verticals inherit; a kind not listed has no first-run card.
  @core_resources %{
    crm: [Person, Company],
    billing: [Customer, Invoice],
    support: [Ticket],
    marketing: [Segment, Campaign]
  }

  @doc "The core-resource names probed for `kind` (empty list = no first-run surface)."
  def core_resources(kind), do: Map.get(@core_resources, kind, [])

  @doc """
  TRUE when this mount is on the TENANT plane and `org_id` has zero rows across the
  mount kind's core resources. Operator plane → `false` by construction (design §3.1:
  the operator's first-run surface is the Accounts empty state, not this checklist).
  """
  def first_run?(%Mount{plane: %{kind: :operator}}, _org_id), do: false
  def first_run?(_mount, nil), do: false

  def first_run?(%Mount{} = mount, org_id) do
    case core_resources(mount.scope_kind) do
      [] -> false
      names -> Enum.all?(names, &(not any_rows?(mount, org_id, &1)))
    end
  end

  # ONE bounded existence probe: limit(1) + id-only select, org-scoped, read with the
  # plane's scope. Errors fail SAFE (treat as "has data" → no card).
  defp any_rows?(mount, org_id, name) do
    Mount.resource(mount, name)
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.select([:id])
    |> Ash.Query.limit(1)
    |> Ash.read!(scope: Mount.scope(mount, org_id))
    |> Enum.any?()
  rescue
    _ -> true
  end

  @doc """
  The tenant first-run checklist card (AC-G5-2) — the designed three steps:

    1. **Add your first …** — wired to the surface's create event (`create_event`).
    2. **Load sample data** — emits `"load_sample_data"` (the AC-G5-3 offer); rendered
       only when `sample?` (the caller gates on `Samen.Web.SampleData.offer?/1`).
    3. **Invite a teammate** — a copy-only pointer (identity/invites belong to the host's
       auth surface, not this framework page — no fake button).

  Purely presentational: copy in, markup out. It renders no field values, so it has no
  masking surface.
  """
  attr :id, :string, default: "first-run"
  attr :title, :string, default: "Welcome — your workspace is empty"
  attr :create_event, :string, required: true, doc: ~s(the surface's create event, e.g. "new_contact")
  attr :create_label, :string, required: true, doc: ~s(e.g. "Add your first contact")
  attr :sample?, :boolean, default: false, doc: "offer the load-sample-data step (SampleData.offer?/1)"

  def first_run_card(assigns) do
    ~H"""
    <div class="card first-run" id={@id} style="padding:22px 24px;margin-bottom:14px">
      <h3 class="first-run-title" style="margin:0 0 4px;font-size:15px;font-weight:600">{@title}</h3>
      <p style="margin:0 0 12px;color:var(--muted);font-size:13px">
        Three steps to a working workspace — pick any.
      </p>
      <ol class="first-run-steps" style="margin:0;padding:0;list-style:none;display:flex;flex-direction:column;gap:10px">
        <li class="first-run-step" style="display:flex;align-items:center;gap:10px">
          <span aria-hidden="true">①</span>
          <.button variant="primary" phx-click={@create_event} id={"#{@id}-create"}>{@create_label}</.button>
        </li>
        <li :if={@sample?} class="first-run-step" style="display:flex;align-items:center;gap:10px">
          <span aria-hidden="true">②</span>
          <.button phx-click="load_sample_data" id={"#{@id}-sample"}>Load sample data</.button>
          <span style="color:var(--muted);font-size:12px">synthetic records — written through the vault like real data</span>
        </li>
        <li class="first-run-step" style="display:flex;align-items:center;gap:10px;color:var(--muted);font-size:13px">
          <span aria-hidden="true">{if @sample?, do: "③", else: "②"}</span>
          Invite a teammate — from your account settings in the host app.
        </li>
      </ol>
    </div>
    """
  end
end

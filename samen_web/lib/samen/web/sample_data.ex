defmodule Samen.Web.SampleData do
  @moduledoc """
  The GUARDED in-app sample-data action (WS-A design §3.1 / AC-G5-3, RP-G5-3) — the seed
  logic verticals previously reached only via `mix` (e.g. `Driftwood.Seeds`), exposed as a
  framework action behind the `empty_state/1` `:sample` slot and the first-run checklist.

  ## Guards (every one is a red path)

    * **Tenant plane ONLY** — an operator/impersonation mount is refused
      (`{:error, :operator_plane}`) BEFORE any write. Belt to the kernel's braces: even if
      this guard were deleted, `Samen.Pii.WriteGuard` rejects an operator-plane plaintext
      PII write at the Ash write path (MC-1).
    * **Disabled in prod unless flagged** — `config :samen_web, Samen.Web.SampleData,
      env: …, enabled: …`. The `env` default is `:prod` (FAIL-CLOSED: an unconfigured
      host refuses) and `enabled` defaults `false`; a prod host must set `enabled: true`
      explicitly (RP-G5-3).
    * **Idempotent** — an org that already has core rows gets `{:ok, :already_loaded}`
      and NO new writes (double-click / re-render safe).
    * **Audited** — a successful load writes an `aud_event` (+ chain entry where the
      table exists) via `Samen.AuditChain.Writer` — token-only, no PII in `detail`.

  ## Masking (LOAD-BEARING — the MC-2 note in design §3.1)

  Sample data is SYNTHETIC (invented names/emails/phones — no real person), but it writes
  through the SAME Ash create actions as real data, so vaulted PII (`full_name`, `emails`,
  `phones`) routes through the `Samen.Vault.Change` chokepoint — never a plaintext column
  write. The demonstration is honest: red-path tests scan the raw rows for the sample
  plaintext and must find NOTHING.
  """

  alias Samen.Web.FirstRun
  alias Samen.Web.Mount
  alias Samen.Web.Plane

  # -- the config gate (RP-G5-3: disabled in prod unless a flag is set) -----------

  @doc """
  TRUE when sample data may load in this runtime. FAIL-CLOSED: with NO host config the
  `env` defaults to `:prod` and `enabled` to `false` → refused. A dev/test host sets
  `env:`; a prod host that truly wants the offer sets `enabled: true`.
  """
  def enabled? do
    cfg = Application.get_env(:samen_web, __MODULE__, [])
    Keyword.get(cfg, :env, :prod) != :prod or Keyword.get(cfg, :enabled, false) == true
  end

  @doc """
  Whether to RENDER the offer on this mount (the affordance gate — enforcement is
  `load/2`'s own guards): tenant plane + runtime-enabled + a kind we have samples for.
  """
  def offer?(%Mount{plane: %Plane{kind: :tenant}, scope_kind: kind}),
    do: enabled?() and kind in [:crm]

  def offer?(_mount), do: false

  # -- the guarded action ----------------------------------------------------------

  @doc """
  Load sample records for `org_id` on this mount — guarded, idempotent, audited
  (AC-G5-3). Returns `{:ok, %{...counts}}`, `{:ok, :already_loaded}`, or a refusal:
  `{:error, :operator_plane | :no_org | :disabled | {:no_sample_data, kind}}`.
  """
  def load(%Mount{plane: %Plane{kind: :operator}}, _org_id), do: {:error, :operator_plane}
  def load(_mount, nil), do: {:error, :no_org}

  # The kinds a per-kind seeder exists for (the offer?/1 render gate mirrors this).
  @sample_kinds [:crm]

  def load(%Mount{} = mount, org_id) do
    cond do
      not enabled?() -> {:error, :disabled}
      mount.scope_kind not in @sample_kinds -> {:error, {:no_sample_data, mount.scope_kind}}
      not FirstRun.first_run?(mount, org_id) -> {:ok, :already_loaded}
      true -> seed(mount.scope_kind, mount, org_id)
    end
  end

  # -- per-kind synthetic seeds (all writes through the REAL Ash create actions) ----

  # CRM: 2 companies + 3 contacts. `full_name`/`emails`/`phones` are vault-routed
  # composites — the create action routes them through Samen.Vault.Change exactly as a
  # tenant's own "New contact" submit does (MC-2). All values are synthetic.
  @sample_companies [
    %{name: "Sample: Harborlight Logistics", industry: "Logistics", size: "11-50"},
    %{name: "Sample: Bluefern Analytics", industry: "Software", size: "1-10"}
  ]

  @sample_people [
    {"Aster", "Vale", "Operations Lead", "aster.vale@sample.invalid", "+1 555 0101", 0},
    {"Rowan", "Pike", "Dispatcher", "rowan.pike@sample.invalid", "+1 555 0102", 0},
    {"Imri", "Solano", "Account Manager", "imri.solano@sample.invalid", "+1 555 0103", 1}
  ]

  defp seed(:crm, mount, org_id) do
    scope = Mount.scope(mount, org_id)

    companies =
      for attrs <- @sample_companies do
        Mount.resource(mount, Company)
        |> Ash.Changeset.for_create(:create, Map.put(attrs, :org_id, org_id), scope: scope)
        |> Ash.create!()
      end

    people =
      for {first, last, title, email, phone, company_idx} <- @sample_people do
        Mount.resource(mount, Person)
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            display_name: "#{first} #{last}",
            job_title: title,
            company_id: Enum.at(companies, company_idx).id,
            full_name: %{"first" => first, "last" => last},
            emails: [%{label: "work", address: email}],
            phones: [%{label: "mobile", number: phone}]
          },
          scope: scope
        )
        |> Ash.create!()
      end

    counts = %{companies: length(companies), contacts: length(people)}
    audit(mount, org_id, scope, "kind=crm companies=#{counts.companies} contacts=#{counts.contacts}")
    {:ok, counts}
  rescue
    e -> {:error, e}
  end

  # Token-only audit line (AC-G5-3 "audited"): event + counts, NO PII. FAIL-HONEST:
  # a refused/failed audit write raises (the `{:ok, _} =` match) into `seed/3`'s
  # rescue, so the caller sees `{:error, _}` rather than a silently-unaudited load.
  # (Where only the aud_chain TABLE is absent, Writer itself degrades gracefully to
  # the aud_event row — that is a host-migration posture, not a skipped audit.)
  defp audit(mount, org_id, scope, detail) do
    {:ok, _} =
      Samen.AuditChain.Writer.write(mount.repo, %{
        org_id: org_id,
        event_type: "system",
        actor_id: scope.actor.id,
        detail: "event=sample_data_loaded #{detail}",
        occurred_at: DateTime.utc_now()
      })

    :ok
  end
end

defmodule Driftwood.Reads do
  @moduledoc """
  The SHARED tenant-plane read layer used by BOTH planes' LiveViews (T5.3).

  This is the load-bearing seam that makes the masked-impersonation guarantee real: the
  broker's own dashboard and the OPERATOR's impersonation view call the EXACT SAME
  functions here — `driver_roster/1`, `load_board/1`, `settlements/1` — differing only
  in the `scope` passed. When the operator passes an impersonation scope (no reveal
  grant), the vault-routed fields (`full_name`, `cdl_number`) come back as `%Masked{}`
  and render `••••` BY CONSTRUCTION. There is no separate "operator read" that could
  accidentally leak plaintext — one code path, one masking behaviour.

  Every function takes an `%Ash.Query`-compatible `scope` (a `%Samen.Scope{}` or an
  actor map) and reads through Ash so OrgScope + the vault masking apply. Vault fields
  are `ensure_selected` explicitly (a real UI asks for them); without a reveal grant
  they load masked.

  ## FMCSA status (the driver roster)

  `fmcsa_status/1` computes, for a driver row, the SAME legality the
  `Driftwood.Policy.FmcsaDispatchGate` enforces — medical/CDL expiry, driver status —
  as a display badge (`:ok` | `{:blocked, reasons}`). It reads ONLY non-PII columns
  (dates + status), never the vaulted CDL number. `dispatchable?/1` is the UI-action
  guard: the roster's "Dispatch" button is disabled for a non-`:ok` driver, matching
  the server-side gate (defence in depth — the gate still refuses if the UI is
  bypassed).
  """

  require Ash.Query

  # ADR-045 §4.2 (O8) — the HARD read bound for the vertical read layer. Every list read here
  # decrypts vault fields per row (`resolve_pii/2`), so an UNBOUNDED read on a large org's
  # roster is a per-navigation resource-exhaustion / KMS-cost hazard. `@limit` caps every list
  # read so one call can never sweep-and-decrypt more than this many rows — the SAME discipline
  # the framework `Samen.Web.Reads` clamp (`@max_page_size 200`) and the sibling
  # `PawChartWeb.ClinicReads` `@limit 200` already apply. Enforced by the boundedness lint
  # (`Samen.Web.Reads.Lint`), which now sweeps this vertical tree.
  @limit 200

  @doc """
  The DRIVER ROSTER for the given scope: driver rows with name (masked unless granted),
  CDL number (masked), CDL state/expiry (non-PII), medical expiry, status, ELD provider,
  and a computed FMCSA badge. Reads through Ash — OrgScope narrows to the scope's org;
  the vault fields load `%Masked{}` without a reveal grant.

  BOUNDED (O8): the read carries an explicit `Ash.Query.limit` so a large org's roster never
  triggers an unbounded per-row vault-decrypt sweep on navigation. `opts[:limit]` may request
  a SMALLER page (a future "load more", or a test probe); it is CLAMPED to `@limit`, so a
  caller can only ever narrow the page — never exceed the cap. The bound does not change WHICH
  plane resolves the vault fields, so masking is untouched (tenant CLEAR, operator masked).
  """
  def driver_roster(scope, opts \\ []) do
    Driftwood.Freight.Driver
    |> Ash.Query.ensure_selected([
      :full_name,
      :cdl_number,
      :cdl_state,
      :cdl_expiry,
      :medical_card_expiry,
      :status,
      :eld_provider
    ])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(bounded_limit(opts))
    |> Ash.read!(scope: scope)
    |> resolve_pii(scope)
    |> Enum.map(fn d ->
      Map.put(d, :__fmcsa__, fmcsa_status(d))
    end)
  rescue
    _ -> []
  end

  # Clamp a requested page into `1..@limit` — a caller can narrow the page but NEVER exceed the
  # cap (defence in depth: even a hostile/buggy `:limit` can only shrink the decrypt sweep).
  defp bounded_limit(opts) do
    case Keyword.get(opts, :limit) do
      n when is_integer(n) and n >= 1 -> min(n, @limit)
      _ -> @limit
    end
  end

  @doc """
  T158 — fetch ONE driver by id for `scope`, PII-resolved through the SAME seam
  `driver_roster/1` uses (`resolve_pii/2` → `Samen.Api.PiiResolution`) — the
  form-prefill source for the driver EDIT modal. On the `broker_scope/1` tenant
  plane this resolves `full_name`/`cdl_number` CLEAR; on an operator-without-grant
  plane it would resolve `%Masked{}` (this console never mounts that plane, but the
  read function is the same one that does elsewhere). `{:ok, driver}` or `:error`
  (not found — including a cross-org id, invisible under OrgScope — or a read
  failure) — never a partial/fabricated record.
  """
  @spec get_driver(term(), binary()) :: {:ok, struct()} | :error
  def get_driver(scope, id) do
    result =
      Driftwood.Freight.Driver
      |> Ash.Query.ensure_selected([
        :full_name,
        :cdl_number,
        :cdl_state,
        :cdl_expiry,
        :medical_card_expiry,
        :status,
        :eld_provider
      ])
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)
      |> resolve_pii(scope)

    case result do
      [driver | _] -> {:ok, driver}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  T158 — fetch ONE settlement by id for `scope`, the RAW (un-reshaped) resource —
  the form-prefill source for the settlement EDIT modal. Settlement carries no PII;
  `settlements/1` reshapes the derived netting calcs on TOP of this same resource,
  but the edit form only touches the STORED input columns, so this reads the plain
  resource directly (no `Driftwood.Context` reshape needed for a write form).
  `{:ok, settlement}` or `:error` (not found / cross-org / read failure).
  """
  @spec get_settlement(term(), binary()) :: {:ok, struct()} | :error
  def get_settlement(scope, id) do
    Driftwood.Freight.Settlement
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(scope: scope)
    |> case do
      nil -> :error
      settlement -> {:ok, settlement}
    end
  rescue
    _ -> :error
  end

  # F2 (Gate-5 carry) — the SHARED tenant-plane PII resolver.
  #
  # An Ash read returns vault-routed fields as `%Masked{}` (••••) for EVERY scope
  # (fail-safe by default). `Samen.Api.PiiResolution.resolve/4` is the two-key-classes
  # rule (doc §external-surface :707): on the `:tenant` plane it unmasks a driver's own
  # `full_name`/`cdl_number` to PLAINTEXT (the tenant owns its drivers' PII, no operator
  # reveal grant); on the `:operator` plane (the impersonation scope) it keeps the field
  # `%Masked{}` — the operator plane stays masked. This is the SAME record-level resolver
  # the public `/api/v1` egress uses (F1), so the console and the API cannot drift.
  #
  # An org-less / plane-less scope resolves to the default masked posture (no plane →
  # ••••), so a broken/missing scope never leaks plaintext. Fail-closed on a decrypt
  # error too (a failed vault read leaves the value masked, never raises a leak).
  defp resolve_pii(records, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      Driftwood.Freight.Driver,
      actor_of(scope),
      repo: Driftwood.Repo
    )
  rescue
    # Any resolver failure MUST NOT downgrade to plaintext — return the records with
    # the fields still masked (the read already produced %Masked{}).
    _ -> records
  end

  # The plane-bearing actor map the resolver keys on. A `%Samen.Scope{}` carries it in
  # `:actor`; a bare actor map is used as-is; anything else has no plane (masked).
  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  @doc """
  The LOAD BOARD for the given scope: Load (Opportunity alias) rows — name, value
  (ADR-036 H1: the Money composite, formerly value_cents/currency), status, close
  date, lane (from the custom bag). Non-PII throughout; reads through the scope's
  org boundary.
  """
  def load_board(scope), do: load_board(scope, %{})

  @doc """
  T158 — the REAL filtered load board. `filters` is a plain map (string or atom
  keys, as it arrives straight off `phx-change` params) with two optional keys:

    * `:status` (or `"status"`) — one of the Load status enum
      (`open`/`won`/`lost`/`on_hold`); an unrecognised value is IGNORED (treated
      as no status filter) rather than raising — a malformed/forged param must
      never 500 the board.
    * `:q` (or `"q"`) — a free-text substring matched against the load
      reference `name` and the `lane` (case-insensitive).

  ORG-SCOPE (load-bearing): the underlying `Ash.read!` call is passed `scope:
  scope` — the SAME `Samen.Policy.OrgScope` boundary every other read in this
  module rides. The filter narrows WITHIN that already-org-scoped result set; it
  can never be used to reach across into another org's rows (there is no path
  here that widens the read past the scope's own org). No matches is an HONEST
  empty list — never a fabricated/sample row.
  """
  def load_board(scope, filters) when is_map(filters) do
    status = normalize_load_status(fetch(filters, :status))
    q = filters |> fetch(:q) |> to_string() |> String.trim() |> String.downcase()

    Driftwood.Crm.Opportunity
    |> Ash.Query.ensure_selected([:name, :value, :status, :close_date, :custom])
    |> Ash.Query.sort(inserted_at: :asc)
    |> maybe_filter_status(status)
    |> Ash.Query.limit(@limit)
    |> Ash.read!(scope: scope)
    |> Enum.map(fn l ->
      lane = get_in(l.custom || %{}, ["lane"]) || "unknown"
      Map.put(l, :__lane__, lane)
    end)
    |> filter_by_query(q)
  rescue
    _ -> []
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  @load_statuses ~w(open won lost on_hold)

  defp normalize_load_status(nil), do: nil
  defp normalize_load_status(""), do: nil

  defp normalize_load_status(s) when is_atom(s) do
    if to_string(s) in @load_statuses, do: s, else: nil
  end

  defp normalize_load_status(s) when is_binary(s) do
    if s in @load_statuses, do: String.to_existing_atom(s), else: nil
  end

  defp normalize_load_status(_), do: nil

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: Ash.Query.filter(query, status == ^status)

  defp filter_by_query(loads, ""), do: loads

  defp filter_by_query(loads, q) do
    Enum.filter(loads, fn l ->
      String.contains?(String.downcase(l.name || ""), q) or
        String.contains?(String.downcase(to_string(l.__lane__)), q)
    end)
  end

  @doc """
  The SETTLEMENTS for the given scope, WITH the `Driftwood.Context` reshape calcs loaded
  (gross / factoring_fee / net_payable / carryover) — the reshaped two-sided money. The
  derived money is read through `Samen.Context.reshaped_query/2` (the anti-corruption
  layer), so the calcs land in `row.calculations`; this returns a normalized map per
  settlement with the stored inputs + the derived fields flattened. Reads through the
  scope's org boundary; all columns are non-PII cents/enums.
  """
  def settlements(scope) do
    Samen.Context.reshaped_query(Driftwood.Context, Driftwood.Freight.Settlement)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@limit)
    |> Ash.read!(scope: scope)
    |> Enum.map(fn s ->
      calc = s.calculations || %{}

      %{
        id: s.id,
        status: s.status,
        linehaul_cents: s.linehaul_cents,
        advances_cents: s.advances_cents,
        claim_deduction_cents: s.claim_deduction_cents,
        gross_cents: to_int(Map.get(calc, :gross_cents)),
        factoring_fee_cents: to_int(Map.get(calc, :factoring_fee_cents)),
        net_payable_cents: to_int(Map.get(calc, :net_payable_cents)),
        carryover_cents: to_int(Map.get(calc, :carryover_cents))
      }
    end)
  rescue
    _ -> []
  end

  # The reshape returns :integer calcs (sometimes a Decimal from the numeric SQL path).
  defp to_int(nil), do: 0
  defp to_int(i) when is_integer(i), do: i
  defp to_int(f) when is_float(f), do: round(f)
  defp to_int(%Decimal{} = d), do: d |> Decimal.round(0) |> Decimal.to_integer()

  @doc """
  Compute the FMCSA display status for a driver row — the SAME rule the
  `FmcsaDispatchGate` enforces (medical/CDL expiry, driver status), as a display badge.
  Reads ONLY non-PII columns. Returns `:ok` or `{:blocked, [reason_atom]}`.
  """
  @spec fmcsa_status(map()) :: :ok | {:blocked, [atom()]}
  def fmcsa_status(driver) do
    today = Date.utc_today()

    reasons =
      []
      |> check_medical(Map.get(driver, :medical_card_expiry), today)
      |> check_cdl(parse_iso(Map.get(driver, :cdl_expiry)), today)
      |> check_status(Map.get(driver, :status))

    case reasons do
      [] -> :ok
      list -> {:blocked, Enum.reverse(list)}
    end
  end

  @doc "Is this driver row currently dispatchable (FMCSA badge is :ok)? UI-action guard."
  @spec dispatchable?(map()) :: boolean()
  def dispatchable?(driver), do: fmcsa_status(driver) == :ok

  @doc "Human-readable reason label for a blocked FMCSA badge."
  def reason_label(:medical_missing), do: "medical card missing"
  def reason_label(:medical_expired), do: "medical card expired"
  def reason_label(:cdl_missing_expiry), do: "CDL expiry missing"
  def reason_label(:cdl_expired), do: "CDL expired"
  def reason_label(:out_of_service), do: "out of service"
  def reason_label(:terminated), do: "terminated"
  def reason_label(other), do: to_string(other)

  # -- gate rule mirrored (non-PII only) ------------------------------------

  defp check_medical(reasons, nil, _today), do: [:medical_missing | reasons]

  defp check_medical(reasons, %Date{} = expiry, today) do
    if Date.compare(expiry, today) == :lt, do: [:medical_expired | reasons], else: reasons
  end

  defp check_cdl(reasons, nil, _today), do: [:cdl_missing_expiry | reasons]

  defp check_cdl(reasons, %Date{} = expiry, today) do
    if Date.compare(expiry, today) == :lt, do: [:cdl_expired | reasons], else: reasons
  end

  defp check_status(reasons, s) when s in [:out_of_service, "out_of_service"],
    do: [:out_of_service | reasons]

  defp check_status(reasons, s) when s in [:terminated, "terminated"],
    do: [:terminated | reasons]

  defp check_status(reasons, _), do: reasons

  defp parse_iso(nil), do: nil
  defp parse_iso(%Date{} = d), do: d

  defp parse_iso(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      {:error, _} -> nil
    end
  end
end

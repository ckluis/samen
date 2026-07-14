defmodule Samen.FeatureFlags do
  @moduledoc """
  The feature-flag evaluation engine (ADR-020; design G6 §3). A pure, deterministic
  function over governed flag config + a NON-PII subject scope — the kernel rollout /
  kill-switch / targeting lever every plane and every API/worker path uses. Web-dep
  free: ETS + a GenServer cache, no Phoenix.

  ## `evaluate/2`

      Samen.FeatureFlags.evaluate("billing.invoice_pdf", %{org_id: org_id, plan: "pro"})
      #=> %Samen.FeatureFlags.Decision{on: true, variant: nil, reason: :rollout_in}

  The subject scope is a map of BOUNDED, NON-PII keys — `org_id` (the bucketing
  subject), plus optional targeting keys (`plan`, `tier`, `stage`, `role`, `region`).
  A bare `org_id` string is accepted as shorthand (`evaluate(flag, org_id)`).

  ## Precedence (fixed, short-circuiting — ADR-020 §2, design §3.2)

      kill-switch  >  explicit deny  >  explicit allow  >  targeting rules
                   >  percentage bucket  >  default

    1. **Kill switch** — `enabled == false` → OFF, `reason: :kill_switch`. The
       incident lever; short-circuits everything. Fail-SAFE: a flag the engine
       cannot CONFIRM on (cache/lookup error, unknown flag) is likewise OFF.
    2. **Explicit deny** — a `then: "deny"` rule that matches → OFF, `reason: :deny`.
    3. **Explicit allow** — a `then: "allow"` rule that matches → ON, `reason: :allow`.
    4. **Targeting** — the first `then: "on"/"off"/<variant>` rule that matches
       (non-PII keys only, enforced at write) → `reason: :targeted`.
    5. **Percentage bucket** — deterministic `phash2({flag, subject}, 10_000)` bucket
       `< rollout_pct` → ON `:rollout_in`, else OFF `:rollout_out`.
    6. **Default** — no rule/rollout applied → the flag's default gate `:default`.

  ## Determinism + monotonic ramp (RP-F1)

  Bucketing is `:erlang.phash2({flag_name, subject_key}, 10_000) / 100.0`. Keying on
  `{flag, subject}` makes the same `(flag, org)` bucket IDENTICALLY forever — raising
  `rollout_pct` only ever ADDS orgs (off→on), never reshuffles — and makes different
  flags bucket independently (no correlated exposure). `phash2` is deterministic
  across processes and restarts; replacing it with `:rand` breaks the stability
  property (the RP-F1 sabotage).

  ## Cache (RP-F4 fail-safe)

  Config is read from `Samen.FeatureFlags.Cache` (ETS). On ANY cache/lookup error the
  engine returns OFF for a flag it cannot confirm ON — it NEVER fails open. The kill
  switch bypasses cache staleness: `Cache.get/2` is write-through-invalidated on flag
  write, and a disabled flag resolves OFF within one broadcast hop (design §3.3).
  """

  require Logger

  alias Samen.FeatureFlags.{Cache, Decision, TargetRule}

  @bucket_space 10_000

  @doc """
  Evaluate a flag for a subject scope. Returns a `%Decision{}`; always succeeds
  (fail-SAFE — OFF on any error).

  `subject` is a non-PII map (`%{org_id: ..., plan: ...}`) or a bare `org_id`
  binary. `opts` may carry `:flag_module` / `:repo` (DI seams; default to config)
  and `:emit` (the assignment seam — see `assignment_payload/3`):

    * a 1-arity fn — called with the payload (test/bespoke consumers);
    * omitted — falls back to the CONFIGURED emitter, the B7 `track/1` wiring
      point (`config :samen_core, Samen.FeatureFlags, emit: {Samen.Analytics,
      :track}`); absent config, no emit;
    * `false` — suppressed (the admin-preview path, `evaluate_config/4`).
  """
  @spec evaluate(String.t(), map() | String.t(), keyword()) :: Decision.t()
  def evaluate(flag_name, subject, opts \\ [])

  def evaluate(flag_name, org_id, opts) when is_binary(org_id) do
    evaluate(flag_name, %{org_id: org_id}, opts)
  end

  def evaluate(flag_name, %{} = subject, opts) when is_binary(flag_name) do
    subject_key = subject_key(subject)

    case Cache.get(flag_name, opts) do
      {:ok, nil} ->
        # Unknown flag — fail SAFE (cannot confirm ON).
        Decision.off(:kill_switch)

      {:ok, config} ->
        decide(flag_name, config, subject, subject_key, opts)

      {:error, _reason} ->
        # RP-F4: cache unavailable / poisoned → OFF, never fails open.
        Decision.off(:kill_switch)
    end
  rescue
    # Belt: any unexpected error in evaluation is fail-SAFE, never fails open.
    e ->
      Logger.warning("[FeatureFlags] evaluate/2 raised, failing OFF: #{Exception.message(e)}")
      Decision.off(:kill_switch)
  end

  @doc """
  Evaluate a flag CONFIG directly — the cache-FREE preview path for the two-plane
  flag admin (design §3.5 "evaluated state"; B6). Runs the SAME precedence pipeline
  as `evaluate/2`, but the caller supplies the config map (e.g. built straight off
  the `pff` row it is rendering), so an admin preview:

    * never reads, warms, or poisons the shared ETS cache (the kill-switch staleness
      bound stays owned by the WRITE path's `Cache.invalidate/1`), and
    * never emits a `flag.assignment` event (`emit: false` unless the caller
      explicitly overrides) — rendering an admin page is not an experiment exposure.

  A `nil` config (unknown flag) is fail-SAFE OFF, exactly like `evaluate/2`.
  """
  @spec evaluate_config(String.t(), map() | nil, map() | String.t(), keyword()) :: Decision.t()
  def evaluate_config(flag_name, config, subject, opts \\ [])

  def evaluate_config(flag_name, config, org_id, opts) when is_binary(org_id),
    do: evaluate_config(flag_name, config, %{org_id: org_id}, opts)

  def evaluate_config(_flag_name, nil, _subject, _opts), do: Decision.off(:kill_switch)

  def evaluate_config(flag_name, %{} = config, %{} = subject, opts) when is_binary(flag_name) do
    opts = Keyword.put_new(opts, :emit, false)
    decide(flag_name, config, subject, subject_key(subject), opts)
  rescue
    e ->
      Logger.warning("[FeatureFlags] evaluate_config/4 raised, failing OFF: #{Exception.message(e)}")
      Decision.off(:kill_switch)
  end

  # The bounded non-PII bucketing subject. org_id is the canonical subject; a caller
  # may pass an explicit :subject_key (a per-org stable token) instead. NEVER a PII
  # field (targeting keys are non-PII by construction; the subject key is an id).
  defp subject_key(%{subject_key: key}) when not is_nil(key), do: to_string(key)
  defp subject_key(%{org_id: org_id}) when not is_nil(org_id), do: to_string(org_id)
  defp subject_key(_), do: ""

  # ---------------------------------------------------------------------------
  # The precedence pipeline (fixed order; short-circuits).
  # ---------------------------------------------------------------------------

  defp decide(flag_name, config, subject, subject_key, opts) do
    cond do
      # (1) KILL SWITCH — enabled == false short-circuits everything.
      not truthy?(config[:enabled]) ->
        Decision.off(:kill_switch)

      true ->
        rules = TargetRule.parse(config[:target_rules])
        eval_targeting(flag_name, config, subject, subject_key, rules, opts)
    end
  end

  defp eval_targeting(flag_name, config, subject, subject_key, rules, opts) do
    # (2) explicit DENY beats (3) explicit ALLOW beats (4) targeting (first match).
    denies = Enum.filter(rules, &(&1.then == :deny))
    allows = Enum.filter(rules, &(&1.then == :allow))
    targets = Enum.reject(rules, &(&1.then in [:deny, :allow]))

    cond do
      match = TargetRule.first_match(denies, subject) ->
        TargetRule.decide(match)

      match = TargetRule.first_match(allows, subject) ->
        maybe_assign(flag_name, config, subject, subject_key, TargetRule.decide(match), opts)

      match = TargetRule.first_match(targets, subject) ->
        maybe_assign(flag_name, config, subject, subject_key, TargetRule.decide(match), opts)

      true ->
        # (5) percentage bucket, then (6) default.
        eval_rollout(flag_name, config, subject, subject_key, opts)
    end
  end

  defp eval_rollout(flag_name, config, subject, subject_key, opts) do
    rollout = rollout_pct(config)

    decision =
      cond do
        rollout >= 100 -> %Decision{on: true, reason: :default}
        rollout <= 0 -> %Decision{on: false, reason: :rollout_out}
        bucket(flag_name, subject_key) < rollout -> %Decision{on: true, reason: :rollout_in}
        true -> %Decision{on: false, reason: :rollout_out}
      end

    maybe_assign(flag_name, config, subject, subject_key, decision, opts)
  end

  # ---------------------------------------------------------------------------
  # Deterministic bucketing (RP-F1 / RP-F2).
  # ---------------------------------------------------------------------------

  @doc """
  The deterministic subject bucket in `0.0..100.0` for `{flag_name, subject_key}`.
  Org-stable (same inputs → same bucket forever, across processes and restarts) and
  flag-independent. This is the load-bearing determinism RP-F1 sabotages.
  """
  @spec bucket(String.t(), String.t()) :: float()
  def bucket(flag_name, subject_key) do
    :erlang.phash2({flag_name, subject_key}, @bucket_space) / 100.0
  end

  # ---------------------------------------------------------------------------
  # Variant assignment (weighted deterministic — the experiment seam, design §3.4).
  # ---------------------------------------------------------------------------

  # When ON and the flag has variants and no variant is already set, assign one
  # deterministically (weighted bucketing on the SAME stable hash) and, if an :emit
  # fn is supplied, emit the assignment payload. The emit CALL SITE to track/1 lands
  # in B7; UNIT 1 asserts the assignment DECISION + payload.
  defp maybe_assign(flag_name, config, subject, subject_key, %Decision{on: true} = decision, opts) do
    variants = normalize_variants(config[:variants])

    cond do
      not is_nil(decision.variant) ->
        decision

      variants == [] ->
        decision

      true ->
        variant = assign_variant(flag_name, subject_key, variants)
        assigned = %{decision | variant: variant}
        emit_assignment(flag_name, variant, subject, opts)
        assigned
    end
  end

  defp maybe_assign(_flag_name, _config, _subject, _subject_key, decision, _opts), do: decision

  @doc """
  Deterministically assign a variant by weighted bucketing on the stable hash.
  Same `{flag, subject}` → same variant forever. `variants` is a list of
  `{name_atom, weight_number}`.
  """
  @spec assign_variant(String.t(), String.t(), [{atom(), number()}]) :: atom()
  def assign_variant(flag_name, subject_key, variants) do
    total = variants |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    # Reuse the stable [0,100) bucket, scaled to the total weight.
    point = bucket(flag_name, subject_key) / 100.0 * total

    variants
    |> Enum.reduce_while({point, nil}, fn {name, weight}, {remaining, _} ->
      if remaining < weight do
        {:halt, {remaining, name}}
      else
        {:cont, {remaining - weight, name}}
      end
    end)
    |> case do
      {_, nil} -> variants |> List.last() |> elem(0)
      {_, name} -> name
    end
  end

  @doc """
  The bounded, NON-PII assignment payload emitted into the G12 product-analytics
  path (design §3.4): `%{event: "flag.assignment", flag_name, variant, org_id}`. All
  fields are config-defined names + a bounded org id — no subject PII.

  ## Org resolution (closes the B5 carry — subject_key-only callers)

  The `org_id` is resolved by `subject_org/1`: an explicit `:org_id` wins, else the
  bucketing `subject_key` (design §3.2: "org_id OR a per-org stable token") stands
  in — the SAME bounded, non-PII identity `track/1` scopes the `pae` row on. Before
  this fix a `%{subject_key: token}`-only caller (a per-org token subject, no
  `:org_id`) produced `org_id: nil`, orphaning the assignment `pae` event off any
  org (design §3.4 requires `org_id` bounded/non-PII, never nil). A truly org-less
  subject (`%{}`) still yields `nil` — an unscoped assignment `track/1` then drops
  (an org-scoped ledger needs an org), never fabricates one.
  """
  @spec assignment_payload(String.t(), atom(), map() | String.t()) :: map()
  def assignment_payload(flag_name, variant, subject) do
    %{
      event: "flag.assignment",
      flag_name: flag_name,
      variant: variant,
      org_id: subject_org(subject)
    }
  end

  # The bounded org identity for the assignment event. An explicit :org_id wins;
  # otherwise the per-org stable :subject_key (design §3.2 — the bucketing subject
  # IS "org_id or a per-org stable token") is the org identity. Both are the same
  # non-PII bounded key `evaluate/2` buckets on. Falls to nil only for a subject
  # carrying NEITHER (a genuinely org-less call), which the emit path then drops.
  defp subject_org(%{org_id: org_id}) when not is_nil(org_id), do: to_string(org_id)
  defp subject_org(%{subject_key: key}) when not is_nil(key), do: to_string(key)
  defp subject_org(org_id) when is_binary(org_id), do: org_id
  defp subject_org(_), do: nil

  # The emit seam (design §3.4; AC-G6-8). Resolution: an explicit 1-arity fn wins;
  # `emit: false` (the preview path) suppresses; otherwise the CONFIGURED emitter —
  # the B7 track/1 wiring point — runs:
  #
  #     config :samen_core, Samen.FeatureFlags, emit: {Samen.Analytics, :track}
  #
  # so once B7's `track/1` lands, EVERY variant assignment flows into the `pae`
  # product-analytics path with zero call-site changes.
  defp emit_assignment(flag_name, variant, subject, opts) do
    case Keyword.get(opts, :emit, :config) do
      fun when is_function(fun, 1) ->
        fun.(assignment_payload(flag_name, variant, subject))
        :ok

      :config ->
        case configured_emitter() do
          {mod, fun} when is_atom(mod) and is_atom(fun) ->
            apply(mod, fun, [assignment_payload(flag_name, variant, subject)])
            :ok

          fun when is_function(fun, 1) ->
            fun.(assignment_payload(flag_name, variant, subject))
            :ok

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  rescue
    # The assignment seam is best-effort — it must never break evaluation.
    _ -> :ok
  end

  defp configured_emitter do
    case Application.get_env(:samen_core, __MODULE__) do
      opts when is_list(opts) -> Keyword.get(opts, :emit)
      %{} = opts -> Map.get(opts, :emit)
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Config coercion helpers (config comes from ETS as a plain map).
  # ---------------------------------------------------------------------------

  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp rollout_pct(config) do
    case config[:rollout_pct] do
      n when is_integer(n) -> clamp(n)
      n when is_float(n) -> clamp(trunc(n))
      _ -> 0
    end
  end

  defp clamp(n) when n < 0, do: 0
  defp clamp(n) when n > 100, do: 100
  defp clamp(n), do: n

  # variants may arrive as %{"a" => 50, "b" => 50} (jsonb) or a keyword list.
  # Normalize to a stable-ordered [{atom, number}] list.
  defp normalize_variants(nil), do: []
  defp normalize_variants(v) when v == %{}, do: []

  defp normalize_variants(v) when is_map(v) do
    v
    |> Enum.map(fn {k, w} -> {to_atom(k), to_number(w)} end)
    |> Enum.filter(fn {_k, w} -> w > 0 end)
    |> Enum.sort_by(fn {k, _w} -> to_string(k) end)
  end

  defp normalize_variants(v) when is_list(v) do
    v
    |> Enum.map(fn {k, w} -> {to_atom(k), to_number(w)} end)
    |> Enum.filter(fn {_k, w} -> w > 0 end)
    |> Enum.sort_by(fn {k, _w} -> to_string(k) end)
  end

  defp normalize_variants(_), do: []

  defp to_atom(k) when is_atom(k), do: k

  defp to_atom(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> String.to_atom(k)
  end

  defp to_number(w) when is_number(w), do: w
  defp to_number(_), do: 0
end

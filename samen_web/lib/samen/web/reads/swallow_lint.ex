defmodule Samen.Web.Reads.SwallowLint do
  @moduledoc """
  The SWALLOW ratchet (WP6): a read helper that ends in `rescue _ -> []` renders an outage as
  an empty workspace (audit P3, ARCH-14). `Samen.Web.Reads.Guard` is the fix; this lint stops
  the swallow from coming back, and from spreading, while the rest of the tree is converted.

  ## What counts as a swallow

  A `rescue` / `catch` clause whose pattern is a CATCH-ALL (`_`, `_e`, `e`, or `_kind, _reason`)
  and whose body does NOT:

    * log (`Logger.*`) or report (`Guard.report/3`),
    * re-raise (`raise` / `reraise`), or
    * hand the exception on — it references the variable the clause bound (`e -> {:error, e}`,
      `Exception.message(e)`), which is a write/probe that tells its caller.

  `rescue ArgumentError -> …`, `rescue e in [A, B] -> …` and any other TYPED clause is not a
  swallow: the author named what can go wrong.

  ## The ratchet

  `baseline/0` is the per-file count of swallows that still exist (the converted tree has none
  in the files that were converted). `check/1` compares a scan of `samen_web/lib`,
  `driftwood/lib` and `pawchart/lib` to it and fails when

    * a file has MORE swallows than its baseline (including any file not listed — a NEW bare
      `rescue _ -> []` fails the suite), or
    * a file has FEWER — the baseline must then be lowered to the new count, so converted code
      cannot quietly re-grow (shrink-only).

  Each phase of WP6 deletes rows from `baseline/0`; the goal state is an empty map plus the
  handful of reviewed total helpers in `reviewed/0`. A reviewed helper is a swallow that is
  correct (an optional-scope probe, a fail-closed authorization lookup): list it by
  `{file, function}` WITH its reason — never a bare entry.

  The lint reads SOURCE only; it never compiles, runs or inspects a value.
  """

  @roots ["samen_web/lib", "driftwood/lib", "pawchart/lib"]

  # Reviewed-correct swallows, `{file, function} => reason`. They are subtracted from the count.
  @reviewed %{
    {"samen_web/lib/samen/web/reads/guard.ex", :run} =>
      "the exit/throw clauses funnel into failed/3, which Guard.report/3s — the lint cannot see through the call",
    {"samen_web/lib/samen/web/reads/guard.ex", :write} =>
      "the exit/throw clauses (and the rescue) funnel into write_failed/3 -> log_failure/4, which Logger.errors and emits the write-error event — the lint cannot see through the call",
    {"samen_web/lib/samen/web/reads/guard.ex", :emit} =>
      "best-effort telemetry: observability must never break the read it observes",
    {"samen_web/lib/samen/web/crm/reads.ex", :work_resource?} =>
      "optional-scope probe: an unmounted Work scope IS 'absent' — the honest answer",
    {"samen_web/lib/samen/web/crm/sequences_reads.ex", :live_resource?} =>
      "optional-scope probe: an unmounted Outreach scope IS 'absent' — the honest answer",
    {"samen_web/lib/samen/web/crm/sequences_reads.ex", :sends_configured?} =>
      "fail-honest predicate: 'no sender configured' is the safe, truthful default",
    {"samen_web/lib/samen/web/marketing/leads_live.ex", :crm_mount} =>
      "optional-scope probe: no (or an unresolvable) :crm_namespace label means the Leads lens is not wired on this host, which the lens renders as inert — a host-configuration fact, not a read",
    {"samen_web/lib/samen/web/settings/security_live.ex", :safe_csrf_token} =>
      "no CSRF token available (outside a request) renders the revoke forms without one, which the server then rejects — fail-closed, nothing to report",
    {"samen_web/lib/samen/web/settings/invitations_live.ex", :verified?} =>
      "fail-CLOSED capability probe (ADR-035 §5 A2): an unresolvable principal is unverified on an armed host (the invite is refused), never an elevated default",
    {"samen_web/lib/samen/web/replay/recorder.ex", :on_mount} =>
      "best-effort observer: session capture must never crash or block the LiveView it observes (documented 'Never crashes, never blocks'); a capture failure turns capture off, it does not change what the user sees",
    {"samen_web/lib/samen/web/replay/recorder.ex", :attach} =>
      "best-effort observer: same contract as on_mount/4 — attaching the recorder can never break the LiveView",
    {"samen_web/lib/samen/web/replay/recorder.ex", :guarded} =>
      "best-effort observer: a failing recorder hook turns capture :off for that LiveView and returns the socket untouched (documented)",
    {"samen_web/lib/samen/web/replay/recorder.ex", :off} =>
      "best-effort observer: detaching hooks after a recorder failure must itself be total",
    {"samen_web/lib/samen/web/replay/renderer.ex", :render_body} =>
      "returns the honest tagged value {:error, :render_failed}, which the player renders as a failed replay — not a swallow",
    {"samen_web/lib/samen/web/replay/renderer.ex", :view_mount} =>
      "optional-scope probe: a view with no resolvable router mount has no live mount; nil is the honest answer the caller handles",
    {"samen_web/lib/samen/web/ai/server.ex", :public_field_names} =>
      "pure introspection of a resource module (no read): a module with no resource info yields no extra fields, which only narrows what the grounding preview shows",
    {"samen_web/lib/samen/web/object_ref/catalog.ex", :catalogued_resource?} =>
      "pure module introspection (no read): a module that is not a loaded Ash resource is not catalogued — the inert chip, no existence oracle",
    {"samen_web/lib/samen/web/object_ref/default_card.ex", :public_attributes} =>
      "pure resource introspection (no read): a module with no resource info shows no extra fields on the card",
    {"samen_web/lib/samen/web/object_ref/registry.ex", :card_for} =>
      "a host card override that raises falls back to the default card (which resolves through the same PiiResolution output) — presentation only, never data",
    {"samen_web/lib/samen/web/object_ref.ex", :selectable_attrs} =>
      "pure resource introspection (no read): no attributes means the default card shows only what it was handed",
    {"samen_web/lib/samen/web/account_health.ex", :sibling_mount} =>
      "optional-scope probe: an unmounted sibling Billing/Support scope IS 'not mounted' — the framework-level honest absence (documented 'billing_available? false')",
    {"samen_web/lib/samen/web/account_health.ex", :resource?} =>
      "optional-scope probe: a module that is not a compiled Ash resource is 'not mounted'",
    {"samen_web/lib/samen/web/onboarding/wizard_live.ex", :verified?} =>
      "fail-CLOSED capability probe (ADR-035 §5 A2): an unresolvable principal is unverified on an armed host, never an elevated default",
    {"samen_web/lib/samen/web/first_run.ex", :any_rows?} =>
      "fail-safe probe: a failed existence check answers 'has records' so the first-run sample-data offer is NOT shown (never offers sample data into a possibly populated org)",
    {"samen_web/lib/samen/web/reads.ex", :safe_count} =>
      "an exact-total aggregate that fails is nil = 'total unknown'; the CRM pipeline column header prints no number for it, and the three board totals that sum group counts (Work timeline, CRM pipeline, CRM calendar) become nil — an em dash — when any group count is nil, never a fabricated count or the loaded row count",
    {"samen_web/lib/samen/web/operator/activity_reads.ex", :mask_value} =>
      "fail-CLOSED masking: a vault-routed diff value that cannot be cast renders the literal mask \"••••\", never the stored value",
    {"samen_web/lib/samen/ui/form.ex", :opt_to_string} =>
      "guards rendering of a validation-message interpolation OPTION (a bound or count carried in the error tuple, not a database read): a value whose to_string raises falls back to its inspect text inside the message",
    {"samen_web/lib/samen/ui/gantt.ex", :frac} =>
      "guards rendering of one bar position: a point incomparable with the timeline range (mixed or malformed temporal types) is placed at the left edge (0.0) instead of crashing the render of every other bar — presentation of caller-supplied points, no read",
    {"samen_web/lib/samen/ui/nav.ex", :host_nav_extra_data} =>
      "guards a HOST-supplied nav-group resolver (navigation chrome, no data shown as empty): a raising resolver omits the host's extra nav group so it cannot take the inherited sidebar down",
    {"samen_web/lib/samen/ui/overlay.ex", :safe_call} =>
      "guards a host-supplied hit-path function: a raising one yields nil, which same_origin_path drops, so the hit renders without a link instead of crashing the overlay",
    {"samen_web/lib/samen/web/auth/totp_pending.ex", :fetch_or_create} =>
      "documented degrade (moduledoc): when the pending-secret process is down the enrolment page gets a fresh unstored secret, which the live holds in its own assigns and confirms against — the pre-F14 behaviour; nothing is read or shown as empty",
    {"samen_web/lib/samen/web/auth/totp_pending.ex", :drop} =>
      "best-effort cleanup after a confirm/disable: a pending secret that is not dropped expires on its own 15-minute TTL and is never written anywhere; nothing is shown to the user",
    {"samen_web/lib/samen/web/tenant_gate.ex", :resolved_env} =>
      "fail-SECURE: an environment that cannot be resolved is :prod, which ARMS the tenant-auth gate — the strictest posture, never an open one",
    {"samen_web/lib/samen/web/csv.ex", :emit_export_telemetry} =>
      "best-effort telemetry (documented 'never fails an export'): observability must not break the export it observes; the export result is untouched",
    {"samen_web/lib/samen/web/live.ex", :peer_data} =>
      "get_connect_info raises outside the mount lifecycle and returns nil on a dead render: either way the caller uses the 'unknown' peer, which is a stricter global per-IP rate-limit bucket — fail-closed on the limiter, nothing shown as empty",
    {"samen_web/lib/samen/web/metrics_controller.ex", :safe_scrape} =>
      "a reporter that is absent, not started or raising is indistinguishable from egress being off BY CONSTRUCTION, and every such outcome answers a non-200 with a body ('metrics egress disabled') — a scraper sees failure, never a fabricated empty 200",
    {"samen_web/lib/samen/web/operator.ex", :repo_otp_app} =>
      "pure introspection of the repo module's config (no read): a repo that exposes no otp_app yields nil, which only means no per-app config is consulted",
    {"samen_web/lib/samen/web/onboarding/wizard_controller.ex", :verified?} =>
      "fail-CLOSED capability probe (ADR-035 §5 A2): an unresolvable principal is unverified on an armed host, never an elevated default"
  }

  # Swallows that still exist, per file, AFTER the reviewed ones are subtracted. Shrink-only: a
  # phase that converts a file lowers or deletes its row. Rows include class-b helpers that are
  # correct as they are (fail-closed authz, seed probes, …) and have not yet been moved to
  # `@reviewed` with a reason — see spec/evaluation-2026-11-13/reads-rescue-inventory.md.
  @baseline %{
    "driftwood/lib/driftwood/directory.ex" => 1,
    "driftwood/lib/driftwood/operator_reveal.ex" => 1,
    "driftwood/lib/driftwood/operator_seeds.ex" => 4,
    "driftwood/lib/driftwood/reads.ex" => 6,
    "driftwood/lib/driftwood/seeds.ex" => 5,
    "driftwood/lib/driftwood_web/broker_live.ex" => 1,
    "driftwood/lib/driftwood_web/operator_impersonation_live.ex" => 2,
    "driftwood/lib/driftwood_web/page_controller.ex" => 1,
    "pawchart/lib/pawchart/auth.ex" => 1,
    "pawchart/lib/pawchart/directory.ex" => 1,
    "pawchart/lib/pawchart/operator_seeds.ex" => 2,
    "pawchart/lib/pawchart_web/clinic_reads.ex" => 5,
    "pawchart/lib/pawchart_web/operator_impersonation_live.ex" => 3
  }

  def roots, do: @roots
  def baseline, do: @baseline
  def reviewed, do: @reviewed

  @doc "Repo root, anchored on this file's compile-time path (cwd-independent)."
  def repo_root do
    __ENV__.file |> Path.dirname() |> Path.join("../../../../..") |> Path.expand()
  end

  @doc "Every `.ex` file under the scanned roots, as repo-relative paths."
  def files do
    root = repo_root()

    for tree <- @roots,
        path <- Path.wildcard(Path.join([root, tree, "**", "*.ex"])),
        do: Path.relative_to(path, root)
  end

  @doc """
  Scan one source and return the swallowing clauses as `[%{fun:, line:}]` (reviewed ones are NOT
  filtered here — `scan_file/1` does that, so a fixture can be linted without a path).
  """
  def scan_source(source, file \\ "nofile") do
    ast = Code.string_to_quoted!(source, file: file, columns: false)

    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head, body]} = node, acc when kind in [:def, :defp] ->
          {node, collect(fun_name(head), body, acc)}

        node, acc ->
          {node, acc}
      end)

    acc |> Enum.reverse() |> Enum.uniq()
  end

  @doc "Swallow count per file for `files` (default `files/0`), reviewed helpers subtracted."
  def scan(files \\ files()) do
    root = repo_root()

    files
    |> Enum.map(fn rel ->
      swallows =
        root
        |> Path.join(rel)
        |> File.read!()
        |> scan_source(rel)
        |> Enum.reject(&Map.has_key?(@reviewed, {rel, &1.fun}))

      {rel, length(swallows)}
    end)
    |> Enum.reject(fn {_rel, n} -> n == 0 end)
    |> Map.new()
  end

  @doc """
  Compare a `scan/1` result to `baseline/0`. `:ok`, or `{:error, [message]}` — each message names
  the file, the two counts and what to do.
  """
  def check(counts \\ scan(), baseline \\ @baseline) do
    problems =
      for file <- Enum.uniq(Map.keys(counts) ++ Map.keys(baseline)),
          have = Map.get(counts, file, 0),
          allowed = Map.get(baseline, file, 0),
          have != allowed do
        if have > allowed do
          "#{file}: #{have} swallowing rescue/catch clause(s), baseline allows #{allowed} — a read must not " <>
            "turn a failure into an empty result: wrap it in Samen.Web.Reads.Guard.run/3 (docs/guides/cookbook.md), " <>
            "or log/report and re-raise; do NOT raise the baseline"
        else
          "#{file}: #{have} swallowing clause(s) left but the baseline still allows #{allowed} — " <>
            "lower it to #{have} in Samen.Web.Reads.SwallowLint (the ratchet only shrinks)"
        end
      end

    if problems == [], do: :ok, else: {:error, problems}
  end

  # -- AST ------------------------------------------------------------------------

  defp fun_name({:when, _, [head | _]}), do: fun_name(head)
  defp fun_name({name, _, _}) when is_atom(name), do: name
  defp fun_name(_), do: :__unknown__

  # The def's do-block keyword list carries `:rescue` / `:catch` for a function-level handler;
  # a `try` expression carries them in its own. Collect both.
  defp collect(fun, body, acc) do
    {_body, acc} =
      Macro.prewalk(body, acc, fn
        kw, acc when is_list(kw) ->
          acc =
            Enum.reduce(kw, acc, fn
              {key, clauses}, acc when key in [:rescue, :catch] and is_list(clauses) ->
                Enum.reduce(clauses, acc, &clause(fun, key, &1, &2))

              _other, acc ->
                acc
            end)

          {kw, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp clause(fun, key, {:->, meta, [patterns, body]}, acc) do
    if catch_all?(key, patterns) and not handled?(body, bound_vars(patterns)) do
      [%{fun: fun, line: meta[:line]} | acc]
    else
      acc
    end
  end

  defp clause(_fun, _key, _other, acc), do: acc

  # rescue: one pattern, a bare/underscore variable. catch: every pattern a variable or `:exit`.
  defp catch_all?(:rescue, [pattern]), do: variable?(pattern)

  defp catch_all?(:catch, patterns),
    do: patterns != [] and Enum.all?(patterns, &(variable?(&1) or &1 in [:exit, :throw, :error]))

  defp variable?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp variable?(_), do: false

  defp bound_vars(patterns) do
    for {name, _, ctx} <- patterns, is_atom(name), is_atom(ctx), not underscored?(name), do: name
  end

  defp underscored?(name), do: name |> Atom.to_string() |> String.starts_with?("_")

  # Logged / reported / re-raised, or the bound exception is used (handed on to the caller).
  defp handled?(body, vars) do
    {_, found?} =
      Macro.prewalk(body, false, fn
        node, true -> {node, true}
        {{:., _, [{:__aliases__, _, [:Logger]}, _]}, _, _} = node, _ -> {node, true}
        {{:., _, [{:__aliases__, _, aliases}, :report]}, _, _} = node, _ -> {node, List.last(aliases) == :Guard}
        {:raise, _, _} = node, _ -> {node, true}
        {:reraise, _, _} = node, _ -> {node, true}
        {name, _, ctx} = node, _ when is_atom(name) and is_atom(ctx) -> {node, name in vars}
        node, found -> {node, found}
      end)

    found?
  end
end

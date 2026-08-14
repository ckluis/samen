defmodule Samen.Gen.App do
  @moduledoc """
  The engine behind `mix samen.gen.app` (T6.4). Pure-ish helpers that build a spec,
  validate it fail-closed, reserve abbrevs in the global registry, render the templated
  file set, and (optionally) compile + dump the schema dict so the app is gate-green.

  Kept out of the Mix.Task module so the generator is unit-testable without invoking the
  task's argv parsing.

  ## The generated shape (parametrized `pawchart`)

  A generated app mirrors `pawchart` — the proven, correct-by-construction reference:

    * ONE scope mount: `Samen.Scopes.Billing` mounted AS-IS with app-derived abbrevs.
    * ONE authored vertical resource with a `pii do` scalar vault field (masked by default,
      `:reveal_*` chokepoint, crypto-shreddable) + OrgScope policy.
    * ONE token-blind aggregate projection (so the C7 / aggregate-privacy verifiers scan a
      real aggregate plane).
    * ALL substrate migrations + a catalog-in-transaction resource migration (`Samen.Migration`).
    * A `ci.sh` wired to the full verifier gate + an anti-tautology probe on the vault path.

  ## The web layer (WS-D D2, ADR-022 — default ON)

  With `web?: true` (the default; `--headless` turns it off) the app is a RUNNING product:

    * the 5-file `*_web/` tree (thin emitted endpoint — the builder owns their salts/port/
      secret_key_base, ADR-022 — router of `Samen.Web.Router` macro mounts ONLY, a
      `use Samen.Web.Layouts` one-liner, page controller with `/healthz`, error html),
    * a `Samen.Scopes.Primitives` mount (the notifications inbox + FeatureFlag rows the
      framework surfaces read) and an OPERATOR namespace (ADR-010: a second Identity +
      Billing + Support mount — the SaaS company's own book of business),
    * web deps (`samen_web`/`phoenix`/`phoenix_live_view`/`phoenix_html`/`bandit`/
      `phoenix_pubsub`), the web plane in `application.ex`, endpoint/pubsub config.

  Derived web abbrevs follow the SHIPPED per-plane first-letter convention (driftwood
  `do*/dp*/dq*`, samen_web test host `wo*/wp*/wq*` + `wn*` primitives): with prefix
  `<p1><p2>`, Primitives is `<p1>nt/np/fl/sh/wh/ff` and the operator namespace is
  `<p1>o?` (Identity) / `<p1>p?` (Billing) / `<p1>q?` (Support). Collisions — internal
  (e.g. a prefix ending in `o/p/q/n`) or against the committed registry — FAIL CLOSED in
  `validate!/1`; pick a different `--prefix`.

  ## The JSON:API layer (WS-D D3, ADR-022 — default ON with the web layer)

  With `api?: true` (defaults to `web?`; `--headless`/`--no-api` turn it off) the app also
  ships the public `/api/v1` JSON:API surface — the demo/driftwood shape:

    * `*_web/api/{router,endpoint,key_auth_plug}.ex` — the AshJsonApi router over the
      authored `Vertical` domain, the `Plug.Builder` pipeline (KeyAuthPlug →
      `Samen.Web.Api.PageLimitClamp` → Router; the clamp is the CANONICAL samen_web plug,
      inherited — never re-emitted, design §3 drift guard), and the two-key-class
      `Authorization: Bearer` resolver over the operator Identity mount's ApiKey,
    * a per-resource DENY-BY-DEFAULT `json_api` allowlist on the authored resource (a
      field absent from `show_fields` is absent from every payload — the vault field
      `secret` and `org_id` are deliberately NOT allowlisted) bound to a BOUNDED
      `:api_read` (keyset, default_limit 50 / max_page_size 200),
    * `test/support/api_case.ex` + `test/record_api_test.exs` — the gen'd bounded/clamp/
      allowlist red-path suite, and
    * a committed `api_contract.v1.json` snapshot + the `api_contract` ci.sh step
      (dumped by `compile_and_dump!/1` post-compile).

  `--api` REQUIRES the web layer (the host router forwards `/api/v1`); an `api?: true,
  web?: false` spec fails closed in `validate!/1`.
  """

  alias Samen.AbbrevRegistry

  @enforce_keys [:module, :otp_app, :prefix, :abbrev, :target, :app_dir]
  defstruct [
    :module,
    :otp_app,
    :prefix,
    :abbrev,
    :target,
    :app_dir,
    # derived resource naming
    :resource_module,
    :resource_name,
    :resource_table,
    # derived billing abbrevs
    :billing_abbrevs,
    # derived aggregate abbrev / table
    :agg_abbrev,
    :agg_table,
    # T37h — the per-app Approvals engine client's abbrev (ADR-040 §4.7/T35 fold-in)
    :approval_abbrev,
    # WS-D D2 (ADR-022): the web layer — flag + derived web-plane abbrevs + port
    web?: true,
    port: 4050,
    primitives_abbrevs: nil,
    operator_abbrevs: nil,
    # WS-D D3 (ADR-022): the public JSON:API layer — default ON with the web layer.
    api?: true,
    # WS-D D10 (ADR-024): the fail-honest deploy layer — default OFF, opt-in via
    # `--deploy` / `mix samen.gen.deploy`. Requires the web layer (fails closed otherwise).
    deploy?: false,
    # WS-E: the selected framework END-USER surfaces to ALSO mount (`--modules`), as a list
    # of atoms from `@known_modules`. Default `[]` — OFF-by-default: an app generated WITHOUT
    # `--modules` is byte-for-byte unchanged. The mountable ones mount over mounts the app
    # already authors; `chat` is documented-not-mounted (needs a Chat scope + Presence).
    modules: []
  ]

  # The framework end-user surfaces `--modules` recognizes (WS-E router macros).
  @known_modules [:chat, :files, :csv, :search, :settings]

  # The subset the generated app can mount at ≈0 authored LOC over its EXISTING mounts:
  #   * files/search — over the Primitives mount (`File` + `SearchIndex` materialized)
  #   * csv          — over the authored `Vertical` domain (deny-by-default resource resolve)
  #   * settings     — over the `Operator` Identity namespace (`User`/`ApiKey`/`Membership`)
  # `chat` is NOT here: it needs a materialized `Samen.Scopes.Chat` mount + a running
  # `Samen.Web.Chat.Presence` — a prerequisite the generated app does not author (documented
  # in docs/guides/generators.md, emitted as a router prerequisite comment, never half-mounted).
  @mountable_modules [:files, :csv, :search, :settings]

  @doc "The framework surfaces `--modules` recognizes (`chat`/`files`/`csv`/`search`/`settings`)."
  def known_modules, do: @known_modules

  @doc "The subset of `known_modules/0` the generated app mounts at ≈0 LOC (all but `chat`)."
  def mountable_modules, do: @mountable_modules

  @doc """
  The default parent directory a generated app is created under: the parent of the
  samen_core SOURCE root, so a generated sibling's `{:samen_core, path: "../samen_core"}`
  resolves.

  `:code.priv_dir(:samen_core)` points at the app's build copy of `priv`, which is a
  SYMLINK back to the source `priv` — so `Path.expand` on the realpath of that symlink
  lands in the true source tree (not `_build`). We resolve the symlink explicitly because
  the naive `priv/../..` would otherwise sit inside `_build/<env>/lib`.
  """
  def default_target do
    priv = :code.priv_dir(:samen_core) |> to_string()

    src_priv =
      case File.read_link(priv) do
        {:ok, link_target} -> Path.expand(link_target, Path.dirname(priv))
        {:error, _} -> priv
      end

    # src_priv = .../samen_core/priv ; samen_core root = its parent ; target = grandparent.
    Path.expand(Path.join([src_priv, "..", ".."]))
  end

  @doc "Build a fully-derived generation spec from the raw options."
  def build_spec(opts) do
    module = Keyword.fetch!(opts, :module)
    prefix = Keyword.fetch!(opts, :prefix) |> to_string() |> String.downcase()
    abbrev = Keyword.fetch!(opts, :abbrev) |> to_string() |> String.downcase()
    target = Keyword.fetch!(opts, :target)

    otp_app = Macro.underscore(module) |> String.to_atom()
    app_dir = Path.join(target, to_string(otp_app))

    # The authored resource is "Record" (the clinical/domain noun); its table is
    # <abbrev>_record.
    resource_module = "#{module}.Vertical.Record"
    resource_name = "Record"
    resource_table = "#{abbrev}_record"

    # Nine Billing-scope abbrevs derived from the 2-char prefix (mirrors pawchart's
    # pbc/pbs/pbl/ppc/pbi/pby/pbu/pbe/pbv — one suffix letter per resource; luminary X10
    # corrected this comment from "Eight" — the map below always had nine entries).
    billing_abbrevs = %{
      customer: prefix <> "c",
      subscription: prefix <> "s",
      plan: prefix <> "l",
      price: prefix <> "p",
      invoice: prefix <> "i",
      payment: prefix <> "y",
      usage: prefix <> "u",
      entitlement: prefix <> "e",
      # WS-B / G7 (ADR-017): the append-only subscription-movement ledger (`mov`).
      subscription_event: prefix <> "v"
    }

    agg_abbrev = prefix <> "a"
    agg_table = "#{agg_abbrev}_record_count"

    # T37h — the per-app Approval resource's abbrev (ADR-040 §4.7/T35 fold-in). `z` is
    # unused by the prefix-derived billing (c/s/l/p/i/y/u/e/v) or aggregate (a) suffix
    # letters, so `<prefix>z` cannot collide with either family.
    approval_abbrev = prefix <> "z"

    # WS-D D2 (ADR-022): the web layer is ON by default; `--headless` (web: false)
    # reproduces the original data-only output exactly.
    web? = Keyword.get(opts, :web, true)
    # WS-D D3 (ADR-022): the JSON:API layer defaults to the web flag (`--api` is ON with
    # `--web`, OFF under `--headless`). An explicit api-without-web fails in validate!/1.
    api? = Keyword.get(opts, :api, web?)
    # WS-D D10 (ADR-024): the deploy layer is OPT-IN (default OFF). It requires the web
    # layer; `deploy?: true, web?: false` fails closed in validate_against!/2.
    deploy? = Keyword.get(opts, :deploy, false)
    # WS-E: the selected end-user surfaces. Accepts a comma-separated STRING (the CLI form),
    # a list of atoms/strings, or nil/"" → []. Membership is checked fail-closed in
    # `validate_against!/2` (an unknown surface raises there, the testable guardrail).
    modules = normalize_modules(Keyword.get(opts, :modules))
    port = Keyword.get(opts, :port, 4050)

    p1 = String.first(prefix)

    # Primitives mount abbrevs — the samen_web test-host convention (`wnt`-style is
    # pawchart's `vnt` with the host letter swapped): <p1> + the blueprint suffix.
    primitives_abbrevs =
      if web? do
        %{
          notification: p1 <> "nt",
          notification_preference: p1 <> "np",
          file: p1 <> "fl",
          search_index: p1 <> "sh",
          webhook: p1 <> "wh",
          feature_flag: p1 <> "ff"
        }
      end

    # Operator namespace abbrevs — the SHIPPED per-plane convention (driftwood
    # `do*/dp*/dq*`; samen_web test host `wo*/wp*/wq*`): <p1> + o (Identity) /
    # p (Billing) / q (Support) + the per-resource letter.
    operator_abbrevs =
      if web? do
        %{
          # Identity — accounts (Org) + tenant-admins (User)
          org: p1 <> "oo",
          user: p1 <> "ou",
          membership: p1 <> "om",
          role: p1 <> "or",
          api_key: p1 <> "ok",
          invitation: p1 <> "on",
          # ADR-035 (T02x integration) — the identity spine's two org-less resources.
          # Prefix-derived (`<p1>oc`/`<p1>ot`), NEVER `Samen.Scopes.Identity`'s literal
          # `crd`/`atk` defaults: those two are ALREADY permanently owned in the committed
          # registry (`hosts.demo.crd`/`hosts.demo.atk`), so falling back to them on every
          # generated app would collide on the first run. `do*`/`wo*`'s shipped `doc`/`dot`
          # and `woc`/`wot` prove the `<p1>o` + first-letter-of-resource shape.
          credential: p1 <> "oc",
          auth_token: p1 <> "ot",
          # T06x (this integration pass) — the identity spine's other two org-less
          # resources (T04's Session, T06's UserIdentity). Prefix-derived
          # (`<p1>os`/`<p1>oi`), NEVER `Samen.Scopes.Identity`'s literal `ses`/`uid`
          # defaults: those two are ALREADY permanently owned in the committed
          # registry (`hosts.demo.ses`/`hosts.demo.uid`), so falling back to them on
          # every generated app would collide on the first run — the exact "ses" is
          # registered to Demo.Identity.Session collision this fixes. `do*`/`wo*`'s
          # shipped `dos`/`doi` and `wos`/`woi` prove the `<p1>o` + first-letter shape.
          session: p1 <> "os",
          user_identity: p1 <> "oi",
          # ADR-038 §6.4 (T109) — the durable brute-force failure counter.
          # Prefix-derived (`<p1>ol`), NEVER `Samen.Scopes.Identity`'s literal
          # `dil` default: that is ALREADY permanently owned in the committed
          # registry (`hosts.demo.dil`), so falling back to it on every
          # generated app would collide on the first run — the same reasoning
          # `credential`/`auth_token`/`session`/`user_identity` document above.
          login_failure: p1 <> "ol",
          # Billing — each tenant's subscription TO the SaaS
          customer: p1 <> "pc",
          subscription: p1 <> "ps",
          plan: p1 <> "pp",
          price: p1 <> "pr",
          invoice: p1 <> "pi",
          payment: p1 <> "py",
          usage: p1 <> "pu",
          entitlement: p1 <> "pe",
          subscription_event: p1 <> "pv",
          # Support — the SaaS help desk (keys mirror @support_resources; abbrev suffixes
          # are independent registry-collision-driven data, not derivable from the atom).
          ticket: p1 <> "qk",
          conversation: p1 <> "qc",
          message: p1 <> "qm",
          agent: p1 <> "qg",
          sla: p1 <> "ql",
          macro: p1 <> "qn",
          csat: p1 <> "qs",
          # I6 (T79) — the CSAT request→response loop's single-use survey link.
          csat_survey_token: p1 <> "qt"
        }
      end

    %__MODULE__{
      module: module,
      otp_app: otp_app,
      prefix: prefix,
      abbrev: abbrev,
      target: target,
      app_dir: app_dir,
      resource_module: resource_module,
      resource_name: resource_name,
      resource_table: resource_table,
      billing_abbrevs: billing_abbrevs,
      agg_abbrev: agg_abbrev,
      agg_table: agg_table,
      approval_abbrev: approval_abbrev,
      web?: web?,
      api?: api?,
      deploy?: deploy?,
      modules: modules,
      port: port,
      primitives_abbrevs: primitives_abbrevs,
      operator_abbrevs: operator_abbrevs
    }
  end

  # Normalize the `--modules` value to a list of atoms. A comma-separated string is the CLI
  # form; a list (atoms or strings) is accepted for programmatic callers; nil/"" → []. The
  # mapping is whitelist-first (known surface names → their atoms) so arbitrary CLI text does
  # not mint atoms; an unrecognized token is kept as an atom so `validate_against!/2` reports
  # it fail-closed (the single, unit-testable guardrail).
  defp normalize_modules(nil), do: []
  defp normalize_modules(""), do: []

  defp normalize_modules(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&to_module_atom/1)
    |> Enum.uniq()
  end

  defp normalize_modules(value) when is_list(value) do
    value
    |> Enum.map(fn
      atom when is_atom(atom) -> atom
      str when is_binary(str) -> to_module_atom(String.downcase(String.trim(str)))
    end)
    |> Enum.uniq()
  end

  defp to_module_atom(str) do
    Enum.find(@known_modules, fn known -> Atom.to_string(known) == str end) ||
      String.to_atom(str)
  end

  @doc """
  All abbrevs the generated app reserves, as `{abbrev, owner_module_string}` pairs
  (billing scope + aggregate + authored resource; with `web?` also the Primitives mount
  + the operator namespace — WS-D D2). Load-bearing for both reservation and
  collision validation.
  """
  def reserved_pairs(%__MODULE__{} = s) do
    billing =
      Enum.map(billing_resource_order(), fn key ->
        {Map.fetch!(s.billing_abbrevs, key), "#{s.module}.Billing.#{billing_module(key)}"}
      end)

    base =
      billing ++
        [
          {s.agg_abbrev, "#{s.module}.Aggregate.RecordCountBySegment"},
          {s.abbrev, s.resource_module},
          {s.approval_abbrev, "#{s.module}.Approvals.Approval"}
        ]

    if s.web? do
      base ++ primitives_pairs(s) ++ operator_pairs(s)
    else
      base
    end
  end

  defp primitives_pairs(%__MODULE__{} = s) do
    Enum.map(primitives_resource_order(), fn key ->
      {Map.fetch!(s.primitives_abbrevs, key), "#{s.module}.Primitives.#{primitives_module(key)}"}
    end)
  end

  defp operator_pairs(%__MODULE__{} = s) do
    Enum.map(operator_resource_order(), fn key ->
      {Map.fetch!(s.operator_abbrevs, key), "#{s.module}.Operator.#{operator_module(key)}"}
    end)
  end

  @doc """
  Fail-closed validation. Raises on: bad module name, non-2-letter prefix, non-3-letter
  abbrev, any derived abbrev that collides with a DIFFERENT owner already in the registry,
  or duplicate abbrevs among the app's own derived set.
  """
  def validate!(%__MODULE__{} = s) do
    validate_against!(s, AbbrevRegistry.load())

    if File.dir?(s.app_dir) do
      raise ArgumentError,
            "target app dir already exists: #{s.app_dir}. Refusing to overwrite."
    end

    :ok
  end

  @doc """
  The registry-parametrized core of `validate!/1` — shape checks, internal-collision
  detection, and existing-owner collision against a passed-in registry map. Pure (no file
  IO, no filesystem checks) so the generator's fail-closed rules are unit-testable without
  touching the committed registry.
  """
  def validate_against!(%__MODULE__{} = s, registry) when is_map(registry) do
    # WS-D D3: the JSON:API surface is FORWARDED from the host web router
    # (`forward "/api/v1", …Web.Api.Endpoint`) — there is no API without the web layer.
    if s.api? and not s.web? do
      raise ArgumentError,
            "--api requires the web layer (the host router forwards /api/v1 to the API " <>
              "endpoint). Drop --no-web / --headless, or pass --no-api."
    end

    # WS-D D10 (ADR-024): the deploy layer's runtime.exs + fly.toml read PHX_HOST + the
    # endpoint port the web plane owns — there is no deploy scaffold without the web layer.
    if s.deploy? and not s.web? do
      raise ArgumentError,
            "--deploy requires the web layer (the emitted config/runtime.exs and fly.toml " <>
              "read PHX_HOST and the endpoint port the web plane owns). Drop " <>
              "--no-web / --headless."
    end

    # WS-E: `--modules` mounts framework LiveViews over the web layer's mounts — no web,
    # no surfaces. And every requested surface must be a KNOWN one (fail closed on typos).
    if s.modules != [] and not s.web? do
      raise ArgumentError,
            "--modules requires the web layer (the surfaces are mounted over the app's " <>
              "Primitives/Vertical/Operator mounts). Drop --no-web / --headless."
    end

    unknown = s.modules -- @known_modules

    unless unknown == [] do
      raise ArgumentError,
            "--modules has unknown surface(s): #{inspect(unknown)}. Known surfaces are " <>
              "#{inspect(@known_modules)} (mountable at ≈0 LOC: #{inspect(@mountable_modules)}; " <>
              "`chat` is documented-with-prerequisite, not auto-mounted)."
    end

    unless Regex.match?(~r/\A[A-Z][A-Za-z0-9]*\z/, s.module) do
      raise ArgumentError,
            "--module must be a valid Elixir module alias (got #{inspect(s.module)})"
    end

    unless Regex.match?(~r/\A[a-z]{2}\z/, s.prefix) do
      raise ArgumentError,
            "--prefix must be exactly 2 lowercase letters (got #{inspect(s.prefix)})"
    end

    unless Regex.match?(~r/\A[a-z]{3}\z/, s.abbrev) do
      raise ArgumentError,
            "--abbrev must be exactly 3 lowercase letters (got #{inspect(s.abbrev)})"
    end

    pairs = reserved_pairs(s)
    abbrevs = Enum.map(pairs, &elem(&1, 0))

    dupes = abbrevs -- Enum.uniq(abbrevs)

    unless dupes == [] do
      raise ArgumentError,
            "generated abbrev set has internal collisions: #{inspect(Enum.uniq(dupes))}. " <>
              "Pick a different --prefix / --abbrev."
    end

    for {abbrev, owner} <- pairs do
      case Map.get(registry, abbrev) do
        nil -> :ok
        ^owner -> :ok
        other -> raise ArgumentError,
                       "abbrev #{inspect(abbrev)} is already reserved to #{other} in the " <>
                         "global registry (#{AbbrevRegistry.path()}). Abbrevs are permanent " <>
                         "and never recycled — pick a different --prefix/--abbrev."
      end
    end

    :ok
  end

  @doc """
  Reserve the app's abbrevs via the ADR-023 allocator (`Samen.Abbrev.Allocator`), writing
  into the app's HOST namespace (`s.otp_app`) in the registry
  (`samen_core/priv/abbrev_registry.json`). Idempotent — a host+abbrev+owner already
  present is a byte no-op; fail-closed on cross-owner collision within the host namespace
  *or* the global cross-host net. Preserves the `$comment` and pretty formatting. The
  legacy global `"abbrevs"` map is left byte-untouched (the allocator only writes host
  namespaces).
  """
  def reserve_abbrevs!(%__MODULE__{} = s, path \\ AbbrevRegistry.path()) do
    for {abbrev, owner} <- reserved_pairs(s) do
      Samen.Abbrev.Allocator.reserve!(to_string(s.otp_app), abbrev, owner, path)
    end

    :ok
  end

  @doc "Render + write the full file set for the app (conditional on the web flag — WS-D D2)."
  def write_app!(%__MODULE__{} = s) do
    b = bindings(s)

    for {rel_path, template} <- files(s) do
      dest = Path.join(s.app_dir, render(rel_path, b))
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, render(template, b))
    end

    # ci.sh must be executable.
    File.chmod!(Path.join(s.app_dir, "ci.sh"), 0o755)
    :ok
  end

  @doc """
  Compile the generated app + dump its `schema.dict.json` so the committed drift baseline
  matches the compiled schema (the gate's step 1b). With the API layer (WS-D D3) also
  dumps the committed `api_contract.v1.json` structural-break snapshot so the generated
  ci.sh's `samen.verify.api_contract` step is green on first run. Runs in the app dir via
  `System.cmd` so it does not disturb the generator's own build.
  """
  def compile_and_dump!(%__MODULE__{} = s) do
    run_mix!(s, ["deps.get"])
    run_mix!(s, ["compile", "--warnings-as-errors"])
    run_mix!(s, ["samen.catalog.dump", "--output", "schema.dict.json"])

    if s.api? do
      run_mix!(s, ["samen.verify.api_contract", "--version", "v1", "--update"])
    end

    :ok
  end

  defp run_mix!(%__MODULE__{app_dir: dir} = s, args) do
    env = [{"MIX_ENV", "test"}, {"MIX_QUIET", "1"}]

    case System.cmd("mix", args, cd: dir, env: env, stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, code} ->
        raise "samen.gen.app post-step `mix #{Enum.join(args, " ")}` failed (exit #{code}) " <>
                "in #{s.app_dir}:\n#{out}"
    end
  end

  # ------------------------------------------------------------------ helpers

  defp billing_resource_order,
    do: [
      :customer,
      :subscription,
      :plan,
      :price,
      :invoice,
      :payment,
      :usage,
      :entitlement,
      :subscription_event
    ]

  defp billing_module(:customer), do: "Customer"
  defp billing_module(:subscription), do: "Subscription"
  defp billing_module(:plan), do: "Plan"
  defp billing_module(:price), do: "Price"
  defp billing_module(:invoice), do: "Invoice"
  defp billing_module(:payment), do: "Payment"
  defp billing_module(:usage), do: "Usage"
  defp billing_module(:entitlement), do: "Entitlement"
  defp billing_module(:subscription_event), do: "SubscriptionEvent"

  defp primitives_resource_order,
    do: [:notification, :notification_preference, :file, :search_index, :webhook, :feature_flag]

  defp primitives_module(:notification), do: "Notification"
  defp primitives_module(:notification_preference), do: "NotificationPreference"
  defp primitives_module(:file), do: "File"
  defp primitives_module(:search_index), do: "SearchIndex"
  defp primitives_module(:webhook), do: "Webhook"
  defp primitives_module(:feature_flag), do: "FeatureFlag"

  # P12 (T79 verify) — the Support-scope resource kinds, as a SINGLE canonical ordered
  # list. `operator_resource_order/0` below splices this in directly (pure membership +
  # order, no per-atom data — the one site that WAS a byte-for-byte duplicate of this
  # list, now DRYed). The other three Support-scope sites that mention these same atoms
  # (`operator_abbrevs` in `derive!/1`, `operator_module/1`'s clauses just below, and the
  # `o_tick`/`o_conv`/… entries in `web_bindings/1`) are NOT DRYed against this list: each
  # pairs an atom with a genuinely independent piece of data — a registry-collision-driven
  # abbrev suffix, an explicit capitalized module name, or a compact binding-key alias —
  # so collapsing them into a lookup keyed by this list would couple unrelated concerns
  # (and, for `operator_module/1`, would trade a `FunctionClauseError` for a `KeyError` on
  # an unmatched atom — a real behaviour change). A 9th Support resource still needs an
  # entry in all four places; this list is the anchor a future author greps for first.
  @support_resources [
    :ticket,
    :conversation,
    :message,
    :agent,
    :sla,
    :macro,
    :csat,
    :csat_survey_token
  ]

  # Identity → Billing → Support, mirroring the Driftwood.Operator mount order.
  defp operator_resource_order,
    do: [
      :org,
      :user,
      :membership,
      :role,
      :api_key,
      :invitation,
      :credential,
      :auth_token,
      :session,
      :user_identity,
      :login_failure,
      :customer,
      :subscription,
      :plan,
      :price,
      :invoice,
      :payment,
      :usage,
      :entitlement,
      :subscription_event
    ] ++ @support_resources

  defp operator_module(:org), do: "Org"
  defp operator_module(:user), do: "User"
  defp operator_module(:membership), do: "Membership"
  defp operator_module(:role), do: "Role"
  defp operator_module(:api_key), do: "ApiKey"
  defp operator_module(:invitation), do: "Invitation"
  defp operator_module(:credential), do: "Credential"
  defp operator_module(:auth_token), do: "AuthToken"
  defp operator_module(:session), do: "Session"
  defp operator_module(:user_identity), do: "UserIdentity"
  defp operator_module(:login_failure), do: "LoginFailure"
  defp operator_module(:customer), do: "Customer"
  defp operator_module(:subscription), do: "Subscription"
  defp operator_module(:plan), do: "Plan"
  defp operator_module(:price), do: "Price"
  defp operator_module(:invoice), do: "Invoice"
  defp operator_module(:payment), do: "Payment"
  defp operator_module(:usage), do: "Usage"
  defp operator_module(:entitlement), do: "Entitlement"
  defp operator_module(:subscription_event), do: "SubscriptionEvent"
  # Support scope (keys mirror @support_resources above) — explicit strings, not a
  # lookup keyed by that list: a map-based rewrite would turn a typo'd/unmatched atom's
  # `FunctionClauseError` into a `KeyError`, a real behaviour change to this generator.
  defp operator_module(:ticket), do: "Ticket"
  defp operator_module(:conversation), do: "Conversation"
  defp operator_module(:message), do: "Message"
  defp operator_module(:agent), do: "Agent"
  defp operator_module(:sla), do: "Sla"
  defp operator_module(:macro), do: "Macro"
  defp operator_module(:csat), do: "Csat"
  defp operator_module(:csat_survey_token), do: "CsatSurveyToken"

  @doc false
  # The template variable bindings. Every `<%= key %>` in a template is replaced by
  # bindings[key] (string). A tiny, dependency-free substitution engine (no EEx) keeps the
  # generator's own compile free of the target app's runtime.
  def bindings(%__MODULE__{} = s) do
    ba = s.billing_abbrevs

    base = %{
      "module" => s.module,
      "otp_app" => to_string(s.otp_app),
      "samen_core_path" => samen_core_rel_path(s),
      "prefix" => s.prefix,
      "abbrev" => s.abbrev,
      "resource_module" => s.resource_module,
      "resource_name" => s.resource_name,
      "resource_table" => s.resource_table,
      "agg_abbrev" => s.agg_abbrev,
      "agg_table" => s.agg_table,
      "approval_abbrev" => s.approval_abbrev,
      "bc" => ba.customer,
      "bs" => ba.subscription,
      "bl" => ba.plan,
      "bp" => ba.price,
      "bi" => ba.invoice,
      "by" => ba.payment,
      "bu" => ba.usage,
      "be" => ba.entitlement,
      "bv" => ba.subscription_event
    }

    if s.web?, do: Map.merge(base, web_bindings(s)), else: base
  end

  # WS-D D2 (ADR-022): the web-layer bindings. The endpoint secrets/salts are emitted as
  # visible LOCAL DEV/DOGFOOD constants (the pawchart idiom) — the builder OWNS them (the
  # ADR-022 thin-endpoint decision); a real deployment replaces them (WS-D D10 runtime.exs).
  defp web_bindings(%__MODULE__{} = s) do
    pa = s.primitives_abbrevs
    oa = s.operator_abbrevs

    %{
      "samen_web_path" => samen_web_rel_path(s),
      "http_port" => to_string(s.port),
      # ≥64 bytes by construction (pad to 72), deterministic per app.
      "secret_key_base" =>
        String.pad_trailing("#{s.otp_app}_local_dogfood_secret_key_base_", 72, "0"),
      # The well-known operator org anchor (ADR-010; `Samen.Web.Operator.org_id/1`
      # resolution step 2 reads it from app env). Seeds (`--seeds`, D4) anchor the
      # operator book of business on this id.
      "operator_org_id" => "0f000000-0000-4000-8000-0000000000aa",
      "p_nt" => pa.notification,
      "p_np" => pa.notification_preference,
      "p_fl" => pa.file,
      "p_sh" => pa.search_index,
      "p_wh" => pa.webhook,
      "p_ff" => pa.feature_flag,
      "o_org" => oa.org,
      "o_user" => oa.user,
      "o_mem" => oa.membership,
      "o_role" => oa.role,
      "o_key" => oa.api_key,
      "o_invite" => oa.invitation,
      "o_cred" => oa.credential,
      "o_atok" => oa.auth_token,
      "o_sess" => oa.session,
      "o_uid" => oa.user_identity,
      "o_lgf" => oa.login_failure,
      "o_cus" => oa.customer,
      "o_sub" => oa.subscription,
      "o_plan" => oa.plan,
      "o_price" => oa.price,
      "o_invoice" => oa.invoice,
      "o_pay" => oa.payment,
      "o_usage" => oa.usage,
      "o_ent" => oa.entitlement,
      "o_sev" => oa.subscription_event,
      # Support scope (keys mirror @support_resources above) — binding-key aliases are
      # independent compact template-variable names, not derivable from the atom.
      "o_tick" => oa.ticket,
      "o_conv" => oa.conversation,
      "o_msg" => oa.message,
      "o_agent" => oa.agent,
      "o_sla" => oa.sla,
      "o_macro" => oa.macro,
      "o_csat" => oa.csat,
      "o_csat_token" => oa.csat_survey_token,
      # WS-E `--modules` seams. Each is "" for a default (no-`--modules`) app, so the
      # rendered router/landing are byte-for-byte unchanged; they carry content only when a
      # surface is selected. Values are computed with `s.module` interpolated DIRECTLY (never
      # via a nested `<%= module %>`) so `render/2`'s single substitution pass is exact.
      "module_mounts" => module_mounts_binding(s),
      "root_route" => root_route_binding(s),
      "menu_nav_items" => menu_nav_items_binding(s),
      "home_surfaces" => home_surfaces_binding(s)
    }
  end

  # --------------------------------------------------------------- WS-E `--modules` seams

  # True when the app should ship the `Samen.UI` menu landing (`HomeLive` at `/`): the web
  # layer is on AND at least one MOUNTABLE surface was selected (a `chat`-only request mounts
  # nothing, so no menu is emitted).
  defp home?(%__MODULE__{web?: web?, modules: mods}),
    do: web? and Enum.any?(mods, &(&1 in @mountable_modules))

  defp selected_mountable(%__MODULE__{modules: mods}),
    do: Enum.filter(@mountable_modules, &(&1 in mods))

  # The `<%= module_mounts %>` router block: the framework surface macro calls (files/search
  # over Primitives, csv over Vertical, settings over Operator), plus — when `chat` was
  # requested — a documented prerequisite comment (NOT a mount). "" when nothing was selected.
  defp module_mounts_binding(%__MODULE__{modules: []}), do: ""

  defp module_mounts_binding(%__MODULE__{module: mod} = s) do
    mounts = Enum.map(selected_mountable(s), &mount_line(&1, mod))
    chat = if :chat in s.modules, do: [chat_prerequisite_comment(mod)], else: []

    body = mounts ++ chat

    case body do
      [] ->
        ""

      lines ->
        joined = Enum.map_join(s.modules, ",", &Atom.to_string/1)

        "\n\n" <>
          "    # --- Selected end-user surfaces (--modules #{joined}) — WS-E framework\n" <>
          "    #     macros, mounted over this app's existing mounts at ≈0 authored LOC.\n" <>
          Enum.join(lines, "\n")
    end
  end

  # Each mountable surface carries the `@current_org_labels` seam (the `:authn`
  # prod gate — see the router template) so a generated prod app never resolves an
  # arbitrary org/user via `?org=`/`?user=`.
  #
  # B-SEC (luminary pre-merge) — that seam alone was NOT the whole guarantee it claimed to
  # be: `Samen.Web.CurrentOrg.resolve/3` runs in `mount/3`, and every framework tenant
  # LiveView then re-derived the org from `params["org"]` in `handle_params/3`, which LV
  # 1.2.9 runs on the initial DEAD RENDER. The seam is now backed by two structural
  # controls the route macros themselves emit — `{Samen.Web.TenantAuthz, :require_tenant}`
  # on every tenant `live_session` (the on_mount halt that preempts `handle_params`) and
  # `Samen.Web.CurrentOrg.reresolve/2` in every tenant `handle_params` (a `?org=` may only
  # SELECT among the principal's authorized orgs) — so the claim holds by construction and
  # a generated app inherits both at ≈0 authored LOC. The settings mount ALSO opts into
  # `spine_totp: true`: this app mounts the framework Identity spine, so its
  # `/settings/security` surface exposes the REAL TOTP-enrollment route
  # (`/settings/security/2fa`) instead of the honest "managed by your identity
  # provider" placeholder — 2FA is reachable, not dormant (Addendum 2).
  defp mount_line(:files, mod),
    do: "    samen_files_routes(:files, #{mod}.Primitives, repo: #{mod}.Repo, labels: @current_org_labels)"

  defp mount_line(:search, mod),
    do: "    samen_search_routes(:search, #{mod}.Primitives, repo: #{mod}.Repo, labels: @current_org_labels)"

  defp mount_line(:csv, mod),
    do: "    samen_csv_routes(:csv, #{mod}.Vertical, repo: #{mod}.Repo, labels: @current_org_labels)"

  defp mount_line(:settings, mod),
    do:
      "    samen_settings_routes(:settings, #{mod}.Operator,\n" <>
        "      repo: #{mod}.Repo,\n" <>
        "      labels: @current_org_labels,\n" <>
        "      spine_totp: true\n" <>
        "    )"

  defp chat_prerequisite_comment(mod) do
    "    # chat requested but NOT auto-mounted (≈0-LOC adoption not possible): it needs a\n" <>
      "    # materialized Samen.Scopes.Chat mount + {Samen.Web.Chat.Presence, pubsub_server:\n" <>
      "    # #{mod}.PubSub} in the supervision tree. After authoring those, mount it with\n" <>
      "    #   samen_chat_routes(:chat, #{mod}.Chat, repo: #{mod}.Repo, labels: %{pubsub: #{mod}.PubSub})\n" <>
      "    # See docs/guides/generators.md → \"Mountable surfaces\"."
  end

  # The `<%= root_route %>` seam: swap `/` to the `Samen.UI` menu landing (`HomeLive`) when a
  # mountable surface is selected; otherwise the DEFAULT plain PageController index (byte-exact
  # to today — the off-by-default guarantee).
  # NB: the `/` route lives inside `scope "/", <App>Web do`, which ALIASES the scope — so the
  # LiveView is named RELATIVE to `<App>Web` (a fully-qualified `<App>Web.HomeLive` would
  # double-prefix to `<App>Web.<App>Web.HomeLive`). Same reason `PageController` is bare here.
  defp root_route_binding(%__MODULE__{} = s) do
    if home?(s) do
      ~s|live("/", HomeLive)|
    else
      ~s|get("/", PageController, :index)|
    end
  end

  # The `<%= menu_nav_items %>` seam: the `Samen.UI.nav_item`s for the `:extra` "Product" nav
  # group in `HomeLive` (only emitted when `home?/1`). "" otherwise. The `\#{@org_id}` is a
  # LITERAL HEEx interpolation preserved into the emitted template (escaped so it is not
  # interpolated here at generation time).
  defp menu_nav_items_binding(%__MODULE__{} = s) do
    s
    |> selected_mountable()
    |> Enum.map_join("\n", &nav_item_line/1)
  end

  defp nav_item_line(:files),
    do: ~s(                <.nav_item label="Files" href={"/files?org=\#{@org_id}"} />)

  defp nav_item_line(:search),
    do: ~s(                <.nav_item label="Search" href={"/search?org=\#{@org_id}"} />)

  defp nav_item_line(:csv),
    do: ~s(                <.nav_item label="CSV import" href={"/csv/import/record?org=\#{@org_id}"} />)

  defp nav_item_line(:settings),
    do: ~s(                <.nav_item label="Settings" href={"/settings?org=\#{@org_id}"} />)

  # The `<%= home_surfaces %>` seam (X1 / ADR-045 §4.1): the LIST of inherited `module_nav/1`
  # groups this app's router ACTUALLY mounts, passed as `surfaces={...}` so the framework nav
  # renders ONLY mounted groups and never a dead link (NoRouteError on the first click). The
  # generated router (see `router_ex_api.eex`) mounts `samen_module_routes(:billing, …)` and
  # `samen_notifications_routes(…)` UNCONDITIONALLY → `:billing` + `:inbox` are always present;
  # it never mounts CRM/Support/Marketing/Automation. `--modules settings` adds the `:settings`
  # workspace item (files/search/csv are the `:extra` "Product" group, not `module_nav` groups).
  # Kept in lockstep with the router mounts above so both derive from the same `s.modules`.
  defp home_surfaces_binding(%__MODULE__{modules: mods}) do
    surfaces = [:inbox, :billing] ++ if :settings in mods, do: [:settings], else: []
    "[" <> Enum.map_join(surfaces, ", ", &inspect/1) <> "]"
  end

  @doc """
  The relative path from the generated app dir to the samen_core SOURCE root, used for the
  `{:samen_core, path: ...}` dep. Computed so a generated app resolves samen_core no matter
  where it is placed (a direct sibling → `../samen_core`; a nested scratch dir → the correct
  deeper relative path).
  """
  def samen_core_rel_path(%__MODULE__{app_dir: app_dir}) do
    samen_core_root = Path.join(default_target(), "samen_core") |> Path.expand()
    rel_path(Path.expand(app_dir), samen_core_root)
  end

  @doc """
  As `samen_core_rel_path/1`, for the samen_web SOURCE root (a sibling of samen_core) —
  the `{:samen_web, path: ...}` dep of a `--web` app (WS-D D2 / ADR-009).
  """
  def samen_web_rel_path(%__MODULE__{app_dir: app_dir}) do
    samen_web_root = Path.join(default_target(), "samen_web") |> Path.expand()
    rel_path(Path.expand(app_dir), samen_web_root)
  end

  # Relative path FROM `from_dir` TO `to_dir`, emitting `..` segments as needed (unlike
  # `Path.relative_to/2`, which returns the absolute path when `to` is not a descendant of
  # `from`). Both args must be absolute.
  defp rel_path(from_dir, to_dir) do
    from = Path.split(from_dir)
    to = Path.split(to_dir)
    common = common_prefix_length(from, to, 0)

    ups = List.duplicate("..", length(from) - common)
    downs = Enum.drop(to, common)

    case ups ++ downs do
      [] -> "."
      parts -> Path.join(parts)
    end
  end

  defp common_prefix_length([h | t1], [h | t2], n), do: common_prefix_length(t1, t2, n + 1)
  defp common_prefix_length(_, _, n), do: n

  @doc false
  def render(template, bindings) do
    Enum.reduce(bindings, template, fn {k, v}, acc ->
      String.replace(acc, "<%= #{k} %>", to_string(v))
    end)
  end

  # ------------------------------------------------------------------ file set
  # {relative_path_template, contents_template}
  defp files(%__MODULE__{web?: web?, api?: api?, deploy?: deploy?} = s) do
    base = Samen.Gen.Templates.files(web?, api?, deploy?)

    # WS-E: the `Samen.UI` menu landing rides ONLY when a mountable surface was selected —
    # so a default (no-`--modules`) app emits the exact same file set as today. Appended (not
    # threaded through Templates.files/3) so the file-set unit tests stay byte-exact.
    if home?(s) do
      base ++ [{"lib/<%= otp_app %>_web/home_live.ex", Samen.Gen.Templates.home_live_ex()}]
    else
      base
    end
  end
end

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
    # WS-D D2 (ADR-022): the web layer — flag + derived web-plane abbrevs + port
    web?: true,
    port: 4050,
    primitives_abbrevs: nil,
    operator_abbrevs: nil,
    # WS-D D3 (ADR-022): the public JSON:API layer — default ON with the web layer.
    api?: true,
    # WS-D D10 (ADR-024): the fail-honest deploy layer — default OFF, opt-in via
    # `--deploy` / `mix samen.gen.deploy`. Requires the web layer (fails closed otherwise).
    deploy?: false
  ]

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

    # Eight Billing-scope abbrevs derived from the 2-char prefix (mirrors pawchart's
    # pbc/pbs/pbl/ppc/pbi/pby/pbu/pbe — one suffix letter per resource).
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

    # WS-D D2 (ADR-022): the web layer is ON by default; `--headless` (web: false)
    # reproduces the original data-only output exactly.
    web? = Keyword.get(opts, :web, true)
    # WS-D D3 (ADR-022): the JSON:API layer defaults to the web flag (`--api` is ON with
    # `--web`, OFF under `--headless`). An explicit api-without-web fails in validate!/1.
    api? = Keyword.get(opts, :api, web?)
    # WS-D D10 (ADR-024): the deploy layer is OPT-IN (default OFF). It requires the web
    # layer; `deploy?: true, web?: false` fails closed in validate_against!/2.
    deploy? = Keyword.get(opts, :deploy, false)
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
          # Support — the SaaS help desk
          ticket: p1 <> "qk",
          conversation: p1 <> "qc",
          message: p1 <> "qm",
          agent: p1 <> "qg",
          sla: p1 <> "ql",
          macro: p1 <> "qn",
          csat: p1 <> "qs"
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
      web?: web?,
      api?: api?,
      deploy?: deploy?,
      port: port,
      primitives_abbrevs: primitives_abbrevs,
      operator_abbrevs: operator_abbrevs
    }
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
          {s.abbrev, s.resource_module}
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

  # Identity → Billing → Support, mirroring the Driftwood.Operator mount order.
  defp operator_resource_order,
    do: [
      :org,
      :user,
      :membership,
      :role,
      :api_key,
      :invitation,
      :customer,
      :subscription,
      :plan,
      :price,
      :invoice,
      :payment,
      :usage,
      :entitlement,
      :subscription_event,
      :ticket,
      :conversation,
      :message,
      :agent,
      :sla,
      :macro,
      :csat
    ]

  defp operator_module(:org), do: "Org"
  defp operator_module(:user), do: "User"
  defp operator_module(:membership), do: "Membership"
  defp operator_module(:role), do: "Role"
  defp operator_module(:api_key), do: "ApiKey"
  defp operator_module(:invitation), do: "Invitation"
  defp operator_module(:customer), do: "Customer"
  defp operator_module(:subscription), do: "Subscription"
  defp operator_module(:plan), do: "Plan"
  defp operator_module(:price), do: "Price"
  defp operator_module(:invoice), do: "Invoice"
  defp operator_module(:payment), do: "Payment"
  defp operator_module(:usage), do: "Usage"
  defp operator_module(:entitlement), do: "Entitlement"
  defp operator_module(:subscription_event), do: "SubscriptionEvent"
  defp operator_module(:ticket), do: "Ticket"
  defp operator_module(:conversation), do: "Conversation"
  defp operator_module(:message), do: "Message"
  defp operator_module(:agent), do: "Agent"
  defp operator_module(:sla), do: "Sla"
  defp operator_module(:macro), do: "Macro"
  defp operator_module(:csat), do: "Csat"

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
      "o_cus" => oa.customer,
      "o_sub" => oa.subscription,
      "o_plan" => oa.plan,
      "o_price" => oa.price,
      "o_invoice" => oa.invoice,
      "o_pay" => oa.payment,
      "o_usage" => oa.usage,
      "o_ent" => oa.entitlement,
      "o_sev" => oa.subscription_event,
      "o_tick" => oa.ticket,
      "o_conv" => oa.conversation,
      "o_msg" => oa.message,
      "o_agent" => oa.agent,
      "o_sla" => oa.sla,
      "o_macro" => oa.macro,
      "o_csat" => oa.csat
    }
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
  defp files(%__MODULE__{web?: web?, api?: api?, deploy?: deploy?}) do
    Samen.Gen.Templates.files(web?, api?, deploy?)
  end
end

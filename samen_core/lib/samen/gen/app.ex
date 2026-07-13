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
    :agg_table
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
      agg_table: agg_table
    }
  end

  @doc """
  All abbrevs the generated app reserves, as `{abbrev, owner_module_string}` pairs
  (billing scope + aggregate + authored resource). Load-bearing for both reservation and
  collision validation.
  """
  def reserved_pairs(%__MODULE__{} = s) do
    billing =
      Enum.map(billing_resource_order(), fn key ->
        {Map.fetch!(s.billing_abbrevs, key), "#{s.module}.Billing.#{billing_module(key)}"}
      end)

    billing ++
      [
        {s.agg_abbrev, "#{s.module}.Aggregate.RecordCountBySegment"},
        {s.abbrev, s.resource_module}
      ]
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
  Append the app's reserved abbrevs to the GLOBAL registry
  (`samen_core/priv/abbrev_registry.json`). Idempotent — rows already present with the
  correct owner are left untouched. Preserves the `$comment` and pretty formatting.
  """
  def reserve_abbrevs!(%__MODULE__{} = s, path \\ AbbrevRegistry.path()) do
    raw = File.read!(path)
    decoded = Jason.decode!(raw)

    abbrevs = Map.fetch!(decoded, "abbrevs")

    new_abbrevs =
      Enum.reduce(reserved_pairs(s), abbrevs, fn {abbrev, owner}, acc ->
        case Map.get(acc, abbrev) do
          nil -> Map.put(acc, abbrev, owner)
          ^owner -> acc
          other ->
            raise ArgumentError,
                  "cannot reserve #{inspect(abbrev)} for #{owner}: already owned by #{other}."
        end
      end)

    updated = Map.put(decoded, "abbrevs", new_abbrevs)
    File.write!(path, Jason.encode!(updated, pretty: true) <> "\n")
    :ok
  end

  @doc "Render + write the full file set for the app."
  def write_app!(%__MODULE__{} = s) do
    b = bindings(s)

    for {rel_path, template} <- files() do
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
  matches the compiled schema (the gate's step 1b). Runs in the app dir via `System.cmd`
  so it does not disturb the generator's own build.
  """
  def compile_and_dump!(%__MODULE__{} = s) do
    run_mix!(s, ["deps.get"])
    run_mix!(s, ["compile", "--warnings-as-errors"])
    run_mix!(s, ["samen.catalog.dump", "--output", "schema.dict.json"])
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

  @doc false
  # The template variable bindings. Every `<%= key %>` in a template is replaced by
  # bindings[key] (string). A tiny, dependency-free substitution engine (no EEx) keeps the
  # generator's own compile free of the target app's runtime.
  def bindings(%__MODULE__{} = s) do
    ba = s.billing_abbrevs

    %{
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
  defp files do
    Samen.Gen.Templates.files()
  end
end

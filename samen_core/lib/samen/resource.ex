defmodule Samen.Resource do
  @moduledoc """
  The Samen base macro (plan A1). Every resource in the foundry is declared with
  `use Samen.Resource` — one macro wires self-qualifying storage, the injected
  universal columns, the PII/catalog extensions, and (optionally) single-table
  fragment composition.

  ## Two shapes

      # a plain resource
      use Samen.Resource,
        otp_app: :my_app,
        domain: MyApp.Crm,
        data_layer: AshPostgres.DataLayer,
        abbrev: "com"

      # a resource that folds in a shared fragment (single-table composition)
      use Samen.Resource,
        otp_app: :my_app,
        domain: MyApp.Clinical,
        data_layer: AshPostgres.DataLayer,
        abbrev: "pat",
        base: Core.Person

  ## What the macro does

    1. **Validates the abbrev caller-side** (a friendly `CompileError` at the
       resource's own `use` line) and injects a first-class
       `samen do abbrev "com" end` section (S0.2 note F4 — introspectable via
       `Samen.Info.abbrev/1`, survives fragment folding) rather than a bare module
       attribute. `use Samen.Resource, abbrev: "com"` is sugar for that section.
    2. **Wires the fixed Samen extension allow-list** — `Samen.Extension` (the
       `samen` section + abbrev transformer + registry verifier + core-column
       injection), `Samen.Pii`, and `Samen.Catalog`.
    3. **Injects the universal columns** `id` / `org_id` / `inserted_at` /
       `updated_at` on every resource (via `Samen.Transformers.CoreAttributes`),
       each prefixed with the resource abbrev.
    4. **Prefixes every physical column** with `<abbrev>_` (via
       `Samen.Transformers.AbbrevStorage`) while logical `:name` is untouched.
    5. **Enforces the abbrev registry** (`Samen.Verifiers.AbbrevRegistry`):
       permanent, 3-letter-lowercase, collision-free, never-recycled.
    6. **Folds a `base:` fragment** into one physical table, guarded by the
       extension allow-list (below).

  ## Fragment composition & the extension allow-list gate (Gate-0 fix task #3)

  `base:` folds a `Spark.Dsl.Fragment` into the resource via Spark's `fragments:`
  mechanism → ONE physical table (never Postgres `INHERITS`). A fragment declares
  the extensions whose DSL it uses. Spark's own behaviour *silently unions* those
  extensions into the composing resource — so a fragment could smuggle in a DSL
  section (and its guarantees) the base macro never wired. `Samen.Resource` refuses:
  if a fragment declares a **Samen-namespace** extension outside the provided
  allow-list (`#{inspect([Samen.Extension, Samen.Pii, Samen.Catalog])}`), the
  composing resource fails to compile at its own `use` line with a clear diagnostic.

  The gate uses `Code.ensure_compiled/1` (NOT `ensure_loaded?/1`): the fragment's
  `extensions/0` is only defined at its `@before_compile`, so `ensure_loaded?/1`
  would race with compile ordering. `ensure_compiled/1` forces the fragment to
  compile first.
  """

  @abbrev_pattern ~r/\A[a-z]{3}\z/

  # The Samen extensions the base macro provides to every resource. A fragment may
  # declare (use DSL from) only these; any other Samen-namespace extension is a
  # fragment asking for a capability the base macro did not wire → fail closed.
  @provided_samen_extensions [Samen.Extension, Samen.Pii, Samen.Catalog]

  defmacro __using__(opts) do
    {abbrev, opts} = Keyword.pop(opts, :abbrev)
    {archivable, opts} = Keyword.pop(opts, :archivable, false)
    {versioned_opt, opts} = Keyword.pop(opts, :versioned, false)
    {base, ash_opts} = Keyword.pop(opts, :base)

    # E7 audit-on-write (ADR-040 §6): `versioned: true | :changes_only | :snapshot`.
    # `true` defaults to `:changes_only`; an explicit mode selects it. `:full_diff` is
    # never accepted (refused substrate-wide — it forces `require_atomic? false`).
    {versioned?, versioned_mode} = normalize_versioned!(versioned_opt, __CALLER__)

    # Validate caller-side so the diagnostic points at the resource's own `use`
    # line. Abbrev shape first, then the fragment extension gate (Gate-0 fix #3 —
    # independent of the abbrev), then the committed registry (permanence/collision).
    validate_abbrev!(abbrev, __CALLER__)

    # RED PATH gate (Gate-0 fix #3): a fragment may only require provided extensions.
    if base do
      Samen.Resource.verify_fragment_extensions!(base, __CALLER__)
    end

    validate_registry!(abbrev, __CALLER__)

    # E6 soft-delete adoption (ADR-040 §5.2/§5.9, ADR-037 §5.3, T36): `archivable:
    # true` folds ash_archival's `AshArchival.Resource` extension in alongside the
    # fixed Samen allow-list; the default (`false`) adds nothing.
    default_extensions =
      provided_samen_extensions() ++
        archival_extensions(archivable) ++ versioned_extensions(versioned?)

    ash_opts =
      ash_opts
      |> Keyword.update(:extensions, default_extensions, fn exts ->
        Enum.uniq(default_extensions ++ List.wrap(exts))
      end)
      |> maybe_put_fragments(base)

    archival_dsl = archival_dsl(archivable)
    # The generated version resource module name (ADR-040 §6.1/§6.2), matching
    # ash_paper_trail's default (`SourceResource.Version`). Its allocator-owned abbrev
    # is injected by Samen.Versioning.VersionMixin at the version module's compile.
    version_module = Module.concat(__CALLER__.module, Version)
    versioned_dsl = versioned_dsl(versioned?, versioned_mode, version_module)

    quote do
      use Ash.Resource, unquote(ash_opts)

      # First-class `samen do abbrev "..." end` section (F4). This is the source
      # of truth for the abbrev, introspectable via Samen.Info.abbrev/1. The
      # `archivable` / `versioned` flags ride alongside it (introspectable via
      # Samen.Info.archivable?/1 and Samen.Info.versioned?/1).
      samen do
        abbrev(unquote(abbrev))
        archivable(unquote(archivable))
        versioned(unquote(versioned?))
        versioned_mode(unquote(versioned_mode))
      end

      unquote(archival_dsl)
      unquote(versioned_dsl)
    end
  end

  @doc false
  def provided_samen_extensions, do: @provided_samen_extensions

  @doc """
  Reads the resource's abbrev out of DSL state, fail-closed.

  Called by `Samen.Transformers.AbbrevStorage`. Reads the first-class `samen`
  section (F4). Raises `Spark.Error.DslError` naming the offending module if the
  abbrev is missing or malformed — self-qualifying storage is not optional. (The
  base macro's caller-side check catches the common case with a friendlier message;
  this is the defense-in-depth second line for resources built without the macro.)
  """
  def fetch_abbrev!(dsl_state) do
    module = Spark.Dsl.Transformer.get_persisted(dsl_state, :module)
    abbrev = Spark.Dsl.Extension.get_opt(dsl_state, [:samen], :abbrev, nil)

    if is_binary(abbrev) and Regex.match?(@abbrev_pattern, abbrev) do
      abbrev
    else
      raise Spark.Error.DslError,
        module: module,
        path: [:samen, :abbrev],
        message:
          "Samen.Resource requires a 3-letter lowercase `abbrev:` (e.g. " <>
            "`abbrev: \"com\"`). Self-qualifying storage is not optional: every " <>
            "column carries its resource's permanent abbrev. Got: " <> inspect(abbrev)
    end
  end

  @doc false
  # RED PATH enforcement (Gate-0 fix #3). Verifies every Samen extension the
  # fragment declares is one the base macro provides.
  def verify_fragment_extensions!(base, caller) do
    fragment = Macro.expand(base, caller)

    # Force the fragment to compile first (compile-time dependency): the fragment's
    # extensions/0 is only defined at its @before_compile, so ensure_loaded?/1 can
    # race with compile ordering. ensure_compiled/1 blocks until it is available.
    loaded? =
      is_atom(fragment) and
        match?({:module, ^fragment}, Code.ensure_compiled(fragment)) and
        function_exported?(fragment, :extensions, 0)

    unless loaded? do
      raise %CompileError{
        file: caller.file,
        line: caller.line,
        description:
          "use Samen.Resource, base: #{inspect(fragment)} — `base:` must be a " <>
            "compiled Spark.Dsl.Fragment (defining extensions/0). Got: #{inspect(fragment)}"
      }
    end

    declared = fragment.extensions()

    # Only police Samen-namespace extensions; Ash's own defaults are always present
    # and are not ours to gate.
    missing =
      declared
      |> Enum.filter(&samen_extension?/1)
      |> Enum.reject(&(&1 in @provided_samen_extensions))

    unless missing == [] do
      raise %CompileError{
        file: caller.file,
        line: caller.line,
        description:
          "Fragment #{inspect(fragment)} declares extension(s) #{inspect(missing)} " <>
            "that `use Samen.Resource` does not provide. A composed resource cannot " <>
            "fold in a fragment whose DSL the base macro never wired — self-qualifying " <>
            "storage, catalog, and PII routing are the only Samen extensions provided " <>
            "(#{inspect(@provided_samen_extensions)}). Either drop the extension from " <>
            "the fragment or extend Samen.Resource to provide it."
      }
    end

    :ok
  end

  defp samen_extension?(module) when is_atom(module) do
    case Atom.to_string(module) do
      "Elixir.Samen." <> _ -> true
      _ -> false
    end
  end

  defp samen_extension?(_), do: false

  defp maybe_put_fragments(ash_opts, nil), do: ash_opts

  defp maybe_put_fragments(ash_opts, base) do
    Keyword.update(ash_opts, :fragments, [base], fn frags ->
      Enum.uniq([base | List.wrap(frags)])
    end)
  end

  # E6 soft-delete (ADR-037 §5.3): `archivable: true` folds in ash_archival's
  # resource extension; the default adds nothing.
  defp archival_extensions(true), do: [AshArchival.Resource]
  defp archival_extensions(_), do: []

  # E7 audit-on-write (ADR-037 §5.4, ADR-040 §6): `versioned` folds in
  # ash_paper_trail's resource extension; the default adds nothing.
  defp versioned_extensions(true), do: [AshPaperTrail.Resource]
  defp versioned_extensions(_), do: []

  # Normalize the `versioned:` sugar caller-side (friendly diagnostic at the resource's
  # own `use` line). `:full_diff` is explicitly refused (ADR-040 §6.3(5)).
  defp normalize_versioned!(false, _caller), do: {false, :changes_only}
  defp normalize_versioned!(nil, _caller), do: {false, :changes_only}
  defp normalize_versioned!(true, _caller), do: {true, :changes_only}
  defp normalize_versioned!(:changes_only, _caller), do: {true, :changes_only}
  defp normalize_versioned!(:snapshot, _caller), do: {true, :snapshot}

  defp normalize_versioned!(other, caller) do
    raise %CompileError{
      file: caller.file,
      line: caller.line,
      description:
        "use Samen.Resource, versioned: expects `true`, `:changes_only`, or " <>
          ":snapshot (ADR-040 §6). `:full_diff` is refused substrate-wide (it forces " <>
          "`require_atomic? false`). Got: #{inspect(other)}"
    }
  end

  # E6 soft-delete DSL (ADR-040 §5.2/§5.9, ADR-037 §5.3, T36). `archivable: true`
  # injects the archive/restore/archived/destroy_permanently actions plus the
  # ash_archival `archive` config that scopes the `is_nil(archived_at)` default
  # read filter. `archivable: false` (the default) injects nothing.
  defp archival_dsl(false), do: nil

  defp archival_dsl(true) do
    quote do
      actions do
        # Soft destroy: ash_archival's SetupArchival stamps archived_at; the
        # Samen.Archival.Archive change adds audit + idempotence (ADR-040 §5.2).
        # Non-primary + non-atomic so it composes with the default hard destroy.
        destroy :archive do
          primary?(false)
          require_atomic?(false)
          change(Samen.Archival.Archive)
        end

        # Restore: clear archived_at + audit the archived → live transition.
        update :restore do
          primary?(false)
          require_atomic?(false)
          change(Samen.Archival.Restore)
        end

        # The trash read: shows ONLY archived rows (Samen.Archival.OnlyArchived).
        read :archived do
          prepare(Samen.Archival.OnlyArchived)
        end

        # A real hard delete, retained for erasure/GC paths.
        destroy :destroy_permanently do
          primary?(false)
        end
      end

      archive do
        # Preparation variant (ADR-037 §5.3): base_filter? stays the package default
        # (false) so :restore is possible. The trash read shows archived rows; the
        # terminal destroy stays a real hard delete.
        exclude_read_actions([:archived])
        exclude_destroy_actions([:destroy_permanently])
      end
    end
  end

  # E7 audit-on-write DSL (ADR-040 §6). `versioned` injects the ash_paper_trail
  # `paper_trail` section configuring the generated `<Resource>.Version`. Nothing when
  # not versioned.
  defp versioned_dsl(false, _mode, _version_module), do: nil

  defp versioned_dsl(true, mode, version_module) do
    quote do
      paper_trail do
        # §6.3(5): :changes_only (default) or :snapshot. :full_diff never reaches here
        # (refused in normalize_versioned!/2).
        change_tracking_mode(unquote(mode))

        # INV-1 / §6.3(2): version rows NEVER persist raw action inputs (pre-vault
        # plaintext / vt_* tokens). FALSE, forever, on every samen resource. Belt-and-
        # braces over the package's own sensitive-input redaction; guarded by a test.
        store_action_inputs?(false)

        # INV-1 / §6.3: keep values (`:display`) so vault-routed attributes are versioned
        # as their `vt_*` TOKEN — token-only BY CONSTRUCTION via `Samen.Type.VaultField`'s
        # dump face (never plaintext), which §6.3(1) makes the guarantee. NOTE: in the
        # samen substrate every `sensitive?` attribute IS a vault field (all PII routes
        # through the vault; a non-vault `sensitive?` attribute would be a discipline
        # violation caught upstream) — so `:display` never versions a non-vault sensitive
        # value. `Samen.VersionedSensitiveTest` guards this: a versioned resource whose
        # `sensitive?` attribute is NOT a VaultField would fail, flagging that this must
        # switch to ignoring that specific attribute (§6.3(3)). `:ignore` is NOT usable
        # here: it would drop the vault fields too (they are `sensitive?`), defeating
        # §6.3(1)'s token-in-diff requirement.
        sensitive_attributes(:display)

        # The universal write timestamps are noise in a change diff (every write bumps
        # updated_at); the version row's own version_inserted_at is the authoritative
        # instant. Excluding them keeps :snapshot/:changes_only diffs signal-only.
        ignore_attributes([:inserted_at, :updated_at])

        # §6.2: mirror org_id onto the version row as a real column (populated from the
        # source record), so version history is OrgScope-boundable exactly like the
        # source table — tenant plane resolves, operator plane masks.
        attributes_as_attributes([:org_id])

        # §6.4: an archivable+versioned resource's soft-destroy (`:archive`) records a
        # version — the archive is itself a recorded change; a terminal hard destroy also
        # records its final version. Keep create-a-version-on-destroy on.
        create_version_on_destroy?(true)

        # A samen resource can be hard-destroyed (`:destroy_permanently`, crypto-shred,
        # GC), so the version must survive its source's deletion — no FK back to the
        # source row (ash_paper_trail's own guidance when actual deletion is allowed).
        # Version rows stay org-scoped/keyset-bounded via the mirrored org_id (§6.2), not
        # a source FK; crypto-shred degrades the tokens to masked like every other tier
        # (§6.4), it does not chase version rows.
        reference_source?(false)

        # §6.2 (INV-3): the generated version resource gets FULL samen governance —
        # allocator-owned abbrev + prefixed columns + org_id + catalog + no_plaintext_pii
        # roster + OrgScope policies — by carrying the same samen extensions + the policy
        # authorizer any governed table does. The abbrev + OrgScope policies are injected
        # by the mixin (abbrev reverse-looked-up from the registry; never pinned).
        version_extensions(
          extensions: [Samen.Extension, Samen.Pii, Samen.Catalog],
          authorizers: [Ash.Policy.Authorizer]
        )

        mixin({Samen.Versioning.VersionMixin, :inject, [unquote(version_module)]})
      end
    end
  end

  # Caller-side abbrev REGISTRY enforcement (permanent / 3-letter / collision-free
  # / never-recycled). Done in the macro (not only the Spark verifier) because a
  # Spark verifier raising during `Code.compile_string` does NOT reliably abort the
  # compile in this Ash/Spark version, whereas a raise here hard-fails at the `use`
  # line — the fail-closed guarantee the registry needs. The verifier remains as
  # defense-in-depth + introspection.
  defp validate_registry!(abbrev, caller) do
    module = caller.module

    if is_binary(abbrev) and is_atom(module) and not is_nil(module) do
      registry = Samen.AbbrevRegistry.load()

      case Samen.AbbrevRegistry.validate(registry, abbrev, inspect(module)) do
        :ok ->
          :ok

        {:error, reason} ->
          raise %CompileError{file: caller.file, line: caller.line, description: reason}
      end
    end
  end

  # Caller-local abbrev validation with a friendly message. `nil` (no abbrev given)
  # and a malformed abbrev both fail here; the registry verifier is the durable
  # backstop that also enforces permanence/collision.
  defp validate_abbrev!(abbrev, caller) do
    unless is_binary(abbrev) and Regex.match?(@abbrev_pattern, abbrev) do
      raise %CompileError{
        file: caller.file,
        line: caller.line,
        description:
          "use Samen.Resource requires `abbrev: \"xxx\"` (3 lowercase letters). " <>
            "Self-qualifying storage is mandatory — every column is prefixed with " <>
            "its resource abbrev. Got: #{inspect(abbrev)}"
      }
    end
  end
end

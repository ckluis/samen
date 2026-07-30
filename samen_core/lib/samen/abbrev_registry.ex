defmodule Samen.AbbrevRegistry do
  @moduledoc """
  The **abbrev registry**: a committed, permanent record mapping every 3-letter
  storage abbrev to the resource module that owns it (A5 in the plan; doc
  §"Self-qualifying storage" — "no rename drift"; memory: "permanent/never-recycled
  like a ticker").

  ## Why a committed file

  A resource's abbrev is projected into the DB column names, CDC rows, logs, and
  catalog. Once data exists under `com_name`, that prefix can never change without
  rewriting history — so abbrevs are treated exactly like stock tickers:
  **permanent, never recycled, one owner forever.** The registry is the durable
  source of truth for that invariant, committed to the repo (`priv/abbrev_registry.json`)
  and checked at compile time by `Samen.Verifiers.AbbrevRegistry`.

  ## Format

  The **legacy / global** namespace (the shape the committed file uses today, 263
  entries) is a flat `"abbrevs"` map — this is the cross-host collision net:

      {
        "abbrevs": {
          "com": "MyApp.Crm.Contact",
          "cpy": "MyApp.Crm.Company"
        }
      }

  Keys are abbrevs (3-letter lowercase); values are the owning resource module's
  fully-qualified name.

  ## Host-namespaced schema (ADR-023, ADR-006 Option B)

  The schema optionally gains a `"hosts"` object keying `(host, abbrev) → owner`, so
  two *different* apps may legitimately own the same physical 3-letter prefix (e.g.
  `demo`'s `cmp` and `driftwood`'s `cmp` are distinct, both permanently owned):

      {
        "abbrevs": { … the global cross-host net … },
        "hosts": {
          "widgetco": { "wid": "Widgetco.Vertical.Widget" }
        }
      }

  The `"hosts"` key is **optional** — a file without it (the committed 263-entry
  registry) reads byte-identically. `load/0` returns the **flat global view** (the
  union of `"abbrevs"` and every host namespace) so the compile-time verifier and every
  existing reader keep working unchanged (the compat shim). Host-scoped reads/writes go
  through `load_namespaced/1`, `owner/2`, and `validate_host/4`.

  ## Bounded scope (ADR-023 §2 / §4)

  WS-D D8 lands the **allocator** (`mix samen.abbrev.reserve`) + the **host-namespaced
  schema it writes** + this **read-compat shim**. Fully partitioning the compile-time
  verifier (`Samen.Verifiers.AbbrevRegistry`) + every reader to be host-aware is a
  50+ file change (ADR-006 §3) and ships as the phased follow-on ADR-025 — the verifier
  still reads the flattened global view here, which is correct **while the flattening is
  lossless**. `"hosts"` is no longer empty in-tree — it carries a handful of
  non-conflicting host allocations (the F3 consent-ledger abbrevs, one per host, all
  distinct) — but every host abbrev still resolves to exactly one owner across all
  namespaces, so the flat union equals the intended view. A fail-closed **tripwire** now
  enforces that invariant: `flatten_conflicts/1` detects any abbrev owned by two
  namespaces with different owners, and `load/0` RAISES (naming ADR-025) the day a real
  cross-host prefix reuse lands — turning ADR-025's latent risk into a loud,
  self-enforcing gate rather than a silent false-positive.

  ## Invariants enforced by the verifier

    * every abbrev is **3-letter lowercase** (`^[a-z]{3}$`);
    * **no collision** — two resources may not claim the same abbrev;
    * **no rename** — a resource may not change the abbrev it is registered under;
    * **registered** — a resource whose abbrev is missing from the registry fails
      compile (you must commit the registry entry to permanently reserve it).

  Removing/recycling is prevented by the same rules: the registry is append-mostly,
  and an abbrev listed for resource A cannot be handed to resource B.
  """

  @registry_path Path.join([:code.priv_dir(:samen_core) |> to_string(), "abbrev_registry.json"])

  @abbrev_pattern ~r/\A[a-z]{3}\z/

  @doc "Absolute path to the committed registry file."
  @spec path() :: String.t()
  def path, do: @registry_path

  @doc "The 3-letter-lowercase pattern every abbrev must match."
  @spec pattern() :: Regex.t()
  def pattern, do: @abbrev_pattern

  @doc """
  Loads the registry as a `%{abbrev => owner_module_string}` map.

  Raises if the file is missing or malformed — a corrupt registry must never
  fail *open* (an unreadable registry cannot be allowed to silently permit any
  abbrev). Callers in the compile path surface this as a build failure.
  """
  @spec load() :: %{optional(String.t()) => String.t()}
  def load do
    load(@registry_path)
  end

  @doc """
  Loads the registry as a flat global `%{abbrev => owner}` map — the **compat shim**.

  Returns the union of the legacy `"abbrevs"` map and every host namespace, so the
  compile-time verifier and every existing flat reader keep working unchanged against
  the host-namespaced schema. A file without a `"hosts"` key (the committed 263-entry
  registry) reads byte-identically to before.
  """
  @spec load(String.t()) :: %{optional(String.t()) => String.t()}
  def load(registry_path) do
    namespaced = load_namespaced(registry_path)

    # ADR-025 fail-closed tripwire. The flattened view is lossless ONLY while no abbrev
    # is owned by two namespaces with different owners. The day a real cross-host prefix
    # reuse lands (or a host owner disagrees with the global net), flattening would
    # silently drop/override an owner and the flattened-view verifier would false-positive
    # a collision on the other resource. Refuse to compile instead — see flatten_conflicts/1.
    case flatten_conflicts(namespaced) do
      [] -> flatten(namespaced)
      conflicts -> raise flatten_conflict_message(conflicts, registry_path)
    end
  end

  @doc """
  Reverse lookup: returns the abbrev reserved for `module` (an atom or its
  `inspect/1` string), fail-closed.

  The abbrev is matched against `inspect(module)` — the exact owner form the
  sanctioned allocator (`mix samen.abbrev.reserve`) and the compile-time verifier
  both use. Raises if no abbrev is reserved for the module: this is the enforcement
  point for the E7 generated `<Resource>.Version` resources (ADR-040 §6.2), whose
  allocator-owned abbrev is injected into their `samen do abbrev end` section at
  build time (never pinned in code) — an unreserved version resource must fail the
  build, not compile with an invented prefix.
  """
  @spec abbrev_for!(module() | String.t()) :: String.t()
  def abbrev_for!(module) do
    owner = if is_binary(module), do: module, else: inspect(module)

    case Enum.find(load(), fn {_abbrev, o} -> o == owner end) do
      {abbrev, _owner} ->
        abbrev

      nil ->
        raise """
        No storage abbrev is reserved for #{owner} in the abbrev registry \
        (#{path()}). Reserve one through the sanctioned allocator \
        (`mix samen.abbrev.reserve --host <host> --owner #{owner} --propose`) — the \
        registry is HANDS-OFF and never hand-edited. A generated version resource \
        (ADR-040 §6.2) whose abbrev is not reserved cannot compile.
        """
    end
  end

  # The lossless flatten: host entries fill in first, the authoritative global net
  # overwrites. Only called once flatten_conflicts/1 has proven the view is unambiguous.
  defp flatten(%{global: global, hosts: hosts}) do
    Enum.reduce(hosts, %{}, fn {_host, ns}, acc -> Map.merge(acc, ns) end)
    |> Map.merge(global)
  end

  @doc """
  Loads the registry preserving host namespacing (ADR-023). Returns
  `%{global: %{abbrev => owner}, hosts: %{host => %{abbrev => owner}}}`.

  The `"hosts"` key is optional; a legacy flat file yields `hosts: %{}`.
  """
  @spec load_namespaced() :: %{global: map(), hosts: map()}
  def load_namespaced, do: load_namespaced(@registry_path)

  @spec load_namespaced(String.t()) :: %{global: map(), hosts: map()}
  def load_namespaced(registry_path) do
    case File.read(registry_path) do
      {:ok, contents} ->
        decode!(contents, registry_path)

      {:error, reason} ->
        raise """
        Samen abbrev registry missing or unreadable at #{registry_path} \
        (#{:file.format_error(reason)}). The registry is the permanent source of \
        truth for storage abbrevs and must be committed to the repo. Refusing to \
        compile — a missing registry cannot be allowed to permit arbitrary abbrevs.
        """
    end
  end

  defp decode!(contents, registry_path) do
    case Jason.decode(contents) do
      {:ok, %{"abbrevs" => abbrevs} = obj} when is_map(abbrevs) ->
        %{global: abbrevs, hosts: decode_hosts!(obj, registry_path)}

      {:ok, _other} ->
        raise "Samen abbrev registry at #{registry_path} must be a JSON object with an \"abbrevs\" map."

      {:error, %Jason.DecodeError{} = err} ->
        raise "Samen abbrev registry at #{registry_path} is not valid JSON: #{Exception.message(err)}"
    end
  end

  defp decode_hosts!(obj, registry_path) do
    case Map.get(obj, "hosts") do
      nil ->
        %{}

      hosts when is_map(hosts) ->
        Enum.each(hosts, fn {host, ns} ->
          unless is_map(ns) do
            raise "Samen abbrev registry at #{registry_path}: host namespace #{inspect(host)} " <>
                    "must be a JSON object of abbrev → owner."
          end
        end)

        hosts

      _ ->
        raise "Samen abbrev registry at #{registry_path}: the \"hosts\" key, if present, " <>
                "must be a JSON object of host → {abbrev → owner}."
    end
  end

  @doc """
  Detects a **lossy flattening** in a namespaced registry — the ADR-025 tripwire
  condition. Pure (no IO), cheap (single pass), safe on the hot compile path.

  Returns the list of abbrevs whose flattened owner is **ambiguous**: the SAME abbrev
  is owned, with DIFFERENT owners, across more than one namespace. That covers both
  lossy cases exactly:

    * **(a) cross-host reuse** — two hosts own the same abbrev for distinct resources; and
    * **(b) host-vs-global mismatch** — a host owns an abbrev whose owner differs from the
      global map's owner for that abbrev.

  When this is empty the flattened compat view (`load/0`) is lossless and the
  flattened-view verifier (`Samen.Verifiers.AbbrevRegistry`) is still correct. When it is
  non-empty, `load/0` fails closed (raises) rather than silently picking one owner — the
  deferred host-partition (ADR-025) must now land. Same-owner reuse of an abbrev across
  namespaces is NOT a conflict (flattening is lossless), so it is not reported.

  Each entry is `%{abbrev: abbrev, owners: [{source, owner}, …]}` where `source` is the
  host name (string) or `:global`, sorted for stable output.
  """
  @spec flatten_conflicts(%{global: map(), hosts: map()}) :: [
          %{abbrev: String.t(), owners: [{String.t() | :global, String.t()}]}
        ]
  def flatten_conflicts(%{global: global, hosts: hosts})
      when is_map(global) and is_map(hosts) do
    host_sources =
      Enum.flat_map(hosts, fn {host, ns} ->
        Enum.map(ns, fn {abbrev, owner} -> {abbrev, {host, owner}} end)
      end)

    global_sources = Enum.map(global, fn {abbrev, owner} -> {abbrev, {:global, owner}} end)

    (host_sources ++ global_sources)
    |> Enum.group_by(fn {abbrev, _src_owner} -> abbrev end, fn {_abbrev, src_owner} -> src_owner end)
    |> Enum.filter(fn {_abbrev, src_owners} ->
      src_owners |> Enum.map(fn {_src, owner} -> owner end) |> Enum.uniq() |> length() > 1
    end)
    |> Enum.map(fn {abbrev, src_owners} -> %{abbrev: abbrev, owners: Enum.sort(src_owners)} end)
    |> Enum.sort_by(& &1.abbrev)
  end

  defp flatten_conflict_message(conflicts, registry_path) do
    details =
      conflicts
      |> Enum.map_join("\n", fn %{abbrev: abbrev, owners: owners} ->
        competing =
          Enum.map_join(owners, ", ", fn {src, owner} -> "#{source_label(src)} → #{owner}" end)

        "  #{inspect(abbrev)}: #{competing}"
      end)

    """
    Samen abbrev registry at #{registry_path} has a LOSSY FLATTENING: an abbrev is owned \
    by more than one namespace with DIFFERENT owners. The flattened compat view \
    (Samen.AbbrevRegistry.load/0) can keep only ONE owner, so it would silently drop the \
    other and the flattened-view verifier (Samen.Verifiers.AbbrevRegistry) would \
    false-positive a collision on the dropped resource. This is the ADR-025 trigger — the \
    first legitimate cross-host prefix reuse (or a host-vs-global owner disagreement) has \
    landed. The deferred abbrev verifier host-partition MUST now be implemented (see \
    docs/adr/025-abbrev-verifier-host-partition-followon.md): validate each resource against \
    its OWN host namespace (validate_host/4) instead of the flattened union. Refusing to \
    compile (fail-closed).

    Conflicting abbrevs (abbrev: competing owners):
    #{details}
    """
  end

  defp source_label(:global), do: "global net"
  defp source_label(host), do: "host #{inspect(host)}"

  @doc """
  Returns the owner module name (string) registered for `abbrev`, or `nil`.
  """
  @spec owner(String.t()) :: String.t() | nil
  def owner(abbrev), do: Map.get(load(), abbrev)

  @doc "True if `abbrev` matches the 3-letter-lowercase permanence pattern."
  @spec valid_shape?(term()) :: boolean()
  def valid_shape?(abbrev) when is_binary(abbrev), do: Regex.match?(@abbrev_pattern, abbrev)
  def valid_shape?(_), do: false

  @doc """
  Validates that `resource` (module name string) may use `abbrev` against a loaded
  registry map. Returns `:ok` or `{:error, reason_string}`. Pure — no file IO — so
  it is unit-testable and reusable by the compile-time verifier.

  Fails (never open) when:

    * `abbrev` is not 3-letter lowercase;
    * `abbrev` is registered to a **different** resource (collision / recycle);
    * `abbrev` is **absent** from the registry (unreserved).
  """
  @spec validate(map(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate(registry, abbrev, resource)
      when is_map(registry) and is_binary(abbrev) and is_binary(resource) do
    cond do
      not valid_shape?(abbrev) ->
        {:error,
         "abbrev #{inspect(abbrev)} for #{resource} is not 3 lowercase letters " <>
           "(^[a-z]{3}$). Storage abbrevs are permanent, ticker-like identifiers."}

      not Map.has_key?(registry, abbrev) ->
        {:error,
         "abbrev #{inspect(abbrev)} for #{resource} is not in the abbrev registry " <>
           "(#{@registry_path}). Abbrevs are permanent and must be reserved: add " <>
           "\"#{abbrev}\": \"#{resource}\" to the \"abbrevs\" map and commit it. " <>
           "This prevents two resources ever racing for the same prefix."}

      Map.fetch!(registry, abbrev) != resource ->
        {:error,
         "abbrev #{inspect(abbrev)} is registered to #{Map.fetch!(registry, abbrev)}, " <>
           "not #{resource}. Abbrevs are permanent and never recycled — you cannot " <>
           "reuse an abbrev for a second resource, nor change a resource's abbrev. " <>
           "Pick a new, unused 3-letter abbrev."}

      true ->
        :ok
    end
  end

  @doc """
  Returns the owner registered for `abbrev` in `host`'s namespace (falling back to the
  global namespace), or `nil`. Reads the committed registry.
  """
  @spec owner(String.t(), String.t()) :: String.t() | nil
  def owner(host, abbrev) when is_binary(host) and is_binary(abbrev) do
    %{global: global, hosts: hosts} = load_namespaced()

    case get_in(hosts, [host, abbrev]) do
      nil -> Map.get(global, abbrev)
      found -> found
    end
  end

  @doc """
  Validates a host-scoped reservation of `abbrev` by `owner` in `host`, given a loaded
  `%{global:, hosts:}` namespaced registry. Pure — no IO — so it is unit-testable and
  reusable by the allocator.

  Fails closed (never open) when:

    * `abbrev` is not 3-letter lowercase;
    * `abbrev` is registered to a **different** owner *within this host's namespace*
      (per-host permanence — ADR-006 one-owner-forever, made host-scoped);
    * `abbrev` is registered to a **different** owner in the **global** namespace
      (the cross-host collision net — two hosts sharing physical infra cannot clash);
    * `abbrev` is registered to a **different** owner in **ANY OTHER host's namespace**
      (T123 — the accidental cross-host collision that broke the T47 build). This last
      check is **refused by default** and opted out of, deliberately, via
      `allow_cross_host_reuse: true` (see below).

  Returns `:ok` when the abbrev is unowned, or already owned by exactly this owner in ANY
  host (idempotent re-reservation — own-host OR cross-host same-owner).

  ## T123 — accidental cross-host collision refused by default (the persistence path)

  Before T123 this checked only the *target* host's namespace + the global net, never any
  OTHER host's namespace — so `Samen.Abbrev.Allocator.reserve!/5` (the sanctioned write
  path routing through here) would persist `hosts.A.xyz` alongside a pre-existing
  `hosts.B.xyz` owned by a DIFFERENT module. That orphan is exactly the T47 incident: it
  trips `flatten_conflicts/1`'s fail-closed "LOSSY FLATTENING" raise inside every
  `use Samen.Resource`, breaking the whole compile. `propose/3` never auto-picks such a
  collision (its `owners_of/2` union check); this makes the *explicit-abbrev* / persistence
  path just as safe — an accidental different-owner cross-host reservation is refused at
  WRITE time, not deferred to a compile-break.

  ### The deliberate ADR-025 Option-B door (explicit override)

  A *legitimate* cross-host prefix reuse (two hosts deliberately owning the same abbrev for
  distinct resources — "the whole point of Option B", ADR-025 §2) is still possible, but
  ONLY when the caller opts in explicitly with `allow_cross_host_reuse: true`. Because
  `validate_host/5` cannot tell a sanctioned reuse from an accident, the default is
  fail-closed and the human must say so. A deliberate reuse then (correctly) trips
  `flatten_conflicts/1` at load — the ADR-025 trigger to implement the verifier
  host-partition, not an accident.
  """
  @spec validate_host(map(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, String.t()}
  def validate_host(namespaced, host, abbrev, owner, opts \\ [])

  def validate_host(%{global: global, hosts: hosts}, host, abbrev, owner, opts)
      when is_binary(host) and is_binary(abbrev) and is_binary(owner) and is_list(opts) do
    host_ns = Map.get(hosts, host, %{})
    allow_cross_host_reuse? = Keyword.get(opts, :allow_cross_host_reuse, false)
    cross_host = cross_host_conflict(hosts, host, abbrev, owner)

    cond do
      not valid_shape?(abbrev) ->
        {:error,
         "abbrev #{inspect(abbrev)} for #{owner} is not 3 lowercase letters (^[a-z]{3}$). " <>
           "Storage abbrevs are permanent, ticker-like identifiers."}

      match?(existing when existing != owner and not is_nil(existing), Map.get(host_ns, abbrev)) ->
        other = Map.fetch!(host_ns, abbrev)

        {:error,
         "abbrev #{inspect(abbrev)} is already owned by #{other} in host #{inspect(host)}, " <>
           "not #{owner}. Abbrevs are permanent within a host and never recycled — pick a " <>
           "new, unused 3-letter abbrev."}

      match?(existing when existing != owner and not is_nil(existing), Map.get(global, abbrev)) ->
        other = Map.fetch!(global, abbrev)

        {:error,
         "abbrev #{inspect(abbrev)} is already owned by #{other} in the GLOBAL cross-host net " <>
           "(#{@registry_path}), not #{owner}. Two hosts sharing physical infrastructure cannot " <>
           "silently clash on a 3-letter prefix — pick a new, unused abbrev."}

      cross_host != nil and not allow_cross_host_reuse? ->
        {other_host, other_owner} = cross_host

        {:error,
         "abbrev #{inspect(abbrev)} is already owned by #{other_owner} in host " <>
           "#{inspect(other_host)}, not #{owner} (a DIFFERENT module in a DIFFERENT host). " <>
           "Refusing by default (T123): persisting an accidental cross-host collision " <>
           "re-creates the T47 build-break — the orphan trips " <>
           "Samen.AbbrevRegistry.flatten_conflicts/1's fail-closed \"LOSSY FLATTENING\" raise " <>
           "inside every `use Samen.Resource`. propose/3 never auto-picks this; pick a new, " <>
           "unused abbrev. If this IS a DELIBERATE ADR-025 Option-B cross-host prefix reuse, " <>
           "opt in explicitly with `allow_cross_host_reuse: true` (that reuse then trips the " <>
           "ADR-025 tripwire — the signal to implement the verifier host-partition)."}

      true ->
        :ok
    end
  end

  # The first {other_host, other_owner} in ANY host namespace OTHER than `host` that owns
  # `abbrev` for a module that is NOT `owner` — i.e. an accidental cross-host collision
  # (T123). Same-owner cross-host reuse returns nil (idempotent, not a collision). This is
  # the persistence-path twin of the allocator's owners_of/2 union check.
  defp cross_host_conflict(hosts, host, abbrev, owner) do
    Enum.find_value(hosts, fn {h, ns} ->
      if h != host do
        case Map.get(ns, abbrev) do
          nil -> nil
          ^owner -> nil
          other -> {h, other}
        end
      else
        nil
      end
    end)
  end
end

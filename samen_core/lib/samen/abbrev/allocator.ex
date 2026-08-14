defmodule Samen.Abbrev.Allocator do
  @moduledoc """
  The abbrev **allocator** (ADR-023, WS-D D8) — the single mechanism the generators call
  to reserve a permanent 3-letter storage abbrev, so a builder never hand-edits
  `priv/abbrev_registry.json`.

  Two responsibilities, both fail-closed:

    * **`propose/3`** — a *deterministic* candidate abbrev for `owner` in `host`, derived
      from the owner module's name and collision-checked against the loaded registry
      **union**: the calling host's namespace, EVERY OTHER host's namespace, AND the
      legacy global cross-host net. Deterministic so a re-run proposes the same abbrev;
      collision-checked so it never auto-proposes a prefix already owned by a *different*
      module anywhere. Returns `{:ok, abbrev}` or `{:error, reason}`.

      > **Why the union check exists (T123).** `propose/3` was host-*blind* through T47:
      > its `free?` closure looked only at the *calling* host's namespace + the global
      > map, never at any *other* host's namespace, so it could hand back an abbrev
      > already owned by a different host for an unrelated resource. This bit four tasks
      > this run (T44/T45/T46 self-corrected pre-write by luck; **T47** persisted `dll`
      > for `driftwood`/`Driftwood.Locations.Location` while `demo` already owned it,
      > and the orphan `hosts.driftwood.dll` tripped `AbbrevRegistry.flatten_conflicts/1`'s
      > fail-closed "LOSSY FLATTENING" raise — which fires inside every `use
      > Samen.Resource`, breaking the whole `samen_core` compile). This is a
      > *forward-looking auto-picker* fix (ADR-023): it only changes what `propose/3`
      > picks on its next call. The persistence path (`reserve!/5` →
      > `AbbrevRegistry.validate_host/5`) is hardened with the SAME all-host check (T123
      > attempt 2) so an **explicit** abbrev that bypasses `propose/3` can no longer
      > persist an accidental cross-host collision either — a different-owner cross-host
      > reservation is **refused by default**. A *deliberate* ADR-025 Option-B reuse
      > stays possible, but only behind the explicit `allow_cross_host_reuse: true`
      > override (ADR-025 §2's `flatten_conflicts/1` tripwire then fires at load — the
      > signal to build the verifier host-partition). This fix does NOT retroactively
      > rewrite any existing row and does NOT implement the ADR-025 partition.

    * **`reserve!/5`** — validates (`Samen.AbbrevRegistry.validate_host/5`) then appends
      `host → {abbrev → owner}` into the registry file, **append-only + idempotent**
      (same host+abbrev+owner is a byte no-op) and **fail-closed on cross-owner
      collision** within the host namespace, the global net, OR (T123) any OTHER host's
      namespace unless the caller passes `allow_cross_host_reuse: true`. The global
      `"abbrevs"` net is left byte-untouched — the allocator writes host namespaces, never
      the legacy global map.

  ## Never point at the committed registry from a probe

  `reserve!/5` takes the registry path explicitly (defaulting to the committed file only
  for the real generator path). Probes and tests pass a **scratch copy** — the committed
  `samen_core/priv/abbrev_registry.json` (the 263-entry legacy global map plus every
  host's namespace) must stay byte-untouched.
  """

  alias Samen.AbbrevRegistry

  @doc """
  Proposes a deterministic, collision-free 3-letter abbrev for `owner` in `host`.

  The base candidate is the first letter of the last three underscore/dot segments of
  the owner module name (e.g. `Widgetco.Vertical.Widget` → `vvw`… collapsed to a
  3-letter seed), lowercased. On collision it walks a deterministic sequence of
  fallbacks (the seed's letters permuted, then `aaa..zzz` scan) until it finds a slot
  unowned across EVERY host namespace AND the global net (or already owned by exactly
  this owner). Fails closed if the whole space is somehow exhausted.

  Reads the committed registry by default; pass a `namespaced` map (from
  `AbbrevRegistry.load_namespaced/1`) to keep it hermetic in tests.
  """
  @spec propose(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def propose(host, owner), do: propose(host, owner, AbbrevRegistry.load_namespaced())

  @spec propose(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def propose(host, owner, %{global: global, hosts: hosts} = ns)
      when is_binary(host) and is_binary(owner) do
    host_ns = Map.get(hosts, host, %{})

    # A slot is free iff, across the UNION of EVERY host namespace AND the global net,
    # every module that currently holds it IS exactly this `owner` (i.e. it is unowned
    # everywhere, or only a same-owner idempotent re-propose). A candidate owned by a
    # DIFFERENT module in ANY namespace — the calling host, ANY OTHER host, or global —
    # is a collision and is skipped for the next deterministic candidate.
    #
    # T123 root-cause fix: the pre-T123 closure only inspected the *calling* host's
    # namespace (`host_ns`) + `global`, never any OTHER host's namespace, so it could
    # auto-hand-back an abbrev already owned by a different host for an unrelated module
    # (T44-T47; T47 persisted it and tripped flatten_conflicts/1's fail-closed raise,
    # breaking every `use Samen.Resource` compile — see moduledoc, ADR-023, ADR-025).
    free? = fn abbrev -> Enum.all?(owners_of(ns, abbrev), &(&1 == owner)) end

    candidates = candidate_stream(owner)

    case Enum.find(candidates, free?) do
      nil ->
        {:error,
         "abbrev allocator exhausted the 3-letter space proposing for #{owner} in host " <>
           "#{inspect(host)} — every candidate is already owned. This should be impossible; " <>
           "the registry may be corrupt (#{map_size(host_ns) + map_size(global)} owned)."}

      abbrev ->
        # Belt-and-suspenders: the deterministic pick must itself validate. Post-T123 this
        # is a genuinely INDEPENDENT all-host check (validate_host/5 now runs the same
        # cross-host union guard as free? via a separate code path), not the same blind
        # check twice — free?'s pick is union-safe, so this is :ok on the happy path.
        case AbbrevRegistry.validate_host(ns, host, abbrev, owner) do
          :ok -> {:ok, abbrev}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Reserves `abbrev` for `owner` in `host`, writing the registry at `path`.

  Fail-closed via `AbbrevRegistry.validate_host/5` (per-host permanence + global net +
  the T123 all-host accidental-cross-host-collision refusal), idempotent (same
  host+abbrev+owner is a byte no-op), append-only (never mutates the legacy global
  `"abbrevs"` map, never another host's namespace). Preserves the `$comment` and pretty
  formatting. Returns `:ok`.

  `opts` is forwarded verbatim to `validate_host/5`. The only supported key is
  `allow_cross_host_reuse: true` — the EXPLICIT opt-in for a deliberate ADR-025 Option-B
  cross-host prefix reuse (two hosts owning the same abbrev for distinct modules). WITHOUT
  it, an accidental different-owner cross-host reservation is **refused** (it would persist
  the exact T47 orphan that trips `flatten_conflicts/1`'s fail-closed raise at compile —
  see `validate_host/5`). Same-owner reuse (own-host or cross-host) needs no override.

  ⚠️ `path` defaults to the committed registry — probes/tests MUST pass a scratch copy.
  """
  @spec reserve!(String.t(), String.t(), String.t(), String.t(), keyword()) :: :ok
  def reserve!(host, abbrev, owner, path \\ AbbrevRegistry.path(), opts \\ [])
      when is_binary(host) and is_binary(abbrev) and is_binary(owner) and is_binary(path) and
             is_list(opts) do
    raw = File.read!(path)
    decoded = Jason.decode!(raw)

    global = Map.get(decoded, "abbrevs", %{})
    hosts = Map.get(decoded, "hosts", %{})
    host_ns = Map.get(hosts, host, %{})

    ns = %{global: global, hosts: hosts}

    case AbbrevRegistry.validate_host(ns, host, abbrev, owner, opts) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "cannot reserve #{inspect(abbrev)}: #{reason}"
    end

    case Map.get(host_ns, abbrev) do
      # Idempotent: already this exact owner in this host — byte no-op, do not rewrite.
      ^owner ->
        :ok

      _ ->
        new_host_ns = Map.put(host_ns, abbrev, owner)
        new_hosts = Map.put(hosts, host, new_host_ns)
        updated = Map.put(decoded, "hosts", new_hosts)
        File.write!(path, Jason.encode!(updated, pretty: true) <> "\n")
        :ok
    end
  end

  # --- host-aware collision union (T123) --------------------------------------

  # Every module that currently owns `abbrev`, gathered across the ENTIRE namespaced
  # registry: every host namespace in `ns.hosts` (not just the calling host's) plus the
  # legacy global cross-host net. This union is what makes `propose/3`'s `free?` check
  # host-aware — the pre-T123 check was blind to every host but the caller's, which let
  # it auto-propose a cross-host collision (T47's build-break). An empty list means the
  # slot is genuinely free everywhere; a list of only this owner is an idempotent
  # re-propose; any other module in the list is a collision.
  defp owners_of(%{global: global, hosts: hosts}, abbrev) do
    from_hosts =
      for {_host, host_ns} <- hosts,
          mod = Map.get(host_ns, abbrev),
          not is_nil(mod),
          do: mod

    case Map.get(global, abbrev) do
      nil -> from_hosts
      mod -> [mod | from_hosts]
    end
  end

  # --- deterministic candidate stream ----------------------------------------

  # A lazy stream of 3-letter lowercase candidates: the name-derived seed first, then
  # deterministic permutations of the seed letters, then a full aaa..zzz scan. Fully
  # deterministic in the owner name — no randomness, so a re-run proposes identically.
  defp candidate_stream(owner) do
    seed = seed_letters(owner)

    seed_candidates =
      ([seed] ++ permutations(seed))
      |> Enum.uniq()
      |> Enum.filter(&Regex.match?(~r/\A[a-z]{3}\z/, &1))

    scan =
      for a <- ?a..?z, b <- ?a..?z, c <- ?a..?z do
        <<a, b, c>>
      end

    Stream.concat(seed_candidates, scan)
  end

  # First letter of up to the last three name segments, padded to 3 letters from the
  # owner's alpha characters (deterministic).
  defp seed_letters(owner) do
    segments =
      owner
      |> String.replace(~r/[^A-Za-z]+/, ".")
      |> String.split(".", trim: true)

    initials =
      segments
      |> Enum.take(-3)
      |> Enum.map(&String.first/1)
      |> Enum.join()
      |> String.downcase()

    alpha = owner |> String.downcase() |> String.replace(~r/[^a-z]/, "")
    (initials <> alpha <> "xxx") |> String.slice(0, 3)
  end

  defp permutations(<<a, b, c>>) do
    for p <- [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]] do
      IO.iodata_to_binary(p)
    end
  end

  defp permutations(_), do: []
end

defmodule Samen.Abbrev.Allocator do
  @moduledoc """
  The abbrev **allocator** (ADR-023, WS-D D8) — the single mechanism the generators call
  to reserve a permanent 3-letter storage abbrev, so a builder never hand-edits
  `priv/abbrev_registry.json`.

  Two responsibilities, both fail-closed:

    * **`propose/3`** — a *deterministic* candidate abbrev for `owner` in `host`, derived
      from the owner module's name and collision-checked against the loaded registry
      (both the host namespace and the global cross-host net). Deterministic so a
      re-run proposes the same abbrev; collision-checked so it never proposes an
      already-owned prefix. Returns `{:ok, abbrev}` or `{:error, reason}`.

    * **`reserve!/4`** — validates (`Samen.AbbrevRegistry.validate_host/4`) then appends
      `host → {abbrev → owner}` into the registry file, **append-only + idempotent**
      (same host+abbrev+owner is a byte no-op) and **fail-closed on cross-owner
      collision** within the host namespace *or* the global net (ADR-006 one-owner-forever,
      made host-scoped). The global `"abbrevs"` net is left byte-untouched — the allocator
      writes host namespaces, never the legacy global map.

  ## Never point at the committed registry from a probe

  `reserve!/4` takes the registry path explicitly (defaulting to the committed file only
  for the real generator path). Probes and tests pass a **scratch copy** — the committed
  `samen_core/priv/abbrev_registry.json` (263 entries) must stay byte-untouched.
  """

  alias Samen.AbbrevRegistry

  @doc """
  Proposes a deterministic, collision-free 3-letter abbrev for `owner` in `host`.

  The base candidate is the first letter of the last three underscore/dot segments of
  the owner module name (e.g. `Widgetco.Vertical.Widget` → `vvw`… collapsed to a
  3-letter seed), lowercased. On collision it walks a deterministic sequence of
  fallbacks (the seed's letters permuted, then `aaa..zzz` scan) until it finds a slot
  unowned in BOTH the host namespace and the global net. Fails closed if the whole
  space is somehow exhausted.

  Reads the committed registry by default; pass a `namespaced` map (from
  `AbbrevRegistry.load_namespaced/1`) to keep it hermetic in tests.
  """
  @spec propose(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def propose(host, owner), do: propose(host, owner, AbbrevRegistry.load_namespaced())

  @spec propose(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def propose(host, owner, %{global: global, hosts: hosts} = ns)
      when is_binary(host) and is_binary(owner) do
    host_ns = Map.get(hosts, host, %{})

    # A slot is free iff unowned in the host namespace AND unowned in the global net,
    # OR already owned by exactly this owner (idempotent proposal).
    free? = fn abbrev ->
      case {Map.get(host_ns, abbrev), Map.get(global, abbrev)} do
        {nil, nil} -> true
        {^owner, _} -> true
        {nil, ^owner} -> true
        _ -> false
      end
    end

    candidates = candidate_stream(owner)

    case Enum.find(candidates, free?) do
      nil ->
        {:error,
         "abbrev allocator exhausted the 3-letter space proposing for #{owner} in host " <>
           "#{inspect(host)} — every candidate is already owned. This should be impossible; " <>
           "the registry may be corrupt (#{map_size(host_ns) + map_size(global)} owned)."}

      abbrev ->
        # Guard: the deterministic pick must itself validate (belt-and-suspenders).
        case AbbrevRegistry.validate_host(ns, host, abbrev, owner) do
          :ok -> {:ok, abbrev}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Reserves `abbrev` for `owner` in `host`, writing the registry at `path`.

  Fail-closed via `AbbrevRegistry.validate_host/4` (per-host permanence + global net),
  idempotent (same host+abbrev+owner is a byte no-op), append-only (never mutates the
  legacy global `"abbrevs"` map, never another host's namespace). Preserves the
  `$comment` and pretty formatting. Returns `:ok`.

  ⚠️ `path` defaults to the committed registry — probes/tests MUST pass a scratch copy.
  """
  @spec reserve!(String.t(), String.t(), String.t(), String.t()) :: :ok
  def reserve!(host, abbrev, owner, path \\ AbbrevRegistry.path())
      when is_binary(host) and is_binary(abbrev) and is_binary(owner) and is_binary(path) do
    raw = File.read!(path)
    decoded = Jason.decode!(raw)

    global = Map.get(decoded, "abbrevs", %{})
    hosts = Map.get(decoded, "hosts", %{})
    host_ns = Map.get(hosts, host, %{})

    ns = %{global: global, hosts: hosts}

    case AbbrevRegistry.validate_host(ns, host, abbrev, owner) do
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

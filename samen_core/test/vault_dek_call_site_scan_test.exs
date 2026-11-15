defmodule Samen.VaultDekCallSiteScanTest do
  @moduledoc """
  Evaluation WP13 S2 — nothing but convention keeps a `Samen.Vault.DekMemo` (raw DEKs) inside the
  resolve call that built it. A memo kept in a LiveView assign / GenServer state would serve
  plaintext for a subject shredded since. This source scan pins WHERE the memo machinery may
  appear, across samen_core, samen_web, demo, driftwood and pawchart `lib/`:

    * `unwrap_subjects(`          — `samen_core/lib/samen/vault.ex`, `samen_core/lib/samen/api/pii_resolution.ex`
    * `deks:`                     — those two files and `samen_core/lib/samen/vault/dek_memo.ex` (docs)
    * `PiiResolution.prefetch(`   — `samen_core/lib/samen/replay/resolver.ex`, and only as a plain
                                    statement/expression (never bound into a map, assign or state)
    * `__vault_deks`, `__vault_rows`, `__prefetched` — pii_resolution.ex only
    * `DekMemo`                   — vault.ex, dek_memo.ex, pii_resolution.ex (docs)
    * any line that both stores (`assign`, `put_private`, `:ets.`, `Process.put`, `:persistent_term`,
      `GenServer`, `Agent.`, `Oban`) and names the memo machinery — never allowed

  A new call site elsewhere must be reviewed against the single-use contract on
  `Samen.Vault.unwrap_subjects/1` and `Samen.Api.PiiResolution.prefetch/4`, then added HERE.
  Anti-tautology: `violations/1` is run on planted fixture strings (no files are planted).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @apps ~w(samen_core samen_web demo driftwood pawchart)

  @vault "samen_core/lib/samen/vault.ex"
  @memo "samen_core/lib/samen/vault/dek_memo.ex"
  @pii "samen_core/lib/samen/api/pii_resolution.ex"
  @resolver "samen_core/lib/samen/replay/resolver.ex"

  @allow %{
    "unwrap_subjects(" => [@vault, @pii],
    "deks:" => [@vault, @memo, @pii],
    "PiiResolution.prefetch(" => [@resolver],
    "__vault_deks" => [@pii],
    "__vault_rows" => [@pii],
    "__prefetched" => [@pii],
    "DekMemo" => [@vault, @memo, @pii]
  }

  @machinery ["__vault_deks", "__vault_rows", "__prefetched", "unwrap_subjects", "PiiResolution.prefetch", "DekMemo"]
  @store ~r/\b(assign|assign_new|put_private)\(|:ets\.|Process\.put|:persistent_term|GenServer|Agent\.|Oban/

  @doc false
  def violations(sources) do
    Enum.flat_map(sources, fn {path, src} ->
      allow_violations =
        for {needle, allowed} <- @allow,
            path not in allowed,
            String.contains?(src, needle),
            do: "#{path}: #{inspect(needle)} outside its allow-list #{inspect(allowed)}"

      lines = String.split(src, "\n")

      store_violations =
        for line <- lines,
            Enum.any?(@machinery, &String.contains?(line, &1)),
            Regex.match?(@store, line),
            do: "#{path}: stores the DEK memo machinery: #{String.trim(line)}"

      bound_violations =
        for line <- lines,
            String.contains?(line, "PiiResolution.prefetch("),
            not Regex.match?(~r/^\s*PiiResolution\.prefetch\(/, line),
            do: "#{path}: PiiResolution.prefetch( result must not be bound or nested: #{String.trim(line)}"

      allow_violations ++ store_violations ++ bound_violations
    end)
  end

  defp sources do
    for app <- @apps,
        path <- Path.wildcard(Path.join([@root, app, "lib", "**", "*.{ex,exs}"])) do
      {Path.relative_to(path, @root), File.read!(path)}
    end
  end

  test "the real tree has no call site outside the allow-list (and the scan sees the apps)" do
    srcs = sources()
    paths = Enum.map(srcs, &elem(&1, 0))
    # Non-vacuity: every allowed file is actually scanned, and every app contributes files.
    for f <- [@vault, @memo, @pii, @resolver], do: assert(f in paths, "#{f} not scanned")
    for app <- @apps, do: assert(Enum.any?(paths, &String.starts_with?(&1, app <> "/")), "no #{app} sources")

    assert violations(srcs) == [],
           "DEK memo call site outside the allow-list (see Samen.VaultDekCallSiteScanTest):\n" <>
             Enum.join(violations(srcs), "\n")
  end

  describe "positive control: the scan detects a planted offender" do
    test "a new unwrap_subjects( / deks: call site names its file" do
      src = "defmodule Host do\n  def f(rows), do: Samen.Vault.unwrap_subjects(rows)\nend\n"
      assert [msg] = violations([{"pawchart/lib/host.ex", src}])
      assert msg =~ "pawchart/lib/host.ex"
      assert msg =~ "unwrap_subjects("

      assert [msg] = violations([{"demo/lib/x.ex", "Samen.Vault.reveal(m, repo, deks: memo)"}])
      assert msg =~ "demo/lib/x.ex"
    end

    test "prefetched opts assigned into a socket are caught, even in the allowed file" do
      src = """
      def mount(_, _, socket) do
        opts = PiiResolution.prefetch(rows, mod, actor, base)
        {:ok, assign(socket, :opts, opts)}
      end
      """

      msgs = violations([{@resolver, src}])
      assert Enum.any?(msgs, &(&1 =~ "must not be bound"))

      state = "def init(_), do: {:ok, %{deks: Samen.Vault.unwrap_subjects(rows)}}"
      assert Enum.any?(violations([{@vault, state <> " # GenServer"}]), &(&1 =~ "stores"))
      assert Enum.any?(violations([{@pii, ":ets.insert(t, {:k, __vault_deks})"}]), &(&1 =~ "stores"))
    end

    test "the sanctioned shapes pass" do
      ok = "    PiiResolution.prefetch(rows, mod, actor, base)\n"
      assert violations([{@resolver, ok}]) == []
      assert violations([{"samen_core/lib/other.ex", "no memo here"}]) == []
    end
  end
end

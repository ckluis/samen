defmodule Samen.Web.OperatorAnalyticsZeroAshReadTest do
  @moduledoc """
  B9 carry B8-P2-2 — the ENV-INDEPENDENT zero-Ash-read assertion for
  `Samen.Web.Operator.AnalyticsReads` (ADR-021; design §4.5).

  The `never_read_current` lint is VACUOUS in the samen_web test env: the CDC tier
  is off, so there is no CDC repo for it to watch, and a future regression sourcing
  a live `pae` Ash scan into AnalyticsReads would sail through it here. Until this
  suite, the zero-Ash-read posture rested only on the reads AST lint (which checks
  bounds, not absence) and the render tests.

  This suite pins the posture at the SOURCE level — an AST scan of the module file,
  independent of any runtime CDC config (no repo, no env, no tier):

    * **ZERO Ash** — AnalyticsReads contains no `Ash.*` / `Ash.Query.*` call and no
      `Mount.resource/2` resolution. Its ONLY reads are the explicit-LIMIT SQL
      reads over the `paf` rollup raw table (`Ecto.Adapters.SQL.query/3` — the mrr
      precedent: never a live `pae` scan).
    * **Non-vacuity** — the scan must actually SEE both rollup SQL reads and a
      realistic module body; a parse/matcher regression that sees nothing cannot
      green-light the posture.
    * **Posture marker** — `use Samen.Cdc.Analytics` stays on the module (the
      `never_read_current` allow-list marker keeps working wherever the CDC tier
      IS on — this suite complements that lint, it does not replace it).
    * **RED / ANTI-TAUTOLOGY** — the same scanner over a fixture that sneaks a
      live `Mount.resource |> Ash.Query.limit |> Ash.read!` pae scan in FLAGS both
      the Ash calls and the resource resolution — the scan discriminates, it is
      not a no-op.
  """
  use ExUnit.Case, async: true

  @reads_path Path.expand("../../../lib/samen/web/operator/analytics/reads.ex", __DIR__)

  # The EXACT regression shape the carry names: a live pae Ash scan sourced into
  # the analytics read layer (posture-marked, so never_read_current would not
  # object even where the CDC tier is on — only THIS scan catches it env-free).
  @regression_fixture """
  defmodule Samen.Web.Fixture.LivePaeScan do
    use Samen.Cdc.Analytics
    require Ash.Query
    alias Samen.Web.Mount

    def analytics(mount, _opts) do
      Mount.resource(mount, ProductEvent)
      |> Ash.Query.limit(100)
      |> Ash.read!(authorize?: false)
    end
  end
  """

  test "GREEN (B8-P2-2): AnalyticsReads performs ZERO Ash reads and ZERO Mount.resource resolutions — its only reads are the paf rollup SQL (non-vacuous)" do
    src = File.read!(@reads_path)
    %{ash_calls: ash_calls, resource_calls: resource_calls, sql_reads: sql_reads, nodes: nodes} = scan(src)

    assert ash_calls == [],
           "AnalyticsReads sourced an Ash call — the zero-Ash-read posture (never a live pae scan) regressed: #{inspect(ash_calls)}"

    assert resource_calls == [],
           "AnalyticsReads resolved a Mount resource — the surface must read ONLY the paf rollup raw table: #{inspect(resource_calls)}"

    # Non-vacuity: the scanner genuinely parsed the real module — it saw both
    # rollup SQL reads (funnel + retention) and a realistic AST.
    assert sql_reads >= 2, "the scan no longer sees the paf rollup SQL reads — matcher/parse regression"
    assert nodes > 100, "the scan saw an implausibly small AST — parse regression"

    # The never_read_current posture marker stays (the lint's allow-list, for
    # every env where the CDC tier IS on).
    assert src =~ "use Samen.Cdc.Analytics"
  end

  test "RED / ANTI-TAUTOLOGY: the scanner FLAGS a live pae Ash scan sneaked into an analytics read module — the assertion discriminates" do
    %{ash_calls: ash_calls, resource_calls: resource_calls} = scan(@regression_fixture)

    # The fixture's Ash.Query.limit + Ash.read! are both seen…
    ash_funs = Enum.map(ash_calls, &elem(&1, 0))
    assert :read! in ash_funs
    assert :limit in ash_funs

    # …and so is the Mount.resource resolution. A scanner that finds neither
    # would make the GREEN half vacuously true — this proves it cannot.
    assert [{:resource, _line} | _] = resource_calls
  end

  # -- the scanner: dot-calls on Ash*/Mount.resource + the rollup SQL reads --------

  defp scan(src) do
    {:ok, ast} = Code.string_to_quoted(src)

    {_ast, acc} =
      Macro.prewalk(ast, %{ash_calls: [], resource_calls: [], sql_reads: 0, nodes: 0}, fn
        {{:., meta, [{:__aliases__, _, [:Ash | _]}, fun]}, _, _} = n, acc ->
          {n, %{acc | ash_calls: acc.ash_calls ++ [{fun, line(meta)}], nodes: acc.nodes + 1}}

        {{:., meta, [{:__aliases__, _, parts}, :resource]}, _, _} = n, acc ->
          if List.last(parts) == :Mount do
            {n, %{acc | resource_calls: acc.resource_calls ++ [{:resource, line(meta)}], nodes: acc.nodes + 1}}
          else
            {n, %{acc | nodes: acc.nodes + 1}}
          end

        {{:., _, [{:__aliases__, _, [:Ecto, :Adapters, :SQL]}, :query]}, _, _} = n, acc ->
          {n, %{acc | sql_reads: acc.sql_reads + 1, nodes: acc.nodes + 1}}

        n, acc ->
          {n, %{acc | nodes: acc.nodes + 1}}
      end)

    acc
  end

  defp line(meta) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp line(_), do: 0
end

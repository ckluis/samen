defmodule Samen.Fleet.ConsumerSweepTest do
  @moduledoc """
  T83 / J3 — RP-J-6(c): the STRUCTURAL consumer sweep (ADR-044 §6.4, in the shape of the
  ADR-037 §4.5 consumer-sweep precedent).

  No module under `Samen.Fleet.*` (samen_core) references the impersonation / reveal / PII
  machinery — `Samen.Impersonation`, `Samen.Reveal`, or `Samen.Api.PiiResolution`. This is the
  by-construction backing for "the fleet introduces no cross-product impersonation session, no
  fleet-wide reveal grant, and no PII read path": those modules are not merely refused at runtime,
  they are not WIRED IN at all.

  The sweep is AST-based, not a substring grep: it collects module-reference nodes
  (`{:__aliases__, _, [...]}`) and DISCARDS string literals — so a moduledoc that mentions
  `Samen.Reveal.reveal/5` while DOCUMENTING that a fleet actor is refused (e.g.
  `Samen.Fleet.HeartbeatActor`) does not trip it. A real `alias`/call would.

  NON-VACUOUS: the same scanner over a fixture that actually calls `Samen.Reveal.reveal/5` flags
  it — the scan discriminates.
  """
  use ExUnit.Case, async: true

  @fleet_lib Path.expand("../../lib/samen/fleet", __DIR__)

  @forbidden [
    [:Samen, :Impersonation],
    [:Samen, :Reveal],
    [:Samen, :Api, :PiiResolution]
  ]

  # Module-reference aliases collected from an AST, ignoring string literals (docs/heredocs).
  defp aliases(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, _meta, parts} = node, acc when is_list(parts) ->
          {node, [parts | acc]}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp references_forbidden?(parts) do
    Enum.any?(@forbidden, fn f -> List.starts_with?(parts, f) end)
  end

  test "GREEN — no Samen.Fleet.* module references Impersonation / Reveal / PiiResolution" do
    files = Path.wildcard(Path.join(@fleet_lib, "**/*.ex"))
    assert files != [], "the fleet lib sweep found no source files — path regression"

    offenders =
      for path <- files,
          ast = Code.string_to_quoted!(File.read!(path)),
          parts <- aliases(ast),
          references_forbidden?(parts),
          uniq: true,
          do: {Path.relative_to(path, @fleet_lib), Module.concat(parts)}

    assert offenders == [],
           "a Samen.Fleet.* module WIRES IN impersonation/reveal/PII machinery: #{inspect(offenders)}"
  end

  test "NON-VACUOUS — the scanner flags a fixture that genuinely calls Samen.Reveal" do
    fixture = """
    defmodule Samen.Fleet.Fixture.Leaky do
      def leak(actor, masked, resource) do
        Samen.Reveal.reveal(actor, masked, :reveal_x, resource, [])
      end
    end
    """

    parts = fixture |> Code.string_to_quoted!() |> aliases()
    assert Enum.any?(parts, &references_forbidden?/1), "the scanner failed to flag a real Reveal call"
  end
end

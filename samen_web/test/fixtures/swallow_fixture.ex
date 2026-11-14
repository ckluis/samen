# NOT compiled into any app: it lives under test/fixtures, outside every elixirc_paths entry and every
# lint root. SwallowLintTest scans it by path as the live ratchet's positive control — it holds exactly
# FOUR known swallows (the count the test pins).
defmodule Fixture.LiveSwallow do
  # 1: the audit's shape — an outage becomes an empty list.
  def contacts(scope) do
    Ash.read!(Person, scope: scope)
  rescue
    _ -> []
  end

  # 2 and 3: a try block with a catch-all rescue and a catch-all catch.
  def tryblock(scope) do
    try do
      Ash.read!(Person, scope: scope)
    rescue
      _error -> %{}
    catch
      :exit, _ -> nil
    end
  end

  # 4: shares its name with a function in the REVIEWED map (samen_web/lib/samen/web/reads.ex, safe_count)
  # but lives in a different file — a reviewed entry is keyed by {file, function}, so this is still counted.
  def safe_count(scope) do
    Ash.count!(Person, scope: scope)
  rescue
    _ -> nil
  end

  # Not swallows: logged, and typed.
  def logged(scope) do
    Ash.read!(Person, scope: scope)
  rescue
    e ->
      Logger.error("read failed: #{inspect(e.__struct__)}")
      []
  end

  def typed(scope) do
    Ash.read!(Person, scope: scope)
  rescue
    ArgumentError -> []
  end
end

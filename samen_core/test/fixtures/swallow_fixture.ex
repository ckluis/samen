# NOT compiled into any app: it lives under test/fixtures, outside every elixirc_paths entry and every
# lint root. SwallowLintTest scans it by path as the live ratchets' positive control — it holds exactly
# FOUR known rescue-class swallows and exactly THREE known non-rescue (`{:error, _} -> literal`) sites
# (the counts the test pins), plus look-alikes the scanners must NOT flag.
defmodule Fixture.KernelSwallow do
  require Logger

  # RESCUE 1: the audit's shape — an outage becomes an empty list.
  def contacts(scope) do
    Ash.read!(Person, scope: scope)
  rescue
    _ -> []
  end

  # RESCUE 2 and 3: a try block with a catch-all rescue and a catch-all catch.
  def tryblock(scope) do
    try do
      Ash.read!(Person, scope: scope)
    rescue
      _error -> %{}
    catch
      :exit, _ -> nil
    end
  end

  # RESCUE 4: one clause in a function the pinned-reviewed map covers with a count of 1 in the tests; the
  # second clause (`pinned/1` has two) is the "added to an already-reviewed function" case.
  def pinned(scope) do
    Ash.read!(Person, scope: scope)
  rescue
    _ -> []
  catch
    _kind, _value -> []
  end

  # Not rescue swallows: logged, reported, handed on, typed.
  def logged(scope) do
    Ash.read!(Person, scope: scope)
  rescue
    e ->
      Logger.error("read failed: #{inspect(e.__struct__)}")
      []
  end

  def reported(scope) do
    Ash.read!(Person, scope: scope)
  rescue
    e -> Samen.Observability.Failure.report(:reported, scope, e)
  end

  def typed(scope) do
    Ash.read!(Person, scope: scope)
  rescue
    ArgumentError -> []
  end

  # ERROR ARM 1: a failed Ash read rendered as an empty list.
  def arm_read(scope) do
    case Ash.read(Person, scope: scope) do
      {:ok, rows} -> rows
      {:error, _} -> []
    end
  end

  # ERROR ARM 2: a failed repo write rendered as :ok (a `with … else` arm, a repo variable receiver).
  def arm_write(repo, attrs) do
    with {:ok, row} <- repo.insert(attrs) do
      {:ok, row}
    else
      {:error, _reason} -> :ok
    end
  end

  # ERROR ARM 3: a failed count rendered as zero.
  def arm_count(scope) do
    case Ash.count(Person, scope: scope) do
      {:ok, n} -> n
      {:error, _} -> 0
    end
  end

  # Not error-arm swallows ----------------------------------------------------------------

  # tagged: the outage stays an outage
  def arm_tagged(scope) do
    case Ash.read(Person, scope: scope) do
      {:ok, rows} -> {:ok, rows}
      {:error, _} -> {:error, :unavailable}
    end
  end

  # the error is used
  def arm_used(scope) do
    case Ash.read(Person, scope: scope) do
      {:ok, rows} -> rows
      {:error, reason} -> raise ArgumentError, "read failed: #{inspect(reason.__struct__)}"
    end
  end

  # a legacy-shape wrapper over a tagged sibling: no read in THIS function, so the literal is the documented shape
  def arm_wrapper(scope) do
    case arm_tagged(scope) do
      {:ok, rows} -> rows
      {:error, _} -> []
    end
  end

  # a literal in an arm that is not an error arm
  def arm_not_error(scope) do
    case Ash.read(Person, scope: scope) do
      {:ok, []} -> []
      {:ok, rows} -> rows
      {:error, e} -> {:error, e}
    end
  end
end

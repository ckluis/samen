defmodule Samen.Web.TenantActor.Guard do
  @moduledoc """
  The detectors behind `Samen.Web.TenantActorGuardTest` (and the hosts' own guard tests): they find the ways tenant
  web code can act with a role nobody resolved.

  `Samen.Web.Plane.scope/2` (through `Samen.Web.Mount.scope/2`) builds the synthetic org-level actor with a FIXED
  `role: :member`. A surface acting for a signed-in person must derive its role from that person's membership
  (`Samen.Web.TenantActor.scope/3`); one that needs the fixed role (system, job, seed, the disarmed dev posture)
  must say so by name (`TenantActor.system_scope/2`). Four detectors, each a per-file count the guard test
  RATCHETS (a file may not gain one, a new file may not appear with one, a converted file must lower its entry):

    * `implicit_calls/1` - the fixed-role scope calls: `Mount.scope(` / `Plane.scope(` under any alias
      (`alias Samen.Web.Mount, as: M`), the `&Mount.scope/2` capture, `apply(Mount, :scope, ...)` and an
      `import` of either module that does not exclude `scope`.
    * `literal_actors/1` - a literal tenant actor map (`id:`, `org_id:` and a literal `role: :atom` in one map):
      the same fixed role, spelled by hand.
    * `escape_hatches/1` - the named ways to ask for a role without resolving one: `system_scope(`,
      `TenantRole.admin_scope(` and `Reads.user_scope(` called WITHOUT a role (fewer than four arguments).
  """

  @call ~r/\b(?:Mount|Plane)\.scope\(/
  @capture ~r/&\s*(?:[A-Z][A-Za-z0-9_]*\.)*(?:Mount|Plane)\.scope\/\d/
  @apply ~r/\bapply\(\s*(?:[A-Z][A-Za-z0-9_]*\.)*(?:Mount|Plane)\s*,\s*:scope\b/
  @alias_as ~r/\balias\s+(?:[A-Z][A-Za-z0-9_]*\.)*(?:Mount|Plane)\s*,\s*as:\s*([A-Z][A-Za-z0-9_]*)/
  @import ~r/^\s*import\s+(?:[A-Z][A-Za-z0-9_]*\.)*(?:Mount|Plane)\b(.*)$/

  @doc "How many fixed-role scope calls `source` makes (comment lines are ignored)."
  @spec implicit_calls(String.t()) :: non_neg_integer()
  def implicit_calls(source) when is_binary(source) do
    lines = code_lines(source)
    aliases = for line <- lines, [_, name] <- Regex.scan(@alias_as, line), do: name
    alias_res = for name <- Enum.uniq(aliases), do: Regex.compile!("\\b#{name}\\.scope\\(|&\\s*#{name}\\.scope\\/\\d")

    lines
    |> Enum.map(fn line ->
      count(@call, line) + count(@capture, line) + count(@apply, line) + import_count(line) +
        Enum.sum(for re <- alias_res, do: count(re, line))
    end)
    |> Enum.sum()
  end

  # An `import` of Mount/Plane puts a bare `scope(` in reach; it is fine only when it names what it takes and
  # `scope` is not among it (`only: [...]`), or excludes it (`except: [scope: 2]`).
  defp import_count(line) do
    case Regex.run(@import, line) do
      nil -> 0
      [_, rest] -> if import_excludes_scope?(rest), do: 0, else: 1
    end
  end

  defp import_excludes_scope?(rest) do
    cond do
      String.contains?(rest, "only:") -> not String.contains?(rest, "scope")
      String.contains?(rest, "except:") -> String.contains?(rest, "scope")
      true -> false
    end
  end

  @actor_map ~r/%\{[^%{}]*\}/s

  @doc "How many literal tenant actor maps (`id:`, `org_id:` and a literal `role: :atom` in one map) `source` builds."
  @spec literal_actors(String.t()) :: non_neg_integer()
  def literal_actors(source) when is_binary(source) do
    source
    |> code_lines()
    |> Enum.join("\n")
    |> String.replace(~r/#\{[^{}]*\}/, "X")
    |> then(&Regex.scan(@actor_map, &1))
    |> Enum.count(fn [map] ->
      Regex.match?(~r/\bid:/, map) and Regex.match?(~r/\borg_id:/, map) and Regex.match?(~r/\brole:\s*:[a-z_]+/, map)
    end)
  end

  @doc """
  How many escape-hatch calls `source` makes: `system_scope(`, `admin_scope(` and `user_scope(` with fewer than four
  arguments (no role). Definitions (`def`/`defp`) and comments are not calls.
  """
  @spec escape_hatches(String.t()) :: non_neg_integer()
  def escape_hatches(source) when is_binary(source) do
    code = source |> code_lines() |> Enum.reject(&String.match?(&1, ~r/^\s*(?:@spec\s|(?:defp?|defmacrop?)\s+)(?:system_scope|admin_scope|user_scope)\b/)) |> Enum.join("\n")

    system = count(~r/\bsystem_scope\(/, code)
    admin = count(~r/\badmin_scope\(/, code)
    user = code |> calls("user_scope") |> Enum.count(&(&1 < 4))
    system + admin + user
  end

  # The argument count of every `name(...)` call in `code` (top-level commas of the balanced parentheses).
  defp calls(code, name) do
    for [{start, len}] <- Regex.scan(Regex.compile!("\\b" <> name <> "\\("), code, return: :index),
        do: code |> binary_part(start + len, byte_size(code) - start - len) |> arg_count()
  end

  defp arg_count(rest), do: scan_args(rest, 0, 0, false)

  defp scan_args(<<>>, _depth, commas, any?), do: total(commas, any?)
  defp scan_args(<<")", _::binary>>, 0, commas, any?), do: total(commas, any?)
  defp scan_args(<<c, rest::binary>>, depth, commas, _any?) when c in [?(, ?[, ?{], do: scan_args(rest, depth + 1, commas, true)
  defp scan_args(<<c, rest::binary>>, depth, commas, any?) when c in [?), ?], ?}], do: scan_args(rest, depth - 1, commas, any?)
  defp scan_args(<<",", rest::binary>>, 0, commas, _any?), do: scan_args(rest, 0, commas + 1, true)
  defp scan_args(<<c, rest::binary>>, depth, commas, any?), do: scan_args(rest, depth, commas, any? or c not in [?\s, ?\n, ?\t])

  defp total(commas, any?), do: if(any?, do: commas + 1, else: 0)

  defp count(re, text), do: length(Regex.scan(re, text))

  defp code_lines(source), do: source |> String.split("\n") |> Enum.reject(&String.match?(&1, ~r/^\s*#/))

  @doc "`%{relative_path => count}` for every `.ex` under `root` where `fun` (a `source -> count` detector) finds at least one."
  @spec scan(String.t(), (String.t() -> non_neg_integer())) :: %{String.t() => pos_integer()}
  def scan(root, fun \\ &implicit_calls/1) when is_function(fun, 1) do
    for file <- Path.wildcard(Path.join(root, "**/*.ex")),
        n = fun.(File.read!(file)),
        n > 0,
        into: %{},
        do: {Path.relative_to(file, root), n}
  end
end

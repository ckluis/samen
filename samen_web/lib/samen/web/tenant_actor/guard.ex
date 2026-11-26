defmodule Samen.Web.TenantActor.Guard do
  @moduledoc """
  The detectors behind `Samen.Web.TenantActorGuardTest` (and the hosts' own guard tests): they find the ways tenant
  web code can act with a role nobody resolved.

  `Samen.Web.Plane.scope/2` (through `Samen.Web.Mount.scope/2`) builds the synthetic org-level actor with a FIXED
  `role: :member`. A surface acting for a signed-in person must derive its role from that person's membership
  (`Samen.Web.TenantActor.scope/3`); one that needs the fixed role (system, job, seed, the disarmed dev posture)
  must say so by name (`TenantActor.system_scope/2`). Detectors, each a per-file count the guard test
  RATCHETS (a file may not gain one, a new file may not appear with one, a converted file must lower its entry):

    * `implicit_calls/1` - the fixed-role scope calls: `Mount.scope(` / `Plane.scope(` under any alias
      (`alias Samen.Web.Mount, as: M`), the `&Mount.scope/2` capture, `apply(Mount, :scope, ...)` and an
      `import` of either module that does not exclude `scope`.
    * `literal_actors/1` - a literal role, spelled by hand: a map with `org_id:` and a literal `role: :atom` (an
      id-less `%{org_id: o, role: :admin}` is all `OrgScope` and `RoleAtLeast` need, so `id:` is not required; a
      nested map is found on its own), a map update `%{actor | role: :admin}`, `Map.put(actor, :role, :admin)` and
      `Map.merge(actor, %{role: :admin})`.
    * `escape_hatches/1` - the named ways to ask for a role without resolving one: `system_scope(`,
      `TenantRole.admin_scope(` and `Reads.user_scope(` called WITHOUT a role (fewer than four arguments, or a
      literal `nil` role, which falls back to `:member`).
    * `foreign_write_scopes/1` - a `TenantActor.write_scope(` call that could pass a scope other than the page's own acting
      scope: its third argument must be the socket's acting scope (`acting`, a variable bound from `acting_scope:` of
      `socket.assigns`, `acting_scope`, `socket.assigns.acting_scope`); a literal `nil`, any other expression, a
      `&TenantActor.write_scope/3` capture, an `apply` and an `import` of the module are all counted. (On an armed mount the
      function itself refuses a non-scope; this keeps a caller from handing it someone else's scope, or none, unseen.)
  """

  @call ~r/\b(?:Mount|Plane)\.scope\(/
  @capture ~r/&\s*(?:[A-Z][A-Za-z0-9_]*\.)*(?:Mount|Plane)\.scope\/\d/
  @apply ~r/\bapply\(\s*(?:[A-Z][A-Za-z0-9_]*\.)*(?:Mount|Plane)\s*,\s*:scope\b/
  # `\s` spans newlines: the pattern is run over the whole source, so `alias ...Mount,\n  as: M` is seen too.
  @alias_as ~r/\balias\s+(?:[A-Z][A-Za-z0-9_]*\.)*(?:Mount|Plane)\s*,\s*as:\s*([A-Z][A-Za-z0-9_]*)/
  @import ~r/^\s*import\s+(?:[A-Z][A-Za-z0-9_]*\.)*(?:Mount|Plane)\b(.*)$/

  @doc "How many fixed-role scope calls `source` makes (comment lines are ignored)."
  @spec implicit_calls(String.t()) :: non_neg_integer()
  def implicit_calls(source) when is_binary(source) do
    lines = code_lines(source)
    aliases = for [_, name] <- Regex.scan(@alias_as, Enum.join(lines, "\n")), do: name
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

  # `scope:` as a keyword KEY (`scope_kind: 1` is another function and says nothing about `scope`).
  @scope_key ~r/\bscope:/

  defp import_excludes_scope?(rest) do
    named? = Regex.match?(@scope_key, rest)

    cond do
      String.contains?(rest, "only:") -> not named?
      String.contains?(rest, "except:") -> named?
      true -> false
    end
  end

  @doc """
  How many hand-spelled roles `source` has: a map literal with `org_id:` and a literal `role: :atom` (its own top
  level, so a nested map counts on its own and an outer map is not hidden by an inner one), a map update
  `%{x | role: :atom}`, `Map.put(x, :role, :atom)` and `Map.merge(x, %{role: :atom})`.
  """
  @spec literal_actors(String.t()) :: non_neg_integer()
  def literal_actors(source) when is_binary(source) do
    # Comments and heredoc text (a `@moduledoc` that SHOWS `Map.put(actor, :role, :admin)`) are not code.
    code =
      source
      |> String.replace(~r/"""[\s\S]*?"""/, "")
      |> code_lines_of()
      |> Enum.join("\n")
      |> String.replace(~r/#\{[^{}]*\}/, "X")

    maps = Enum.count(map_bodies(code), &literal_role_map?/1)
    puts = count(~r/\bMap\.put\(\s*[^,()]+,\s*:role\s*,\s*:[a-z_]+/, code)
    merges = count(~r/\bMap\.merge\([^()]*%\{[^{}]*\brole:\s*:[a-z_]+/, code)
    maps + puts + merges
  end

  @role_literal ~r/\brole:\s*:[a-z_]+/

  # `%{org_id: o, role: :atom}` (an actor) or `%{actor | role: :atom}` (an update of one).
  defp literal_role_map?(body) do
    Regex.match?(@role_literal, body) and (Regex.match?(~r/\borg_id:/, body) or String.contains?(body, "|"))
  end

  # The top-level text of every `%{...}` literal in `code`: nested brackets are removed, and each nested map is its
  # own entry (found from its own `%{`), so neither shape hides the other.
  defp map_bodies(code) do
    for [{start, len}] <- Regex.scan(~r/%\{/, code, return: :index) do
      code |> binary_part(start + len, byte_size(code) - start - len) |> top_level(0, [])
    end
  end

  defp top_level(<<>>, _depth, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp top_level(<<"}", _::binary>>, 0, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp top_level(<<c, rest::binary>>, depth, acc) when c in [?{, ?(, ?[], do: top_level(rest, depth + 1, acc)
  defp top_level(<<c, rest::binary>>, depth, acc) when c in [?}, ?), ?]], do: top_level(rest, depth - 1, acc)
  defp top_level(<<c, rest::binary>>, 0, acc), do: top_level(rest, 0, [<<c>> | acc])
  defp top_level(<<_, rest::binary>>, depth, acc), do: top_level(rest, depth, acc)

  @doc """
  How many escape-hatch calls `source` makes: `system_scope(`, `admin_scope(` and `user_scope(` with fewer than four
  arguments (no role). Definitions (`def`/`defp`) and comments are not calls.
  """
  @spec escape_hatches(String.t()) :: non_neg_integer()
  def escape_hatches(source) when is_binary(source) do
    code = source |> code_lines() |> Enum.reject(&String.match?(&1, ~r/^\s*(?:@spec\s|(?:defp?|defmacrop?)\s+)(?:system_scope|admin_scope|user_scope)\b/)) |> Enum.join("\n")

    system = count(~r/\bsystem_scope\(/, code)
    admin = count(~r/\badmin_scope\(/, code)
    user = code |> calls("user_scope") |> Enum.count(&role_less?/1)
    system + admin + user
  end

  # A `user_scope` call names no role when it has fewer than four arguments, or its fourth is a literal `nil`.
  defp role_less?(args), do: length(args) < 4 or args |> Enum.at(3) |> String.trim() == "nil"

  # The arguments (source text, split at the top-level commas of the balanced parentheses) of every `name(...)` call.
  defp calls(code, name) do
    for [{start, len}] <- Regex.scan(Regex.compile!("\\b" <> name <> "\\("), code, return: :index),
        do: code |> binary_part(start + len, byte_size(code) - start - len) |> split_args(0, "", [])
  end

  defp split_args(<<>>, _depth, cur, acc), do: finish_args(cur, acc)
  defp split_args(<<")", _::binary>>, 0, cur, acc), do: finish_args(cur, acc)
  defp split_args(<<c, rest::binary>>, depth, cur, acc) when c in [?(, ?[, ?{], do: split_args(rest, depth + 1, cur <> <<c>>, acc)
  defp split_args(<<c, rest::binary>>, depth, cur, acc) when c in [?), ?], ?}], do: split_args(rest, depth - 1, cur <> <<c>>, acc)
  defp split_args(<<",", rest::binary>>, 0, cur, acc), do: split_args(rest, 0, "", [cur | acc])
  defp split_args(<<c, rest::binary>>, depth, cur, acc), do: split_args(rest, depth, cur <> <<c>>, acc)

  defp finish_args(cur, acc), do: if(String.trim(cur) == "" and acc == [], do: [], else: Enum.reverse([cur | acc]))

  @write_scope_acting ~w(acting acting_scope socket.assigns.acting_scope assigns.acting_scope)

  @doc """
  How many `TenantActor.write_scope(` uses `source` has that are not demonstrably the page's own acting scope: a third
  argument other than `acting` / `acting_scope` / `socket.assigns.acting_scope` / `assigns.acting_scope` (so a literal `nil`
  counts), a `&TenantActor.write_scope/3` capture, `apply(TenantActor, :write_scope, ...)` and an `import` of the module
  that does not exclude `write_scope`. Comments and heredoc text are not code; a definition is not a call.
  """
  @spec foreign_write_scopes(String.t()) :: non_neg_integer()
  def foreign_write_scopes(source) when is_binary(source) do
    code =
      source
      |> String.replace(~r/"""[\s\S]*?"""/, "")
      |> code_lines_of()
      |> Enum.join("\n")

    args = for a <- calls_qualified(code, "TenantActor.write_scope"), do: Enum.map(a, &String.trim/1)
    bad_args = Enum.count(args, fn a -> length(a) != 3 or Enum.at(a, 2) not in @write_scope_acting end)

    captures = count(~r/&\s*(?:[A-Z][A-Za-z0-9_]*\.)*TenantActor\.write_scope\/\d/, code)
    applies = count(~r/\bapply\(\s*(?:[A-Z][A-Za-z0-9_]*\.)*TenantActor\s*,\s*:write_scope\b/, code)

    imports =
      code
      |> String.split("\n")
      |> Enum.count(fn line ->
        case Regex.run(~r/^\s*import\s+(?:[A-Z][A-Za-z0-9_]*\.)*TenantActor\b(.*)$/, line) do
          nil -> false
          [_, rest] -> not import_excludes?(rest, "write_scope")
        end
      end)

    bad_args + captures + applies + imports
  end

  defp import_excludes?(rest, name) do
    named? = Regex.match?(Regex.compile!("\\b#{name}:"), rest)

    cond do
      String.contains?(rest, "only:") -> not named?
      String.contains?(rest, "except:") -> named?
      true -> false
    end
  end

  # The argument lists of every `prefix(...)` call (the prefix is a literal, dots included).
  defp calls_qualified(code, prefix) do
    for [{start, len}] <- Regex.scan(Regex.compile!("\\b" <> Regex.escape(prefix) <> "\\("), code, return: :index),
        do: code |> binary_part(start + len, byte_size(code) - start - len) |> split_args(0, "", [])
  end

  defp count(re, text), do: length(Regex.scan(re, text))

  defp code_lines(source), do: code_lines_of(source)
  defp code_lines_of(source), do: source |> String.split("\n") |> Enum.reject(&String.match?(&1, ~r/^\s*#/))

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

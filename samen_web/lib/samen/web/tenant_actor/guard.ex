defmodule Samen.Web.TenantActor.Guard do
  @moduledoc """
  The detector behind `Samen.Web.TenantActorGuardTest`: finds the IMPLICIT fixed-role scope calls
  (`Mount.scope(`, `Plane.scope(`) in tenant web code.

  Those calls build the synthetic org-level actor with a fixed `role: :member`
  (`Samen.Web.Plane.scope/2`). A surface acting for a signed-in person must derive its role from
  that person's membership (`Samen.Web.TenantActor.scope/3`); one that needs the fixed role
  (system, job, seed, the disarmed dev posture) must say so by name (`TenantActor.system_scope/2`).
  The guard test holds a per-file RATCHET over the sites not yet converted: a file may not gain a
  call, a new file may not appear with one, and a converted file may not regress.
  """

  @call ~r/\b(?:Mount|Plane)\.scope\(/

  @doc "How many implicit fixed-role scope calls `source` makes (comment lines are ignored)."
  @spec implicit_calls(String.t()) :: non_neg_integer()
  def implicit_calls(source) when is_binary(source) do
    source
    |> String.split("\n")
    |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
    |> Enum.map(&length(Regex.scan(@call, &1)))
    |> Enum.sum()
  end

  @doc "`%{relative_path => count}` for every `.ex` under `root` with at least one implicit call."
  @spec scan(String.t()) :: %{String.t() => pos_integer()}
  def scan(root) do
    for file <- Path.wildcard(Path.join(root, "**/*.ex")),
        n = implicit_calls(File.read!(file)),
        n > 0,
        into: %{},
        do: {Path.relative_to(file, root), n}
  end
end

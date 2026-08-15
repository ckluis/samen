defmodule Samen.AI.Agent.Approver do
  @moduledoc """
  Resolve the DECIDING party of an agent write proposal to a REAL org member with
  their REAL role (ADR-047 §5.3; the A4 verifier's R2 finding, closed at A5).

  ## What this replaces, and why it had to

  A4 executed an approved write as
  `%Samen.Scope{id: <the id the engine handed us>, org_id: run.org_id, role: :member}` —
  a SYNTHESIZED scope. Two defects, both closed here:

    1. **membership was never verified.** The id came from an unvalidated argument
       (`ctx.actor` on the handler contract), so a wholly foreign actor id executed a
       governed write in the run's org. The engine's own `decide/4` checks blank /
       not-pending / distinct-party and nothing else — it never asserts the approver
       belongs to the approval's org. A4 was mitigated only by there being no approve
       surface; **A5 ships one**, so A5 owns the fix;
    2. **the role was hardcoded `:member`.** An approver whose real role is NARROWER
       than `:member` was silently ELEVATED (the exact direction ADR-040 §4.4's
       requester/approver rule guards), and an approver whose real role is WIDER was
       silently refused writes their envelope actually permits.

  So the approver is now resolved from the host's REAL membership store at decision
  time, and their REAL role rides the scope the governed action executes under. A
  non-member is refused `{:error, :not_authorized}` — the whole E3 decision rolls back,
  the approval stays `pending`, nothing executed.

  ## The host seam (fail-CLOSED when unwired)

  `samen_core` cannot name the membership resource: `Identity.Membership` is
  materialized INTO the host's namespace by `use Samen.Scopes.Identity` (ADR-004
  library-authored blueprints), so the kernel is handed the module by config —
  the `Samen.Approvals.Registry` / `:reveal_grant` seam shape:

      # the ≈0-LOC vertical path — point at the host's materialized Membership resource
      config :samen_core, Samen.AI.Agent,
        approver_membership: Driftwood.Operator.Membership

      # or an explicit {module, function} of arity 2 for a host with a different shape
      config :samen_core, Samen.AI.Agent,
        approver_membership: {MyApp.Approvers, :resolve}

  An UNWIRED host resolves `{:error, :approver_unresolvable}` — fail-closed, and honest
  in the same direction as `:approval_unavailable` (an unwired approvals engine): the
  failure mode of a host that has not wired membership is *"the agent's write cannot be
  approved"*, never *"the write executed under a synthesized member"*. This is the same
  posture the fail-honest adapter contract takes everywhere else (ADR-014/024/026): a
  seam that cannot do the work refuses rather than claiming it did.

  ## The resource path

  Given an Ash resource, the resolver reads ONE row filtered
  `user_id == ^approver_id and org_id == ^org_id` and takes its `role` — the
  `Samen.Auth.OrgActor.resolve/3` rule ("the actor role is read from the Membership,
  not hardcoded `:member`", ADR-035 §3.1), applied to the approver. The role is
  normalized through `Samen.Scope`'s closed `Samen.Scope.Role` set: an unknown/blank
  role is `nil`, which every RBAC check treats as unprivileged — so an unrecognized
  role can only ever SUBTRACT authority, never add it.

  The read is `authorize?: false` because this IS the authorization-boundary read that
  establishes the actor (the `Samen.Auth.OrgActor` precedent) — it is pinned to the
  RUN's org id, taken from the durable run row, never from a caller argument.
  """

  require Ash.Query

  @type resolution :: {:ok, Samen.Scope.t()} | {:error, :not_authorized | :approver_unresolvable}

  @doc """
  Resolve `approver_id` to a `%Samen.Scope{}` in `org_id` — a REAL membership with its
  REAL role — or refuse.

    * `{:ok, scope}` — the approver holds a membership row in this org; the scope carries
      that row's role and id;
    * `{:error, :not_authorized}` — no membership row in this org (a foreign actor, a
      removed member, a blank id);
    * `{:error, :approver_unresolvable}` — the host has not wired the membership seam, or
      the seam itself failed. Fail-closed: nothing executes.
  """
  @spec resolve(term(), term()) :: resolution()
  def resolve(approver_id, org_id) when is_binary(approver_id) and is_binary(org_id) do
    cond do
      approver_id == "" or org_id == "" -> {:error, :not_authorized}
      true -> resolve_wired(seam(), approver_id, org_id)
    end
  end

  def resolve(_approver_id, _org_id), do: {:error, :not_authorized}

  @doc "The configured membership seam (`nil` when the host has not wired one)."
  @spec seam() :: module() | {module(), atom()} | nil
  def seam do
    case Application.get_env(:samen_core, Samen.AI.Agent, [])[:approver_membership] do
      {mod, fun} when is_atom(mod) and is_atom(fun) -> {mod, fun}
      mod when is_atom(mod) and not is_nil(mod) -> mod
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------

  defp resolve_wired(nil, _approver_id, _org_id), do: {:error, :approver_unresolvable}

  defp resolve_wired({mod, fun}, approver_id, org_id) do
    normalize(apply(mod, fun, [approver_id, org_id]), approver_id, org_id)
  rescue
    _ -> {:error, :approver_unresolvable}
  end

  defp resolve_wired(resource, approver_id, org_id) when is_atom(resource) do
    resource
    |> Ash.Query.filter(user_id == ^approver_id and org_id == ^org_id)
    |> Ash.Query.ensure_selected([:id, :role])
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [membership]} -> scope_for(approver_id, org_id, membership)
      {:ok, []} -> {:error, :not_authorized}
      {:error, _} -> {:error, :approver_unresolvable}
    end
  rescue
    _ -> {:error, :approver_unresolvable}
  end

  # A custom seam may answer with a membership-ish map, a bare role, or a refusal. Every
  # shape that does not carry a positive membership answer is a REFUSAL — never a
  # default-member fallback (that would re-introduce exactly the synthesis this closes).
  defp normalize({:ok, %{} = membership}, approver_id, org_id),
    do: scope_for(approver_id, org_id, membership)

  defp normalize({:ok, role}, approver_id, org_id) when is_atom(role) or is_binary(role),
    do: scope_for(approver_id, org_id, %{role: role})

  defp normalize(:error, _approver_id, _org_id), do: {:error, :not_authorized}
  defp normalize({:error, :not_authorized}, _approver_id, _org_id), do: {:error, :not_authorized}
  defp normalize({:error, _reason}, _approver_id, _org_id), do: {:error, :approver_unresolvable}
  defp normalize(nil, _approver_id, _org_id), do: {:error, :not_authorized}
  defp normalize(_other, _approver_id, _org_id), do: {:error, :approver_unresolvable}

  defp normalize_role(role) when is_atom(role) and not is_nil(role), do: Atom.to_string(role)
  defp normalize_role(role) when is_binary(role), do: role
  defp normalize_role(_role), do: nil

  defp scope_for(approver_id, org_id, membership) do
    {:ok,
     Samen.Scope.new(%{
       id: approver_id,
       org_id: org_id,
       # The REAL role off the membership row, rendered to a STRING so `Samen.Scope`
       # resolves it against the CLOSED `Samen.Scope.Role` set: a recognized role comes
       # back as its atom, an unrecognized one lands `nil` (unprivileged), never
       # `:member`. Passing a raw atom straight through would SKIP that check.
       role: normalize_role(Map.get(membership, :role)),
       membership_id: Map.get(membership, :id)
     })}
  end
end

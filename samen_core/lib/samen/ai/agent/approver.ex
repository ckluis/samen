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

  ## `{:ok, nil}` is a REFUSAL, not a membership (A6 — the A5 verifier's R-A5-2)

  A custom `{m, f}` seam's natural spelling of *"no membership found"* is `{:ok, nil}`.
  Elixir's `nil` **is** an atom, so it matched the `{:ok, role} when is_atom(role)` clause
  and resolved to a real `%Samen.Scope{role: nil}` — an ambiguous affirmative admitted as
  a positive membership answer, while a bare `nil` correctly refused. That is the exact
  default-member synthesis this module exists to close, one shape over. `{:ok, nil}` now
  refuses `{:error, :not_authorized}`, ahead of the atom clause. The sanctioned Ash-resource
  path was never affected (it requires a real row); this closes the host-seam contract.

  ## The `nil`-ROLE posture, decided and pinned (A6)

  A membership row whose `role` is outside `Samen.Scope.Role`'s closed set normalizes to
  `nil` — deliberately, so an unrecognized role can only ever SUBTRACT authority. The A5
  verifier observed that a `nil`-role approver nonetheless executed an org-scoped governed
  write *identically to a `:member` one*, and asked whether `nil` should therefore refuse
  outright. **It should not, and the equivalence is intended:** role gating is the TARGET
  RESOURCE's job, not this resolver's.

    * On a target gated only by `Samen.Policy.OrgScope` (which keys on ORG, not role —
      the A4 fixture target) there is no role gate to fail open: `nil` and `:member`
      execute alike because the resource asked nothing about role.
    * On a target that DOES consult role — `Samen.Policy.RoleAtLeast`, which the shipped
      `Driftwood.Work.Task` write path carries — `nil` ranks `-1` and is REFUSED where
      `:member` is admitted. Proven live in the A6 vertical e2e (`:viewer` and `:member`
      approvers of the *same* proposal diverge, and the refusal rolls the whole decision
      back: approval still pending, run still parked, record unmutated).

  So `nil` is strictly narrower than `:member` everywhere role is consulted, and
  indistinguishable only where role is deliberately not consulted. Refusing `nil`-role
  membership here instead would refuse legitimate hosts whose membership rows carry role
  vocabulary outside the framework's closed set — a host-vocabulary decision the kernel
  has no standing to make. What the resolution guarantees is what §5.3 needs: the approver
  is a REAL member of the run's org, and the role recorded on the turn row
  (`meta.approver_role`) is their REAL one, never a synthesized `:member`. Pinned by the
  named `nil`-role tests in `samen_core/test/ai/agent_write_test.exs`.
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
    # A6: an approver id that cannot even be CAST to the seam's key type (e.g. the
    # synthetic `"broker:<org_id>"` tenant-plane pseudo-principal against a `:uuid`
    # `user_id`) is not a seam failure — it is a principal that provably holds no
    # membership row. Refuse `:not_authorized` (the honest "you are not a member of this
    # org" the surface reports) instead of letting the filter's cast error degrade into
    # `:approver_unresolvable` ("approvals are not wired on this host"), which would
    # misattribute a caller problem to the operator's configuration. Both are refusals —
    # nothing executes either way — but only one of them is TRUE.
    if castable_key?(resource, approver_id) do
      read_membership(resource, approver_id, org_id)
    else
      {:error, :not_authorized}
    end
  end

  defp castable_key?(resource, approver_id) do
    case Ash.Resource.Info.attribute(resource, :user_id) do
      %{type: type, constraints: constraints} ->
        match?({:ok, _}, Ash.Type.cast_input(type, approver_id, constraints))

      _ ->
        true
    end
  rescue
    _ -> true
  end

  defp read_membership(resource, approver_id, org_id) do
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

  # A6 (R-A5-2): `{:ok, nil}` — the natural spelling of "no membership found" — is a
  # REFUSAL. It must be matched BEFORE the atom clause below, because `nil` is an atom
  # and would otherwise be admitted as a positive membership answer with a `nil` role.
  defp normalize({:ok, nil}, _approver_id, _org_id), do: {:error, :not_authorized}

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

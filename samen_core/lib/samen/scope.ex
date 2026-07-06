defmodule Samen.Scope do
  @moduledoc """
  The canonical Samen actor scope (T3.1). This is the `Ash.Scope`-compatible struct
  every tenant-plane request carries: **who** is acting (`actor`) and **which org**
  they act within (`org_id`), both derived from the actor's Identity membership.

  ## Why a scope, not a bare actor

  The doc's org-scope idiom (§runs 1; scope table) requires every tenant-plane read
  and write to be filtered by the acting org. Ash resolves the acting org from the
  actor, so the actor must carry `org_id`. Rather than pass `actor:` and `tenant:`
  separately at every call site (easy to forget → a cross-org leak), Samen wraps
  them in one `%Samen.Scope{}` and implements `Ash.Scope.ToOpts` so `scope: scope`
  threads both into every action. This is the "actor+org_id from membership" pattern
  the scope-authoring guide (§3) makes every scope copy.

  ## Building a scope from a membership

  `Samen.Scope.for_membership/1` is the one blessed constructor: given a loaded
  Identity membership (which carries `user_id`, `org_id`, and `role`), it returns a
  scope whose `actor` is a plain map the policies read
  (`%{id, org_id, role, membership_id}`) — no PII, only the RBAC-relevant facts.
  Policies key on `actor(:org_id)` and `actor(:role)`; the org-scope filter keys on
  `actor(:org_id)`.

  ## The actor shape (what policies see)

  The `actor` is a map with exactly:

    * `:id`            — the acting user's id (opaque uuid)
    * `:org_id`        — the org the actor is scoped to (the tenant boundary)
    * `:role`          — the actor's role name in that org (`Samen.Scope.Role`)
    * `:membership_id` — the membership row proving (user, org) association

  No name/email/PII is ever placed on the actor — the actor is an authorization
  subject, not a profile. This keeps the actor safe to log (it is bounded IDs +
  an enum role) and consistent with the `metric_labels`/`no_plaintext_pii` posture.
  """

  @enforce_keys [:actor]
  defstruct [:actor, :context]

  @type actor :: %{
          id: String.t(),
          org_id: String.t(),
          role: atom() | String.t(),
          membership_id: String.t() | nil
        }

  @type t :: %__MODULE__{actor: actor(), context: map() | nil}

  @doc """
  Build a scope from a loaded Identity membership struct/map.

  The membership must expose `id`, `user_id` (or `id` of the user), `org_id`, and
  `role`. Accepts either an Ash membership record or a plain map with those keys.
  Returns `%Samen.Scope{}` with a PII-free actor map.
  """
  @spec for_membership(map()) :: t()
  def for_membership(membership) do
    %__MODULE__{
      actor: %{
        id: fetch(membership, [:user_id, :usr_id]),
        org_id: fetch(membership, [:org_id, :mbr_org_id]),
        role: normalize_role(fetch(membership, [:role, :mbr_role])),
        membership_id: fetch(membership, [:id, :mbr_id])
      }
    }
  end

  @doc """
  Build a scope directly from an actor map. The map must carry `:id`, `:org_id`,
  and `:role`; `:membership_id` is optional. Raises if `:org_id` is missing — a
  scope with no org is a cross-org hazard and is refused (fail closed).
  """
  @spec new(map()) :: t()
  def new(%{org_id: org_id} = actor) when not is_nil(org_id) do
    %__MODULE__{
      actor: %{
        id: Map.get(actor, :id),
        org_id: org_id,
        role: normalize_role(Map.get(actor, :role)),
        membership_id: Map.get(actor, :membership_id)
      }
    }
  end

  def new(actor) do
    raise ArgumentError,
          "Samen.Scope.new/1 requires an :org_id (the tenant boundary). Building a " <>
            "scope with no org is a cross-org hazard — refusing. Got: #{inspect(actor)}"
  end

  defp fetch(source, keys) do
    Enum.find_value(keys, fn k ->
      cond do
        is_map(source) and Map.has_key?(source, k) -> Map.get(source, k)
        true -> nil
      end
    end)
  end

  defp normalize_role(role) when is_atom(role) and not is_nil(role), do: role

  defp normalize_role(role) when is_binary(role) do
    # Roles come from a closed set (Samen.Scope.Role.all/0). Never String.to_atom/1
    # on untrusted input; resolve against the known role atoms and fall back to nil
    # (which every RBAC check treats as unprivileged / fail closed).
    Enum.find(Samen.Scope.Role.all(), fn r -> Atom.to_string(r) == role end)
  end

  defp normalize_role(_), do: nil

  defimpl Ash.Scope.ToOpts do
    def get_actor(%{actor: actor}), do: {:ok, actor}
    # The org_id IS the Ash multitenancy tenant when a resource opts into
    # attribute multitenancy; for the policy-filter approach we leave tenant
    # unset and rely on the org-scope policy reading actor(:org_id).
    def get_tenant(_), do: :error

    def get_context(%{context: context}) when is_map(context),
      do: {:ok, %{shared: context}}

    def get_context(_), do: {:ok, %{}}

    def get_tracer(_), do: :error
    def get_authorize?(_), do: :error
  end
end

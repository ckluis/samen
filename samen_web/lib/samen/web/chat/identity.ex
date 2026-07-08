defmodule Samen.Web.Chat.Identity do
  @moduledoc """
  The **participant identity model** (ADR-012 §5) — the 3-state disclosure precedence and the
  per-participant plane-choice resolve. A SaaS employee chatting with a tenant sees the tenant
  participant's identity **masked by default** (`••••`, reveal-gated), UNLESS one of two stored
  disclosures applies.

  ## The three states — all through `PiiResolution`, no bespoke masking branch

    * **State 1 — MASKED BY DEFAULT (the floor).** `disclosure_mode = :masked` and the
      participant's `identity_shared = false`. The operator resolves the participant's identity
      on the OPERATOR plane → `%Masked{}` → `••••`. The only thing the operator sees is the
      non-PII `handle`.
    * **State 2 — INITIATOR OPT-IN PER CONVERSATION.** `disclosure_mode = :initiator_opt_in`
      and the initiator's `identity_shared = true`. That ONE participant's identity is resolved
      on the TENANT plane (clear, own-org — the tenant disclosing its OWN identity, which it is
      entitled to do). Every OTHER tenant participant who did not opt in stays `••••`.
    * **State 3 — TENANT-WIDE DISCLOSURE.** `disclosure_mode = :tenant_wide` (stamped at thread
      create from the org's `ChatDisclosureSetting`). EVERY tenant participant's identity is
      resolved on the TENANT plane for the operator's render (org-wide consent).

  ## The mechanism (masking BY CONSTRUCTION)

  Disclosure is NOT a reveal grant and NOT a `Vault.reveal` bypass. It is choosing WHICH
  PLANE'S ACTOR resolves that one subject's PII: a tenant-plane actor resolves the field clear
  (the tenant owns its own PII), an operator-plane actor resolves it `%Masked{}`. Both paths go
  through `Samen.Api.PiiResolution.resolve/4` — the ONLY difference is which plane's actor is
  passed (§5.1). Fail-safe: an unknown/absent `disclosure_mode` resolves to the masked floor,
  and any resolver error keeps `%Masked{}` (never a plaintext downgrade).

  Identity disclosure ≠ content disclosure: this module governs the participant CARD's identity
  only. Message BODIES are governed by the message body's own vault (`Samen.Web.Chat.Reads`),
  so even under `:tenant_wide` an operator's message bodies stay `••••` unless separately
  revealed (§5 state 3, red path 5).
  """

  alias Samen.Web.Mount

  @doc """
  The precedence function (ADR-012 §5.1) — is this participant's identity disclosed to the
  given `viewer_party`?

      viewer_party == :tenant                -> true   # tenant sees tenant, own-plane clear
      thread.disclosure_mode == :tenant_wide -> true   # state 3 (org consent)
      participant.identity_shared == true    -> true   # state 2 (initiator opt-in)
      _                                       -> false  # state 1 (masked floor)
  """
  @spec disclosed?(map(), map(), atom()) :: boolean()
  def disclosed?(thread, participant, viewer_party)

  def disclosed?(_thread, _participant, :tenant), do: true

  def disclosed?(%{disclosure_mode: :tenant_wide}, _participant, _viewer_party), do: true

  def disclosed?(_thread, %{identity_shared: true}, _viewer_party), do: true

  def disclosed?(_thread, _participant, _viewer_party), do: false

  @doc """
  Resolve ONE participant's identity for the VIEWER, per the stored disclosure state.

  Returns the participant with `full_name` resolved: CLEAR (a plaintext binary / `FullName`)
  when `disclosed?/3` is true — because it is resolved on the TENANT-plane actor for the
  participant's org — and `%Masked{}` (`••••`) otherwise (resolved on the viewer's own
  operator-plane actor). The non-PII `handle`/`party` pass through untouched.

  `mount` carries the repo; `scope` is the VIEWER's scope (its plane decides the non-disclosed
  path); `thread` carries the `disclosure_mode`; `participant` is a raw row from
  `Samen.Web.Chat.Reads.participants/3` (identity still `%Masked{}` for an operator viewer).
  """
  @spec resolve_participant(Mount.t(), Samen.Scope.t(), map(), map()) :: map()
  def resolve_participant(%Mount{} = mount, scope, thread, participant) do
    viewer_party = viewer_party(scope)
    actor = disclosure_actor(scope, thread, participant, viewer_party)

    [resolved] =
      Samen.Api.PiiResolution.resolve(
        [participant],
        Mount.resource(mount, ChatParticipant),
        actor,
        repo: mount.repo
      )

    resolved
  rescue
    # Fail-safe: keep the raw (still-masked-for-operator) participant, never a plaintext
    # downgrade and never a raise to the caller.
    _ -> participant
  end

  @doc """
  Resolve ALL of a thread's participants for the viewer (§5.2 render path). A convenience over
  `resolve_participant/4`. Each participant's identity is disclosed or masked per the stored
  state, independently — so under `:initiator_opt_in` only the opted-in participant is clear.
  """
  @spec resolve_participants(Mount.t(), Samen.Scope.t(), map(), [map()]) :: [map()]
  def resolve_participants(mount, scope, thread, participants) do
    Enum.map(participants, &resolve_participant(mount, scope, thread, &1))
  end

  # -- private -----------------------------------------------------------------

  # The viewer's plane party (`:tenant` / `:operator`).
  defp viewer_party(scope) do
    case actor_of(scope) do
      %{plane: :operator} -> :operator
      _ -> :tenant
    end
  end

  # Pick the actor that resolves THIS participant's identity:
  #
  #   * disclosed?  -> a TENANT-plane actor for the participant's org (clear; the tenant
  #                    discloses its OWN identity). This is the plane CHOICE that models
  #                    disclosure — not a reveal grant, not a vault bypass.
  #   * otherwise   -> the viewer's OWN actor (an operator viewer keeps `••••`; a tenant
  #                    viewer is already clear because viewer_party == :tenant is disclosed).
  defp disclosure_actor(scope, thread, participant, viewer_party) do
    if disclosed?(thread, participant, viewer_party) do
      tenant_actor(scope)
    else
      actor_of(scope)
    end
  end

  # A tenant-plane actor over the SAME org the viewer is scoped to. The tenant-as-owner rule:
  # a `plane: :tenant` actor reads its own org's PII in the clear (no reveal grant). This is
  # the disclosure resolve — the tenant org consenting to expose (org-wide or per-initiator).
  defp tenant_actor(scope) do
    org_id = actor_of(scope) |> Map.get(:org_id)

    %{
      id: "chat-disclosure:#{org_id}",
      org_id: org_id,
      role: :member,
      kind: :tenant,
      plane: :tenant
    }
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}
end

defmodule Samen.Web.Operator.DeliverabilityReads do
  @moduledoc """
  Operator per-tenant deliverability read layer (R2, T114; `_orch/ux/dogfood-report.md`
  R3 — P4 job-test 3, "why didn't this tenant get their email?"). Surfaces the T28/T30
  delivery substrate: `Samen.Delivery.EmailEvent` (`dlv_email_event` — the webhook-
  confirmed delivery/bounce/complaint/open/click history) and `Samen.Delivery.Suppression`
  (`dlv_suppression` — the current suppression fact) for ONE tenant org, cross-tenant
  (an operator drilling into ANY tenant org, not just the operator's own book).

  ## Recipient resolution — the ONLY new masking-relevant code this task adds

  Both `dlv_email_event` and `dlv_suppression` are, BY DESIGN, token-blind: no PII
  column exists on either (ADR-038 §4.4 / the `Suppression` moduledoc). Every
  recipient reference is an opaque `subscriber_id`. Resolving "who" for display
  looks the id up as an `Identity.User` in the SAME org (the identity blueprint
  every host mounts — the only family this framework-level surface can resolve
  generically; a marketing/CRM-family subscriber_id that isn't a User row
  resolves to `nil` and renders by its bounded id, NEVER fabricated) and then runs
  it through `Samen.Api.PiiResolution.resolve/4` — the SAME chokepoint every other
  framework read uses. This module holds no masking logic of its own.

  ## The operator actor (mirrors `Samen.Delivery.Rendering.operator_plane_actor/0`)

  This is a CROSS-TENANT lookup (the operator can view ANY tenant org's delivery
  state, not only its own book), so it does not ride `Samen.Web.Operator.scope/1`
  (which is the operator ORG's own tenant-plane scope). Instead it uses the SAME
  "operator previewing tenant PII without a live impersonation session" actor
  shape `Samen.Delivery.Rendering` already ships for operator message previews:
  `plane: :operator` + an impersonation marker — masked-but-PRESENT (`••••`) by
  default, PLAINTEXT the moment a live `Samen.Reveal` grant covers the specific
  subscriber (the SAME T1.6 reveal-grant model every other operator PII read
  honors). No new masking rule is invented here.
  """

  require Ash.Query

  alias Samen.Delivery.{EmailEvent, Suppression}
  alias Samen.Web.Mount

  @lookup_limit 200

  @doc """
  Assemble ONE tenant org's delivery/suppression state. Returns
  `%{events:, suppressions:, suppressed_subscriber_ids:}` — `events`/`suppressions`
  rows carry a `:__recipient__` key (`%{name:, email:}`, each possibly `%Masked{}`,
  or `nil` when the subscriber_id does not resolve to a known `Identity.User`).
  `suppressed_subscriber_ids` is a `MapSet` of every currently-suppressed
  subscriber, so a delivery-timeline row can flag itself "suppressed" without a
  second read. Any read error degrades to the all-empty shape — fail-honest,
  never a crash, never partial-with-a-lie.
  """
  @spec deliverability(Mount.t(), map(), String.t(), keyword()) :: map()
  def deliverability(mount, actor, org_id, opts \\ []) do
    events =
      mount.repo
      |> EmailEvent.list_for_org(org_id, limit: @lookup_limit)
      |> Enum.map(&with_recipient(&1, mount, actor, opts))

    suppressions =
      mount.repo
      |> Suppression.list_for_org(org_id, limit: @lookup_limit)
      |> Enum.map(&with_recipient(&1, mount, actor, opts))

    %{
      events: events,
      suppressions: suppressions,
      suppressed_subscriber_ids: MapSet.new(suppressions, & &1.subscriber_id)
    }
  rescue
    _ -> %{events: [], suppressions: [], suppressed_subscriber_ids: MapSet.new()}
  end

  defp with_recipient(row, mount, actor, opts) do
    Map.put(row, :__recipient__, resolve_recipient(mount, actor, row.org_id, row.subscriber_id, opts))
  end

  @doc """
  Resolve `subscriber_id` (opaque, org-scoped) to its display identity — a
  `%{name:, email:}` map whose values are plaintext (operator-with-grant),
  `%Samen.Masked{}` (operator-without-grant, renders `••••`), or absent fields
  per the SAME `Samen.Api.PiiResolution` rules every framework read follows.
  `nil` when no `Identity.User` matches (honest "cannot resolve", never a
  fabricated identity). `opts` (`:repo`/`:grant`/`:vault`) pass straight to the
  resolver — production callers pass none (the real configured
  `Samen.Reveal` grant checker decides); tests inject a grant stub.
  """
  @spec resolve_recipient(Mount.t(), map(), String.t(), String.t() | nil, keyword()) :: map() | nil
  def resolve_recipient(_mount, _actor, _org_id, nil, _opts), do: nil

  def resolve_recipient(mount, actor, org_id, subscriber_id, opts) do
    case find_user(mount, org_id, subscriber_id) do
      nil ->
        nil

      user ->
        [resolved] =
          Samen.Api.PiiResolution.resolve(
            [user],
            Mount.resource(mount, User),
            actor,
            Keyword.put_new(opts, :repo, mount.repo)
          )

        %{name: resolved.full_name, email: resolved.emails}
    end
  rescue
    _ -> nil
  end

  defp find_user(mount, org_id, subscriber_id) do
    Mount.resource(mount, User)
    |> Ash.Query.ensure_selected([:id, :org_id, :full_name, :emails])
    |> Ash.Query.filter(id == ^subscriber_id and org_id == ^org_id)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
  rescue
    _ -> nil
  end

  @doc """
  The canonical actor for THIS surface — see the moduledoc. `operator_id` is
  carried on the marker for future audit correlation (unused by the grant check
  today, mirrors `Samen.Impersonation.Scope`'s marker shape).
  """
  @spec operator_actor(String.t() | nil) :: map()
  def operator_actor(operator_id \\ nil) do
    %{
      plane: :operator,
      impersonation: %{session_id: "operator-deliverability", operator_id: operator_id}
    }
  end
end

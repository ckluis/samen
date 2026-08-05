defmodule Samen.Api.PiiResolution do
  @moduledoc """
  The API/webhook PII-resolution rule for the two key classes (T3.11; doc
  §external-surface). Given a resource's loaded records and the acting `%Samen.Scope{}`
  actor, it rewrites each vault-routed field to its plane-correct serialized value —
  the SAME rule the doc states:

    * a masked value serializes as `••••` (the `%Masked{}` default — untouched here);
    * a **tenant** key over its OWN org reads that PII in CLEAR, with NO reveal grant
      (the tenant owns its customers' PII; the reveal seam is operator-scoped and does
      not sit between a tenant and its own records);
    * an **operator** / cross-tenant key is masked by default: a vaulted field is
      **ABSENT** unless a live reveal grant covers the subject. "Absent" is real
      omission, not `••••` — the doc's "vaulted field is absent unless a reveal grant
      covers it." We implement absence by setting the field to `%Ash.ForbiddenField{}`,
      which the AshJsonApi serializer omits from the payload entirely.
    * an **impersonation** scope (T4.1; `plane: :operator` + an `:impersonation`
      marker) is masked but **PRESENT** — a vaulted field renders `••••` (`%Masked{}`),
      NOT omitted, because the doc's impersonation seam (§control) states "the operator
      opens a tenant and sees its real UI, but the session carries no reveal grant, so
      personal data renders •••• by default." So under impersonation the operator sees
      the tenant's REAL data shape with `••••` where PII would be, rather than the
      field vanishing. A live second-party reveal grant on top produces plaintext, the
      same as any operator path.

  ## Where this runs

  This is a pure function called from a read's `after_action` (the resource threads
  it — see the demo's `Demo.Api.PiiResolvePrep`). Running it at the RECORD level (not
  the JSON body) means the vault token is still present as `%Masked{token: …}`, so a
  granted read can decrypt through the single vault chokepoint (`Samen.Vault.reveal/3`)
  and a forbidden read never touches the vault at all (fail closed: no grant → no
  decrypt, field omitted).

  ## Plane resolution

  The plane comes off the actor map's `:plane` key (`:tenant | :operator`), set by the
  api_key auth resolver. An actor with no `:plane` (e.g. the internal UI scope) is
  treated as the default masked posture — vaulted fields stay `%Masked{}` (`••••`).
  This keeps the rule fail-safe: an unrecognised actor never gets plaintext.

  ## Subject + grant

  The grant is checked per subject = the record's own id (the data subject a User /
  Contact row is about), against the resource's declared reveal action and the field's
  label. The configured `Samen.Reveal.Grant` (default `DenyAll`) is the authority —
  the same T1.6 grant model the operator UI reveal uses. No approving grant ⇒ absent.
  """

  use Ash.Resource.Preparation

  alias Samen.Masked
  alias Samen.Pii.Info
  alias Samen.Reveal

  # --- Ash preparation face -------------------------------------------------

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def prepare(query, opts, context) do
    actor = context.actor
    resource = query.resource

    Ash.Query.after_action(query, fn _q, records ->
      resolved = resolve(records, resource, actor, resolve_opts(resource, opts))
      {:ok, resolved}
    end)
  end

  # Resolve the vault repo: explicit `:repo` opt wins; else the resource's own
  # AshPostgres repo; else the configured `:vault_repo`. Fail closed by leaving the
  # value masked if no repo (reveal_plaintext returns nil → keeps `%Masked{}`).
  defp resolve_opts(resource, opts) do
    repo =
      Keyword.get(opts, :repo) ||
        ash_postgres_repo(resource) ||
        Application.get_env(:samen_core, :vault_repo)

    Keyword.put(opts, :repo, repo)
  end

  defp ash_postgres_repo(resource) do
    if function_exported?(AshPostgres.DataLayer.Info, :repo, 2) do
      try do
        AshPostgres.DataLayer.Info.repo(resource, :read)
      rescue
        _ -> nil
      end
    end
  end

  @doc """
  Resolve the vault-routed fields on a list of records for `actor`.

  Options:
    * `:repo`   — REQUIRED for a plaintext path (decrypt). The masked (default) path needs
      no repo — it never touches the vault.
    * `:vault`  — the vault module (defaults to `Samen.Vault`; injectable for tests).
    * `:grant`  — override the grant checker module (defaults to
      `Samen.Reveal.grant_checker()`; injectable for tests).
    * `:egress` — when `true`, use the **AI-egress** resolution (ADR-043 §3.2/§6.1): every
      vault-routed field is `%Masked{}` (`••••`) on EVERY plane (masked-by-default, stricter
      than the tenant own-org-clear read), PRESENT never absent. Default `false` (the ordinary
      UI/API serialization rule above).
    * `:grant_egress?` — egress-mode-only host opt-in (ADR-043 §6.1, default `false`): when
      `true` AND a live reveal grant covers subject+label, egress resolves plaintext into the
      (ephemeral, `:complete`) payload — the one deliberately-permitted PII egress to the
      third-party provider. The caller (`Samen.AI.Chokepoint`) passes it ONLY for `:complete`,
      never `:embed`/`:mcp` (persisted/external egress — grants never apply, INV-7).

  Returns the records with each vault field set to its plane-correct value:
  plaintext (tenant own-org / operator-with-grant), `%Masked{}` (default), or
  `%Ash.ForbiddenField{}` (operator without grant → omitted by the serializer).
  """
  @spec resolve(list(struct()), module(), map() | nil, keyword()) :: list(struct())
  def resolve(records, resource, actor, opts) when is_list(records) do
    fields = Info.pii_attributes(resource)
    reveal_action = resource |> Info.reveal_actions() |> Enum.at(0)
    plane = plane_of(actor)

    Enum.map(records, fn record ->
      Enum.reduce(fields, record, fn %Samen.Pii.Attribute{name: name}, acc ->
        current = Map.get(acc, name)
        resolved = resolve_field(current, name, plane, acc, resource, reveal_action, actor, opts)
        Map.put(acc, name, resolved)
      end)
    end)
  end

  # Only a %Masked{} value is subject to plane resolution — a nil field stays nil.
  defp resolve_field(%Masked{} = masked, label, plane, record, resource, reveal_action, actor, opts) do
    # AI-egress mode (ADR-043 §3.2 step 1 / §6.1, the T65 chokepoint resolver). Egress is a
    # DIFFERENT trust boundary than a UI render: a UI renders to the data owner, an AI call
    # transmits to a third-party provider. So egress mode is masked-but-present on EVERY plane
    # (stricter than the tenant own-org-clear posture) — a vaulted field stays `%Masked{}`
    # (`••••`) regardless of plane, with exactly one exception: plaintext under a LIVE reveal
    # grant AND the host's `grant_plaintext_egress` opt-in (threaded here as `:grant_egress?`,
    # default off; the caller — `Samen.AI.Chokepoint` — passes it only for `:complete`, never
    # for `:embed`/`:mcp` per INV-7's persisted-egress rule). Never `%Ash.ForbiddenField{}`
    # (absence): egress wants the field PRESENT-but-`••••`, not vanished.
    if Keyword.get(opts, :egress, false) do
      resolve_egress(masked, label, record, resource, reveal_action, actor, opts)
    else
      resolve_render(masked, label, plane, record, resource, reveal_action, actor, opts)
    end
  end

  defp resolve_field(other, _label, _plane, _record, _resource, _reveal_action, _actor, _opts),
    do: other

  # The AI-egress resolution (ADR-043 §6.1). Default masked-but-present; plaintext ONLY when
  # BOTH the host opt-in (`:grant_egress?`) is on AND a live reveal grant covers subject+label
  # — the same grant model/authority/audit as the operator-UI reveal, but the destination is
  # the third-party provider. Fail-safe: a decrypt failure keeps `%Masked{}`, never raises.
  defp resolve_egress(masked, label, record, resource, reveal_action, actor, opts) do
    # T137: require a LITERAL `true` from the grant checker (same strictness as
    # `Samen.AI.Chokepoint.granted?/2` and `Samen.Reveal.granted?/2`). A host-injected grant
    # checker is adversarial input: one returning a truthy NON-true verdict (`:yes`, a map, a
    # PID, …) must NOT admit plaintext into the egress payload by accident. Anything but `true`
    # keeps the value masked (`••••`) — fail-closed, no plaintext egress.
    if Keyword.get(opts, :grant_egress?, false) and
         operator_granted?(record, label, resource, reveal_action, actor, opts) === true do
      reveal_plaintext(masked, opts) || masked
    else
      masked
    end
  end

  # The original per-plane serialization resolution (unchanged — the UI/API/webhook rule).
  defp resolve_render(masked, label, plane, record, resource, reveal_action, actor, opts) do
    case plane do
      :tenant ->
        # Tenant owns its own org's PII → clear, no grant. Fail closed on shred/KMS:
        # a failed decrypt leaves the masked value (`••••`), never raises a leak.
        reveal_plaintext(masked, opts) || masked

      :operator ->
        cond do
          operator_granted?(record, label, resource, reveal_action, actor, opts) ->
            reveal_plaintext(masked, opts) || masked_or_forbidden(masked, label, actor)

          # IMPERSONATION UI posture (T4.1; doc §control: "personal data renders ••••
          # by default"): under an impersonation session the operator sees the tenant's
          # REAL UI with the field PRESENT-but-masked (`••••`), NOT omitted. The API
          # operator-KEY posture below is different — a cross-tenant key omits the field.
          impersonated?(actor) ->
            masked

          # Operator API-KEY posture (T3.11; doc §external-surface: "a vaulted field is
          # absent unless a reveal grant covers it"). No grant → ABSENT (the serializer
          # omits %Ash.ForbiddenField{}).
          true ->
            forbidden(label)
        end

      _ ->
        # Unknown/absent plane → default masked posture (`••••`). Never plaintext.
        masked
    end
  end

  defp plane_of(actor) when is_map(actor), do: Map.get(actor, :plane)
  defp plane_of(_), do: nil

  # Is this actor an impersonation scope (T4.1)? The impersonation scope builder
  # (`Samen.Impersonation.Scope`) sets a `:impersonation` marker on the actor map. A
  # plain operator API-KEY actor has no such marker.
  defp impersonated?(actor) when is_map(actor) do
    case Map.get(actor, :impersonation) do
      %{session_id: _} -> true
      _ -> false
    end
  end

  defp impersonated?(_), do: false

  # On a granted read whose decrypt failed: an impersonation UI keeps `%Masked{}`
  # (`••••`, never absent); an operator API key omits the field (forbidden). Fail-safe
  # either way — no plaintext.
  defp masked_or_forbidden(masked, label, actor) do
    if impersonated?(actor), do: masked, else: forbidden(label)
  end

  defp reveal_plaintext(%Masked{} = masked, opts) do
    vault = Keyword.get(opts, :vault, Samen.Vault)

    case Keyword.get(opts, :repo) do
      nil ->
        # No repo → cannot decrypt. Fail closed: keep the value masked.
        nil

      repo ->
        case vault.reveal(masked, repo, []) do
          {:ok, plaintext} -> plaintext
          _ -> nil
        end
    end
  end

  defp operator_granted?(record, label, resource, reveal_action, actor, opts) do
    grant = Keyword.get(opts, :grant, Reveal.grant_checker())
    subject_id = Map.get(record, :id)

    # A resource with no declared reveal action can never be operator-revealed.
    reveal_action != nil and
      grant.granted?(%Reveal.Context{
        actor: actor,
        subject_id: subject_id,
        resource: resource,
        action: reveal_action,
        label: label
      })
  end

  defp forbidden(label) do
    %Ash.ForbiddenField{field: label, type: :attribute}
  end
end

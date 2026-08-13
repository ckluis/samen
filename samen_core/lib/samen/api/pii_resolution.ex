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

  ## Tier-1 `pii_declared` custom-bag keys (ADR-046 §4.2 · D3)

  A Tier-1 custom field declared `pii_declared: true` stores **plaintext PII in the
  `custom` jsonb bag** (never vault-routed — the honest seam, `custom_fields/schema.ex`).
  The bag is `public?: true`, so without resolution it would flow to the operator in the
  CLEAR on every generic surface (CSV / JSON:API / kit). This function ALSO resolves those
  bag keys through the SAME plane model, mask-by-omission: the value of a `tnt_pii_declared`
  bag key is replaced with a `%Masked{}` (`••••` — never the plaintext, never a token) on the
  operator-without-grant plane (and on the unknown/default and AI-egress planes), while the
  tenant plane (and operator-WITH-grant) keeps the plaintext. The set of pii_declared keys is
  a RUNTIME per-org fact read from the org's `tnt_field` catalog (`Samen.CustomFields`), so the
  masking is data-driven and generic — every resource carrying a `:custom` bag is masked
  by-construction, no per-resource wiring. (Unlike a vault field, a bag key is NOT vault-routed:
  there is no token to reveal, so the masked bag value carries `token: nil` and the
  operator-without-grant posture is present-but-`••••`, not omitted.)
  """
  @bag_attr :custom

  @spec resolve(list(struct()), module(), map() | nil, keyword()) :: list(struct())
  def resolve(records, resource, actor, opts) when is_list(records) do
    fields = Info.pii_attributes(resource)
    reveal_action = resource |> Info.reveal_actions() |> Enum.at(0)
    plane = plane_of(actor)
    bag_ctx = bag_context(resource, records, plane, actor, opts)

    Enum.map(records, fn record ->
      record
      |> resolve_pii_fields(fields, plane, resource, reveal_action, actor, opts)
      |> resolve_bag_keys(bag_ctx, plane, resource, reveal_action, actor, opts)
    end)
  end

  defp resolve_pii_fields(record, fields, plane, resource, reveal_action, actor, opts) do
    Enum.reduce(fields, record, fn %Samen.Pii.Attribute{name: name}, acc ->
      current = Map.get(acc, name)
      resolved = resolve_field(current, name, plane, acc, resource, reveal_action, actor, opts)
      Map.put(acc, name, resolved)
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

  # --- Tier-1 pii_declared custom-bag resolution (ADR-046 §4.2 · D3) ----------

  # Decide the bag-resolution posture for this resolve call, once. Returns:
  #   * `:skip`      — nothing to do: a NON-masking plane (tenant / non-egress — bag
  #     plaintext is legitimately allowed), OR the resource has no `:custom` bag, OR the
  #     org's catalog was read successfully and declares NO pii_declared bag key (a
  #     determinate "nothing to mask" — the bag rides along clear, no over-mask).
  #   * `{:bag, %{org => MapSet}, actor_org}` — determinate: mask exactly the org's
  #     pii_declared keys, per-key.
  #   * `:mask_all`  — FAIL-CLOSED: a MASKING plane (operator / unknown / AI-egress) with
  #     a `:custom` bag whose pii_declared key set is INDETERMINATE (no repo/table, or the
  #     org could not be resolved, or the catalog query FAILED). A masking resolver that
  #     cannot enumerate which keys are pii_declared must not emit ANY bag value in the
  #     clear — so it masks the WHOLE bag. (On a non-masking plane this branch is never
  #     reached, so the tenant/grant planes are never over-masked.)
  defp bag_context(resource, records, plane, actor, opts) do
    egress? = Keyword.get(opts, :egress, false)
    masking? = egress? or plane != :tenant

    cond do
      not masking? ->
        :skip

      not has_bag_attr?(resource) ->
        :skip

      true ->
        # The org whose `tnt_field` catalog governs these records. On an org-scoped read
        # every record shares the acting scope's org, which the actor reliably carries
        # (`org_id`, the tenant boundary — set for tenant AND operator/impersonation
        # planes). `org_id` is NOT select-by-default on a resource, so the record often
        # does not carry it — the actor is the reliable source; per-record org (when
        # loaded) is a fallback for ad-hoc/multi-org batches.
        repo = Keyword.get(opts, :repo)
        table = table_name(resource)
        actor_org = actor_org_id(actor)

        org_ids =
          [actor_org | Enum.map(records, &org_id_of/1)]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        cond do
          # INDETERMINATE on a masking plane → fail closed (mask the whole bag).
          is_nil(repo) or is_nil(table) or org_ids == [] ->
            :mask_all

          true ->
            case pii_declared_keys(repo, table, org_ids) do
              # The catalog query FAILED — we cannot enumerate the key set → fail closed.
              :error -> :mask_all
              # Determinate: the org declares no pii_declared bag key → nothing to mask.
              declared when map_size(declared) == 0 -> :skip
              declared -> {:bag, declared, actor_org}
            end
        end
    end
  end

  defp has_bag_attr?(resource) do
    match?(%{type: Ash.Type.Map}, Ash.Resource.Info.attribute(resource, @bag_attr))
  end

  defp table_name(resource) do
    AshPostgres.DataLayer.Info.table(resource)
  rescue
    _ -> nil
  end

  # Returns `%{org_id => MapSet.t(key)}` (possibly empty — a DETERMINATE "no pii_declared
  # keys") on success, or `:error` when the catalog could not be read — the caller fails
  # CLOSED on `:error`, never conflating "read it, none declared" with "could not read".
  defp pii_declared_keys(repo, table, org_ids) do
    Enum.reduce(org_ids, %{}, fn org_id, acc ->
      keys =
        org_id
        |> Samen.CustomFields.list_fields(table, repo)
        |> Enum.filter(& &1.tnt_pii_declared)
        |> MapSet.new(& &1.tnt_field_name)

      if MapSet.size(keys) == 0, do: acc, else: Map.put(acc, org_id, keys)
    end)
  rescue
    _ -> :error
  end

  defp resolve_bag_keys(record, :skip, _plane, _resource, _reveal_action, _actor, _opts), do: record

  # FAIL-CLOSED whole-bag mask (ADR-046 §4.2 D3): reached ONLY on a masking plane where
  # the pii_declared key set is indeterminate (see `bag_context/5`). No bag value may be
  # emitted in the clear, and grants cannot be evaluated without knowing the labels, so
  # EVERY non-nil key is masked — routed through the same `%Masked{}` path (never
  # hand-masked). This never runs on the tenant/grant determinate path, so those planes
  # keep the bag clear.
  defp resolve_bag_keys(record, :mask_all, _plane, _resource, _reveal_action, _actor, _opts) do
    case Map.get(record, @bag_attr) do
      bag when is_map(bag) ->
        masked = Map.new(bag, fn {k, v} -> {k, if(is_nil(v), do: v, else: bag_mask(k))} end)
        Map.put(record, @bag_attr, masked)

      _ ->
        record
    end
  end

  defp resolve_bag_keys(record, {:bag, declared, actor_org}, plane, resource, reveal_action, actor, opts) do
    org_id = org_id_of(record) || actor_org
    keys = org_id && Map.get(declared, org_id)
    bag = Map.get(record, @bag_attr)

    if is_nil(keys) or not is_map(bag) do
      record
    else
      new_bag =
        Enum.reduce(keys, bag, fn key, acc ->
          case Map.fetch(acc, key) do
            {:ok, value} when not is_nil(value) ->
              Map.put(acc, key, resolve_bag_value(value, key, plane, record, resource, reveal_action, actor, opts))

            _ ->
              acc
          end
        end)

      Map.put(record, @bag_attr, new_bag)
    end
  end

  # Plane-resolve ONE pii_declared bag value. The value is PLAINTEXT-in-bag (no
  # token to reveal), so masking replaces it with a `%Masked{}` (`••••`) rather than
  # decrypting anything:
  #   * AI-egress (any plane)          → `%Masked{}` (INV-7: bag PII must not egress;
  #     no bag grant-egress path — fail-closed masked-but-present).
  #   * tenant                         → plaintext (the tenant owns its org's PII).
  #   * operator WITH a live grant     → plaintext (same grant model as a vault reveal).
  #   * operator WITHOUT a grant       → `%Masked{}` (`••••`).
  #   * unknown/absent plane           → `%Masked{}` (fail-safe default).
  defp resolve_bag_value(value, key, plane, record, resource, reveal_action, actor, opts) do
    cond do
      Keyword.get(opts, :egress, false) ->
        bag_mask(key)

      plane == :tenant ->
        value

      plane == :operator ->
        if operator_granted?(record, key, resource, reveal_action, actor, opts),
          do: value,
          else: bag_mask(key)

      true ->
        bag_mask(key)
    end
  end

  # A masked bag value: a `%Masked{}` with NO token (a bag key is not vault-routed —
  # there is nothing to reveal). It stringifies / JSON-encodes to `••••` everywhere
  # (`Samen.Masked`), so no serialization path (DOM/CSV/JSON:API/export) can emit the
  # plaintext or a `vt_*` token. The label carries the (tenant-defined) key STRING —
  # never minted to an atom.
  defp bag_mask(key), do: %Masked{token: nil, label: to_string(key)}

  # The record's org id as a canonical string, or nil when it is absent or NOT loaded
  # (a bag key can only be resolved against its org's catalog; every framework read
  # surface loads `org_id`, so this is nil only for an unloaded ad-hoc record).
  defp org_id_of(record), do: normalize_org(Map.get(record, :org_id))

  # The acting scope's org (the tenant boundary), reliably carried on the actor map
  # for both the tenant and operator/impersonation planes (`Samen.Web.Plane.scope/2`).
  defp actor_org_id(actor) when is_map(actor), do: normalize_org(Map.get(actor, :org_id))
  defp actor_org_id(_), do: nil

  defp normalize_org(nil), do: nil
  defp normalize_org(%Ash.NotLoaded{}), do: nil
  defp normalize_org(value), do: to_string(value)
end

defmodule Samen.Analytics do
  @moduledoc """
  The **product-analytics capture API** (WS-B / G12; ADR-021).

  `track/1` is the ONE way a `pae` (`Analytics.ProductEvent`) row is written. It is
  the capture boundary where PII is REFUSED by construction — a payload carrying a
  freeform string, a vault-routed value, an email/phone/SSN/name-shaped value, or an
  unregistered event name / prop key is DROPPED (logged `:pii_rejected` /
  `:unregistered_*`), never persisted (ADR-021 §5 RP-A1). It is best-effort: it
  rides alongside the primary write like `Samen.Notifications.Engine.emit/2` and
  NEVER raises into the caller (a track failure never fails the action that fired it).

  ## The capture request

      Samen.Analytics.track(%{
        org_id: org_id,                 # bounded id — the tenant (required)
        event_name: "record.created",   # a REGISTERED Catalog name (required)
        subject_id: user_id,            # optional — pseudonymized to pae_actor_ref
        entity_ref: record_id,          # optional — a bounded id/token
        props: %{"resource" => "crm.contact"},  # bounded, catalog-schema-validated
        occurred_at: DateTime.utc_now() # optional (defaults to now)
      })

  Returns `{:ok, pae}` on capture, `{:ok, :dropped}` when the framework emitter is
  unwired (no `pae` resource configured), or `{:error, reason}` when the payload is
  REFUSED — always a non-raising result the caller can ignore.

  ## The four refusal gates (default-deny at every layer)

    1. **Unregistered event name** — `event_name` must be in `Samen.Analytics.Catalog`
       (a bounded enum, never freeform). An unknown name is refused
       (`{:error, :unregistered_event}`).
    2. **Unregistered prop key** — every `props` KEY must be in the event's catalog
       key schema. A freeform key (`"note"`, `"comment"`) is refused
       (`{:error, {:unregistered_prop_key, key}}`) — the mask-unknown-by-default
       discipline applied to the prop schema (design §4.2).
    3. **PII-shaped prop value** — every `props` VALUE is classified against the
       shared `Samen.Pii` oracle: a value whose TYPE is PII (a non-scalar / freeform
       type) OR whose SHAPE is PII (an email/phone/SSN/space-separated name via
       `Samen.PiiValueShape`) OR that carries a `vt_*` vault token is refused
       (`{:error, :pii_rejected}`, logged). This is the exact H-2/A1 default-deny
       discipline at the capture boundary (ADR-021 §5).
    4. **PII-shaped entity_ref** — the same value gate applied to `entity_ref`, with
       REFUSAL SYMMETRY (B9 carry B7-P2-1): a PII-shaped / vault-token / structured
       `entity_ref` refuses the WHOLE event (`{:error, :pii_rejected}`), never a
       silent scrub-to-nil — fail-closed, like every other gate.

  ## `pae_actor_ref` — a per-subject HMAC pseudonym, never a raw id

  When a `:subject_id` is supplied, `track/1` derives `actor_ref` via
  `Samen.WideEvent.for_subject/2` — `HMAC(psk_S, subject_id)`, a one-way handle
  keyed on the subject's own KMS DEK. It is NOT a raw user id and NOT PII. After the
  subject is shredded the pseudonym is unreconstructable (`for_subject` returns
  `:shredded`) and `actor_ref` is simply omitted — the row still records the
  org-scoped fact, it just loses the actor linkage (erasure for free; AC-G12-5).

  ## The framework wiring seam

  `track/1` resolves the `pae` resource from config:

      config :samen_core, Samen.Analytics, product_event_resource: Demo.Analytics.ProductEvent

  Absent config, `track/1` is INERT (`{:ok, :dropped}`) — sources are quiet until the
  host mounts the Analytics scope, by design (the notifications-engine posture). This
  is also the `config :samen_core, Samen.FeatureFlags, emit: {Samen.Analytics, :track}`
  target: every flag-variant assignment flows here at zero call-site changes.
  """

  require Logger

  alias Samen.Analytics.Catalog

  @kind_by_event %{
    "session.signed_in" => :session,
    "first_run.completed" => :onboarding,
    "record.created" => :record,
    "search.used" => :search,
    "flag.assignment" => :experiment
  }

  @doc """
  Capture a product event → a `pae` row. Best-effort; never raises.

  See the module doc for the request shape, the three refusal gates, and the
  `pae_actor_ref` pseudonymization. Returns `{:ok, pae}` | `{:ok, :dropped}` |
  `{:error, reason}`.
  """
  @spec track(map()) ::
          {:ok, struct()} | {:ok, :dropped} | {:error, term()}
  def track(request) when is_map(request) do
    with {:ok, org_id} <- fetch_org_id(request),
         {:ok, name} <- fetch_event_name(request),
         {:ok, allowed_keys} <- Catalog.allowed_keys(name),
         {:ok, props} <- validate_props(props_of(request, allowed_keys), allowed_keys),
         {:ok, entity_ref} <- validate_entity_ref(request) do
      write(org_id, name, props, entity_ref, request)
    end
  rescue
    # Best-effort belt: capture NEVER raises into the caller (the primary write is
    # load-bearing; the pae row rides alongside, like Engine.emit/2).
    e ->
      Logger.warning("[Analytics] track/1 raised, dropping event: #{Exception.message(e)}")
      {:error, {:track_raised, Exception.message(e)}}
  catch
    kind, reason ->
      Logger.warning("[Analytics] track/1 caught #{inspect(kind)}, dropping event")
      {:error, {:track_caught, reason}}
  end

  def track(_other), do: {:error, :invalid_request}

  # ---------------------------------------------------------------------------
  # Gate 0 — org + event name.
  # ---------------------------------------------------------------------------

  defp fetch_org_id(request) do
    case Map.get(request, :org_id) do
      org_id when is_binary(org_id) and org_id != "" -> {:ok, org_id}
      %{} = _ -> {:error, :missing_org_id}
      org_id when not is_nil(org_id) -> {:ok, to_string(org_id)}
      _ -> {:error, :missing_org_id}
    end
  end

  # The event name arrives as a string ("record.created") or an atom (:"record.created").
  # It MUST be a registered Catalog name (a bounded enum) — an unregistered name is
  # refused (Gate 1). Normalized to the atom the resource enum constraint expects.
  defp fetch_event_name(request) do
    raw =
      case Map.get(request, :event_name) || Map.get(request, :event) do
        v when is_binary(v) -> v
        v when is_atom(v) and not is_nil(v) -> Atom.to_string(v)
        _ -> nil
      end

    cond do
      is_nil(raw) -> {:error, :missing_event_name}
      Catalog.registered?(raw) -> {:ok, raw}
      true -> {:error, :unregistered_event}
    end
  end

  # ---------------------------------------------------------------------------
  # Gate 2 + 3 — prop keys (bounded catalog schema) + prop values (PII refusal).
  # ---------------------------------------------------------------------------

  defp validate_props(props, allowed_keys) when is_map(props) do
    Enum.reduce_while(props, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key_str = to_string(key)

      cond do
        # Gate 2 — default-deny an unregistered prop key (no freeform keys).
        not MapSet.member?(allowed_keys, key_str) ->
          {:halt, {:error, {:unregistered_prop_key, key_str}}}

        # Gate 3 — refuse a PII-classified / PII-shaped / vault-token value.
        pii_value?(value) ->
          Logger.warning(
            "[Analytics] track/1 refused a PII-shaped value for prop #{inspect(key_str)} " <>
              "(:pii_rejected) — dropped, never persisted (ADR-021 RP-A1)."
          )

          {:halt, {:error, :pii_rejected}}

        true ->
          {:cont, {:ok, Map.put(acc, key_str, value)}}
      end
    end)
  end

  defp validate_props(_not_a_map, _allowed), do: {:error, :props_not_a_map}

  # Resolve the props to validate. An explicit `:props` map is authoritative (used
  # by the framework Sources). Absent that, FOLD the top-level request keys that
  # match the event's catalog schema into props — so a FLAT payload (the
  # `Samen.FeatureFlags.assignment_payload/3` shape `%{event:, flag_name:, variant:,
  # org_id:}`) carries `flag_name`/`variant` into `pae_props` at zero call-site
  # change. Reserved request keys (org/event/subject/entity/occurred_at) never fold.
  @reserved_request_keys ~w(org_id event_name event subject_id entity_ref occurred_at props)a

  defp props_of(request, allowed_keys) do
    case Map.get(request, :props) do
      %{} = props ->
        props

      _ ->
        request
        |> Enum.reject(fn {k, _v} -> k in @reserved_request_keys end)
        |> Enum.filter(fn {k, _v} -> MapSet.member?(allowed_keys, to_string(k)) end)
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
    end
  end

  # A value is PII-refused if ANY of:
  #   * its TYPE is freeform/unknown → the Pii oracle calls it :pii (default-deny);
  #   * it is a string whose SHAPE is PII (email/phone/SSN/space-separated name);
  #   * it carries a vault token (vt_* — a laundered vaulted value must not ride here);
  #   * it is a nested map/list (a freeform structure the schema can't bound).
  # Bounded scalars (bool/int/float/atom/uuid-shaped string/timestamp) pass.
  defp pii_value?(value) when is_binary(value) do
    vault_token?(value) or Samen.PiiValueShape.pii_shaped_id?(value)
  end

  defp pii_value?(value) when is_boolean(value), do: false
  defp pii_value?(value) when is_number(value), do: false
  defp pii_value?(value) when is_atom(value), do: pii_shaped_atom?(value)
  defp pii_value?(%DateTime{}), do: false
  defp pii_value?(%NaiveDateTime{}), do: false
  defp pii_value?(%Date{}), do: false
  defp pii_value?(%Time{}), do: false
  # A nested map or list is a freeform structure the bounded prop schema cannot
  # validate — default-deny it (mask-unknown-by-default at the value layer).
  defp pii_value?(_other), do: true

  # A vt_* vault token (or any hex-ish token shape the vault emits). We refuse it
  # OUTRIGHT: a vaulted value laundered into props would let PII ride token-shaped.
  defp vault_token?(value) do
    String.starts_with?(value, "vt_")
  end

  defp pii_shaped_atom?(value) when is_atom(value) and value not in [nil, true, false] do
    Samen.PiiValueShape.pii_shaped_id?(Atom.to_string(value))
  end

  defp pii_shaped_atom?(_), do: false

  # ---------------------------------------------------------------------------
  # The write — best-effort, authorize?: false framework emit (the mov/Engine posture).
  # ---------------------------------------------------------------------------

  defp write(org_id, name, props, entity_ref, request) do
    case product_event_resource() do
      nil ->
        # Unwired — inert until the host mounts the Analytics scope (by design).
        Logger.debug(
          "[Analytics] event #{inspect(name)} not captured: no pae resource wired " <>
            "(config :samen_core, Samen.Analytics, product_event_resource: ...)."
        )

        {:ok, :dropped}

      resource ->
        resource
        |> Ash.Changeset.for_create(:append, %{
          org_id: org_id,
          event_name: String.to_existing_atom(name),
          event_kind: Map.get(@kind_by_event, name),
          actor_ref: actor_ref(request),
          entity_ref: entity_ref,
          props: props,
          occurred_at: occurred_at(request)
        })
        |> Ash.create(authorize?: false)
    end
  rescue
    e ->
      Logger.warning("[Analytics] track/1 write raised, dropping: #{Exception.message(e)}")
      {:error, {:write_raised, Exception.message(e)}}
  end

  # A per-subject HMAC pseudonym via WideEvent.for_subject/2 — NOT a raw id, NOT PII.
  # Absent subject or a shredded subject → nil (the row still records the org fact;
  # it loses only the actor linkage — erasure for free).
  defp actor_ref(request) do
    case Map.get(request, :subject_id) do
      subject_id when is_binary(subject_id) and subject_id != "" ->
        case Samen.WideEvent.for_subject(subject_id) do
          {:ok, pseudonym} -> pseudonym
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # Gate 4 — the entity_ref refusal (REFUSAL SYMMETRY with the prop-value gate;
  # B9 carry B7-P2-1, fail-closed per the design ethos). An entity_ref is an opaque
  # bounded id/token, never a name/email/vault token: a PII-shaped or vt_* value
  # REFUSES the WHOLE event ({:error, :pii_rejected}, logged) — never a silent
  # scrub-to-nil that persists the rest of the row. Non-binary scalars (atom/number)
  # are stringified FIRST and pass the same shape gate; a structured value
  # (map/list — a shape the bounded column cannot hold honestly) is refused outright.
  defp validate_entity_ref(request) do
    case Map.get(request, :entity_ref) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      ref when is_binary(ref) or is_atom(ref) or is_number(ref) ->
        ref = to_string(ref)

        if Samen.PiiValueShape.pii_shaped_id?(ref) or vault_token?(ref) do
          Logger.warning(
            "[Analytics] track/1 refused a PII-shaped entity_ref (:pii_rejected) — the " <>
              "WHOLE event is dropped, never persisted (refusal symmetry, ADR-021 §5 / B7-P2-1)."
          )

          {:error, :pii_rejected}
        else
          {:ok, ref}
        end

      _structured ->
        Logger.warning(
          "[Analytics] track/1 refused a structured entity_ref (:pii_rejected) — an " <>
            "entity_ref is an opaque bounded scalar handle (ADR-021 §5 / B7-P2-1)."
        )

        {:error, :pii_rejected}
    end
  end

  defp occurred_at(request) do
    case Map.get(request, :occurred_at) do
      %DateTime{} = dt -> DateTime.truncate(dt, :second)
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  @doc false
  def product_event_resource do
    case Application.get_env(:samen_core, __MODULE__) do
      opts when is_list(opts) -> Keyword.get(opts, :product_event_resource)
      _ -> nil
    end
  end
end

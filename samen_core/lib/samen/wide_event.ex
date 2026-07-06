defmodule Samen.WideEvent do
  @moduledoc """
  One canonical **wide event** per request/action (doc §runs 4b).

  > "Each request emits one wide, canonical event carrying the fields you debug
  > on — request_id, trace_id, tenant_id, actor_id, action, row-count,
  > query-operation/timing summary, queue depth — shipped to a trace/event
  > backend (OpenTelemetry → Honeycomb/Tempo/Loki) where you slice by any of
  > them."

  ## Two defences, one struct — the SCHEMA is load-bearing, the runtime is a belt

    1. **Build-time (static) — the load-bearing J2 defence.**
       `Samen.WideEvent.Schema` declares every field with a bounded type
       (`:opaque_id | :token | :enum | :number`); `mix samen.verify.sink_schema`
       (J2, demo/ci.sh) **fails the build on any free-string/untyped field**. This
       is the real guarantee: there is *no free-string field* for a laundered PII
       value to land in. This is what the vision doc stakes and it is enforced.

    2. **Runtime (dynamic) — a value-SHAPE heuristic, NOT a taint proof.**
       `new/1` validates every supplied value against its declared field type and
       REJECTS an unknown field, a wrong-typed value, or a value whose *shape* is
       obviously PII — a space-separated name, an email, a phone, or an SSN stuffed
       into a bounded `:opaque_id`/`:token` field, and a PII/name-shaped atom in an
       open `:enum` (`:action`). It reuses the C4 `Samen.PiiValueShape` heuristics.

       **Honesty note:** this runtime check is a *shape heuristic*, not a proof of
       non-PII. It catches the obvious "a host typed a PII literal into tenant_id"
       mistake, but a single-token opaque value that happens to be a real surname
       is indistinguishable from a legitimate token by shape alone. Do not
       over-trust it: the **schema-level no-free-string-field defence (1) is the
       load-bearing J2 guarantee**; this heuristic is a belt on top of it.

  ## `actor_id` is a per-subject-keyed pseudonym

  `actor_id = HMAC(psk_S, subject_id)` where `psk_S = HKDF(DEK_S, "samen/obs-pseudonym/v1")`
  (ADR-001 §2 RQ5). It rides the subject's own KMS-held DEK, so destroying that
  key on erasure makes the pseudonym **promptly unlinkable** — a one-way handle
  whose key is gone (doc §runs 4b; the trace sink is ingress-class, not
  destruction-class). Use `for_subject/2` to build the actor_id from a subject id
  via the configured `Samen.Kms` adapter; after shred it returns `:shredded` and
  the field is omitted (the event still emits — the sink just loses the linkage).

  ## Emit path

  `emit/2` runs the event through the runtime schema validation, then
  `:telemetry.execute([:samen, :wide_event], measurements, metadata)` — the sink
  adapters attach as telemetry handlers. There is exactly ONE canonical event per
  request; the caller assembles it as the request unwinds.
  """

  alias Samen.WideEvent.Schema

  @telemetry_event [:samen, :wide_event]

  @enforce_keys [:action]
  defstruct request_id: nil,
            trace_id: nil,
            span_id: nil,
            tenant_id: nil,
            actor_id: nil,
            action: nil,
            op: nil,
            table: nil,
            row_count: nil,
            duration_ms: nil,
            queue_depth: nil

  @type t :: %__MODULE__{
          request_id: String.t() | nil,
          trace_id: String.t() | nil,
          span_id: String.t() | nil,
          tenant_id: String.t() | nil,
          actor_id: String.t() | nil,
          action: atom(),
          op: atom() | nil,
          table: String.t() | nil,
          row_count: non_neg_integer() | nil,
          duration_ms: number() | nil,
          queue_depth: non_neg_integer() | nil
        }

  @doc "The telemetry event name the sink adapters attach to."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc """
  Build a validated wide event from a keyword/map of fields.

  Returns `{:ok, %Samen.WideEvent{}}` or `{:error, reasons}` where `reasons` is a
  list of human strings. Validation is the **runtime** half of the J2 defence — a
  value-shape belt, not a taint proof (the schema type is the load-bearing gate):

    * an **unknown field** (not in `Schema.field_names/0`) is rejected — you
      cannot smuggle an undeclared field past the runtime;
    * every supplied value must fit its **declared bounded type** — a value in a
      `:number` field must be a number; a `:enum` value must be in the closed set;
    * a bounded `:opaque_id`/`:token` value that is *obviously* PII-shaped (a
      space-separated name, an email, a phone, an SSN) is rejected, and a
      PII/name-shaped atom in an open `:enum` is rejected. This is a heuristic:
      it catches the obvious literal, not every possible PII value.

  `nil` values are permitted (a field may be absent for a given request).
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, [String.t()]}
  def new(fields) do
    fields = Map.new(fields)

    with :ok <- reject_unknown_fields(fields),
         :ok <- ensure_action(fields),
         :ok <- validate_values(fields) do
      {:ok, struct(__MODULE__, fields)}
    end
  end

  @doc "Like `new/1` but raises on invalid input (for call sites that treat a bad event as a bug)."
  @spec new!(keyword() | map()) :: t()
  def new!(fields) do
    case new(fields) do
      {:ok, ev} -> ev
      {:error, reasons} -> raise ArgumentError, "invalid wide event: #{Enum.join(reasons, "; ")}"
    end
  end

  @doc """
  Compute `actor_id` for a subject via the configured `Samen.Kms` adapter.

  `HMAC(psk_S, subject_id)` — a per-subject-keyed pseudonym. Returns
  `{:ok, actor_id}` while the subject's DEK lives, or `{:error, :shredded}` after
  the key is destroyed (the pseudonym is then unreconstructable — the unlink is
  the guarantee, not a bug).

  `subject_id` is the actor's own subject id (the pseudonym is keyed on and of the
  same subject — a self-pseudonym handle for the trace sink).
  """
  @spec for_subject(String.t(), module()) :: {:ok, String.t()} | {:error, term()}
  def for_subject(subject_id, kms \\ Samen.Kms.adapter()) when is_binary(subject_id) do
    case kms.pseudonym(subject_id, subject_id) do
      {:ok, actor_id} -> {:ok, actor_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Emit the canonical wide event via `:telemetry.execute/3`.

  Re-validates the struct against the schema (defence in depth), then splits it
  into `measurements` (the numeric fields) and `metadata` (the bounded IDs /
  tokens / enums) and executes the telemetry event the sinks listen on.

  Returns `:ok`, or `{:error, reasons}` if the struct is somehow invalid (a raw
  `%WideEvent{}` built by `struct/2` bypassing `new/1`).
  """
  @spec emit(t()) :: :ok | {:error, [String.t()]}
  def emit(%__MODULE__{} = ev) do
    fields = ev |> Map.from_struct() |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

    with :ok <- reject_unknown_fields(fields),
         :ok <- ensure_action(fields),
         :ok <- validate_values(fields) do
      {measurements, metadata} = split(ev)
      :telemetry.execute(@telemetry_event, measurements, metadata)
      :ok
    end
  end

  @doc "Convenience: build + emit in one call. Returns `:ok` or `{:error, reasons}`."
  @spec emit(keyword() | map(), :build) :: :ok | {:error, [String.t()]}
  def emit(fields, :build) do
    case new(fields) do
      {:ok, ev} -> emit(ev)
      {:error, reasons} -> {:error, reasons}
    end
  end

  # ---------------------------------------------------------------------------

  @number_fields [:row_count, :duration_ms, :queue_depth]

  defp split(%__MODULE__{} = ev) do
    map = Map.from_struct(ev)
    measurements = map |> Map.take(@number_fields) |> reject_nils()
    metadata = map |> Map.drop(@number_fields) |> reject_nils()
    {measurements, metadata}
  end

  defp reject_nils(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp reject_unknown_fields(fields) do
    allowed = Schema.field_names()

    case Enum.reject(Map.keys(fields), &MapSet.member?(allowed, &1)) do
      [] ->
        :ok

      unknown ->
        {:error,
         Enum.map(unknown, fn f ->
           "unknown wide-event field #{inspect(f)} — not in the declared schema " <>
             "(#{inspect(MapSet.to_list(allowed))}). Add it to Samen.WideEvent.Schema " <>
             "with a bounded type first (J2)."
         end)}
    end
  end

  defp ensure_action(%{action: action}) when is_atom(action) and not is_nil(action), do: :ok

  defp ensure_action(_),
    do: {:error, ["wide event requires an :action (a bounded enum atom)"]}

  defp validate_values(fields) do
    reasons =
      Enum.flat_map(fields, fn {name, value} ->
        if is_nil(value) do
          []
        else
          {:ok, {^name, type, opts}} = Schema.fetch(name)
          value_violation(name, type, opts, value)
        end
      end)

    if reasons == [], do: :ok, else: {:error, reasons}
  end

  # :opaque_id — a bounded, printable identifier (uuid/ulid-shaped). We accept a
  # binary that is bounded in length and free of whitespace/PII shape. It is NOT a
  # free-form string field: an id has no spaces and is length-capped.
  defp value_violation(name, :opaque_id, _opts, value) do
    if is_binary(value) and bounded_id_shape?(value) do
      []
    else
      ["#{inspect(name)} (:opaque_id) must be a bounded, whitespace-free identifier — got #{inspect(value)}"]
    end
  end

  # :token — a vault token or a per-subject pseudonym (hex/`vt_` shaped). Same
  # bounded, whitespace-free shape as an id; the point is it is opaque, not text.
  defp value_violation(name, :token, _opts, value) do
    if is_binary(value) and bounded_id_shape?(value) do
      []
    else
      ["#{inspect(name)} (:token) must be an opaque token/pseudonym — got #{inspect(value)}"]
    end
  end

  # :number — an integer or float measurement.
  defp value_violation(name, :number, _opts, value) do
    if is_number(value),
      do: [],
      else: ["#{inspect(name)} (:number) must be a number — got #{inspect(value)}"]
  end

  # :enum — a value drawn from the declared closed set, or (for :action) any atom
  # since :action's closed set is app-defined; but it MUST be an atom (never a
  # free binary), so a laundered name can't sit in an enum field either. For an
  # OPEN enum (`:action`) we additionally reject an atom whose printable form is
  # name/email/phone/SSN-shaped — an atom-ized PII value (`:"alice@example.com"`,
  # `:"Alice Anders"`) is not a legitimate action label.
  defp value_violation(name, :enum, opts, value) do
    case Keyword.get(opts, :allowed) do
      :open ->
        cond do
          not is_atom(value) ->
            ["#{inspect(name)} (:enum) must be an atom label — got #{inspect(value)}"]

          pii_shaped_atom?(value) ->
            ["#{inspect(name)} (:enum) atom label #{inspect(value)} is PII/name-shaped — " <>
               "an :action is a bounded label, not a value carrier (J2 runtime guard)"]

          true ->
            []
        end

      allowed when is_list(allowed) ->
        if value in allowed,
          do: [],
          else: ["#{inspect(name)} (:enum) value #{inspect(value)} not in closed set #{inspect(allowed)}"]

      _ ->
        ["#{inspect(name)} (:enum) has no declared allowed set (schema bug)"]
    end
  end

  # A bounded id/token shape: a binary, length-capped, with no internal
  # whitespace/space-separated words (a name has spaces; a uuid/token doesn't),
  # AND not an email/phone/SSN-shaped literal (a single-token PII value stuffed
  # into an opaque-ID field). This is a **value-shape heuristic, not a taint
  # proof** — the schema type (no free-string field, `mix samen.verify.sink_schema`)
  # is the load-bearing J2 gate. This heuristic is a belt that rejects the obvious
  # "a host typed a PII literal into tenant_id/actor_id" mistake; it reuses the C4
  # `Samen.PiiValueShape` heuristics (Gate-2 F2.2) rather than re-deriving them.
  @max_id_len 256
  defp bounded_id_shape?(value) do
    byte_size(value) <= @max_id_len and
      not String.contains?(value, [" ", "\t", "\n"]) and
      not Samen.PiiValueShape.pii_shaped_id?(value)
  end

  # An atom is PII/name-shaped if its printable form matches the ID value-shape
  # heuristic (email/phone/SSN/space-separated name). `Atom.to_string/1` recovers
  # the printable form so an atom-ized name/email is caught in an open `:enum`.
  defp pii_shaped_atom?(value) when is_atom(value) and value not in [nil, true, false] do
    Samen.PiiValueShape.pii_shaped_id?(Atom.to_string(value))
  end

  defp pii_shaped_atom?(_), do: false
end

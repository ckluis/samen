defmodule Samen.Observability.RevealSpanTest do
  @moduledoc """
  ADR-052 §2.1 (P1 item 2) — red path **R3**: the reveal chokepoint (`Samen.Reveal.reveal/5`,
  the single grant-gated path to `Samen.Vault.reveal/3`) runs inside exactly ONE
  `Samen.Tracer.with_reveal_span/3`, whose attributes are the three allow-listed keys and
  never the plaintext.

    * GRANTED reveal → one `samen.reveal` span; attribute keys ⊆ {subject_id, grant_id,
      reason}; the plaintext appears in no attribute and not in the status.
    * DENIED reveal → still one span (a denial is visible in the trace) with an ERROR status
      whose message is the bounded refusal atom, and no plaintext.
    * A disallowed key handed in opts (`:decrypted_value`) and a FREE-TEXT reason never reach
      the span.

  Spans are captured with the SDK's built-in pid exporter (`docs/observability-guide.md` §3).
  """
  use ExUnit.Case, async: false

  require Record

  Record.defrecord(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  alias Samen.Masked
  alias Samen.Reveal
  alias SamenCore.Support.RevealDomain.RevealPerson

  @plaintext "reveal-span-secret@example.test"
  @masked Masked.new("vt_reveal_span_token", :emails)

  defmodule ApproveAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: true
  end

  defmodule DenyAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: false
  end

  defmodule OkVault do
    def reveal(_masked, _repo, _opts \\ []), do: {:ok, "reveal-span-secret@example.test"}
  end

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    on_exit(fn -> :otel_simple_processor.set_exporter(:otel_exporter_pid, :undefined) end)
    :ok
  end

  defp reveal_spans do
    collect([])
    |> Enum.filter(&(span(&1, :name) == Reveal.span_name()))
  end

  defp collect(acc) do
    receive do
      {:span, s} -> collect([s | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp attrs(s), do: s |> span(:attributes) |> :otel_attributes.map()

  defp status_message(s) do
    case span(s, :status) do
      {:status, _code, message} -> message
      _ -> ""
    end
  end

  test "R3 GREEN: a granted reveal runs inside exactly ONE allow-listed reveal span" do
    subject = Ecto.UUID.generate()

    assert {:ok, @plaintext} =
             Reveal.reveal("operator-1", @masked, :reveal_email, RevealPerson,
               repo: :unused,
               vault: OkVault,
               grant: ApproveAll,
               subject_id: subject,
               grant_id: "grant-123",
               reason: :support_ticket,
               decrypted_value: @plaintext
             )

    assert [s] = reveal_spans(), "expected exactly one reveal span"

    a = attrs(s)
    assert Map.keys(a) |> Enum.all?(&(&1 in Samen.Tracer.reveal_allowed_attrs()))
    assert a[:subject_id] == subject
    assert a[:grant_id] == "grant-123"
    assert a[:reason] == "support_ticket"

    refute inspect(a) =~ @plaintext
    refute status_message(s) =~ @plaintext
  end

  test "R3 RED: a DENIED reveal is also exactly one span, ERROR status, no plaintext" do
    assert {:error, :denied} =
             Reveal.reveal("operator-1", @masked, :reveal_email, RevealPerson,
               repo: :unused,
               vault: OkVault,
               grant: DenyAll,
               subject_id: Ecto.UUID.generate()
             )

    assert [s] = reveal_spans()
    assert {:status, :error, "denied"} = span(s, :status)
    refute inspect(attrs(s)) =~ @plaintext
  end

  test "R3 RED: a non-reveal action is refused inside the span too (bounded refusal label)" do
    assert {:error, :not_reveal_action} =
             Reveal.reveal("operator-1", @masked, :read, RevealPerson,
               repo: :unused,
               vault: OkVault,
               grant: ApproveAll
             )

    assert [s] = reveal_spans()
    assert {:status, :error, "not_reveal_action"} = span(s, :status)
  end

  test "a FREE-TEXT reason never reaches the span (only a bounded atom code does)" do
    {:ok, _} =
      Reveal.reveal("operator-1", @masked, :reveal_email, RevealPerson,
        repo: :unused,
        vault: OkVault,
        grant: ApproveAll,
        reason: "calling Alice Anders back"
      )

    assert [s] = reveal_spans()
    refute Map.has_key?(attrs(s), :reason)
    refute inspect(attrs(s)) =~ "Alice"
  end
end

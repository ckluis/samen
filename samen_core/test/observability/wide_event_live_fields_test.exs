defmodule Samen.WideEvent.LiveFieldsTest do
  @moduledoc """
  ADR-052 §2.1 — red path **R1**: the wide-event schema still refuses a free-string field,
  INCLUDING the new LiveView/request fields (`view`, `callback`, `event`, `outcome`, `method`,
  `status`). The J2 build check (`mix samen.verify.sink_schema`, the `:trace_sink` tier) reads
  the same `Samen.WideEvent.Schema.violations/1`.

  Each denial pairs with a positive control: the real schema is clean, and the real types are
  pinned so retyping a LiveView field to `:string` fails here.
  """
  use ExUnit.Case, async: true

  alias Samen.WideEvent
  alias Samen.WideEvent.Schema

  @live_fields [
    view: :opaque_id,
    callback: :enum,
    event: :enum,
    outcome: :enum,
    method: :enum,
    status: :number
  ]

  test "POSITIVE CONTROL: the real schema (with the LiveView fields) has no J2 violation" do
    assert Schema.violations() == []
  end

  test "R1: every LiveView/request field is declared with its bounded type" do
    for {name, type} <- @live_fields do
      assert {:ok, {^name, ^type, _opts}} = Schema.fetch(name),
             "#{inspect(name)} must be declared as #{inspect(type)}"

      assert Schema.bounded_type?(type)
    end
  end

  test "R1: retyping ANY LiveView field to :string is a FORBIDDEN-type violation" do
    for {name, _type} <- @live_fields do
      seeded =
        Enum.map(Schema.canonical_fields(), fn
          {^name, _t, _o} -> {name, :string, []}
          spec -> spec
        end)

      assert [msg] = Schema.violations(seeded)
      assert msg =~ inspect(name)
      assert msg =~ "FORBIDDEN"
    end
  end

  test "R1: the reserved :open enum sentinel is refused outside :action / :event" do
    assert Schema.open_enum_fields() == [:action, :event]

    seeded =
      Enum.map(Schema.canonical_fields(), fn
        {:callback, :enum, _} -> {:callback, :enum, [allowed: :open]}
        spec -> spec
      end)

    assert [msg] = Schema.violations(seeded)
    assert msg =~ ":callback"
    assert msg =~ "reserved"
  end

  test "runtime: a binary event / an out-of-set callback never builds a wide event" do
    assert {:error, _} = WideEvent.new(action: :live_view, event: "save")
    assert {:error, _} = WideEvent.new(action: :live_view, callback: :render)
    assert {:error, _} = WideEvent.new(action: :live_view, view: "Alice Anders")
    assert {:error, _} = WideEvent.new(action: :live_view, status: "200")

    # Positive control: bounded values build.
    assert {:ok, %WideEvent{event: :save, callback: :handle_event, status: 200}} =
             WideEvent.new(
               action: :live_view,
               event: :save,
               callback: :handle_event,
               view: "MyAppWeb.ContactLive",
               status: 200
             )
  end

  test "status is a measurement (a :number field), not metadata" do
    assert :status in Schema.number_fields()
    assert :event in Schema.enum_fields()
  end
end

defmodule Samen.Replay.FrameSchemaTest do
  @moduledoc """
  ADR-052 §2.2 rule 3 — the replay frame schema: a declared, bounded schema, a build-time check
  (`mix samen.verify.replay_schema`, the `sink_schema` twin) that fails on a free-string field,
  and the persist-time validator that refuses a frame carrying a bare string anywhere.
  """
  use ExUnit.Case, async: true

  alias Samen.Replay.{FrameSchema, Id, Kept, Redacted, Ref, Sanitizer}

  @project_dir File.cwd!()

  describe "build-time check" do
    test "the real schema is clean" do
      assert FrameSchema.violations() == []
    end

    test "RED: a :string payload field is a violation (the name-carrier)" do
      seeded = FrameSchema.all_fields() ++ [{"payload render", {:typed_name, :string, []}}]
      assert [msg] = FrameSchema.violations(seeded)
      assert msg =~ "typed_name"
      assert msg =~ "FORBIDDEN"
    end

    test "RED: an open enum outside the reserved fields, a closed enum with no set, an unbounded keep_listed" do
      assert [_] = FrameSchema.violations([{"x", {:status, :enum, [allowed: :open]}}])
      assert [_] = FrameSchema.violations([{"x", {:status, :enum, []}}])
      assert [_] = FrameSchema.violations([{"x", {:title, :keep_listed, []}}])
      assert [_] = FrameSchema.violations([{"x", {:title, :keep_listed, [max_length: 10_000]}}])
      assert [] = FrameSchema.violations([{"x", {:title, :keep_listed, [max_length: 50]}}])
    end

    test "every forbidden type name fails" do
      for type <- FrameSchema.known_forbidden_types() do
        assert [_] = FrameSchema.violations([{"x", {:f, type, []}}]), "#{type} passed"
      end
    end
  end

  describe "persist-time validation" do
    defp frame(kind, payload), do: FrameSchema.encode({1, 10, kind, payload})

    test "a sanitized render frame validates" do
      assigns =
        Sanitizer.assigns(
          %{
            page_title: "Contacts",
            note: "Ada Lovelace",
            n: 3,
            d: ~D[2026-01-01],
            dec: Decimal.new("1.50"),
            status: :open,
            rows: [%{id: Ash.UUID.generate(), name: "Ada"}],
            pair: {:ok, 1}
          },
          keep: [:page_title]
        )

      assert :ok = FrameSchema.validate(frame(:render, %{assigns: assigns}))
    end

    test "refs, redactions, shapes and an exit frame validate" do
      ref = %Ref{resource: "My.Person", pk: Ash.UUID.generate(), attribute: :email, label: :email}
      assert :ok = FrameSchema.validate(frame(:render, %{assigns: %{email: ref}}))

      shape = Sanitizer.params(%{"q" => "Ada", "sort" => "name", "x" => %{"y" => 1}}, ["sort"])
      assert :ok = FrameSchema.validate(frame(:event, %{event: "sort", params: shape}))
      assert :ok = FrameSchema.validate(frame(:exit, %{reason: :normal}))

      assert :ok =
               FrameSchema.validate(
                 frame(:mount, %{
                   view: "Samen.Web.CRM.ContactsLive",
                   view_md5: String.duplicate("a", 32),
                   live_action: :index,
                   assigns: %{id: %Id{value: Ash.UUID.generate()}}
                 })
               )
    end

    test "RED: a bare string anywhere in the tree is refused" do
      assert {:error, _} =
               FrameSchema.validate(frame(:render, %{assigns: %{name: "Ada Lovelace"}}))

      assert {:error, _} = FrameSchema.validate(frame(:render, %{assigns: %{rows: [["Ada"]]}}))
    end

    test "RED: a kept or label value that is PII-shaped is refused" do
      assert {:error, _} =
               FrameSchema.validate(
                 frame(:render, %{assigns: %{t: %Kept{value: "ada@example.com"}}})
               )

      assert {:error, _} = FrameSchema.validate(frame(:event, %{event: "ada@example.com"}))

      bad_ref = %Ref{resource: "My.Person", pk: "Ada Lovelace", attribute: :email, label: :email}
      assert {:error, _} = FrameSchema.validate(frame(:render, %{assigns: %{e: bad_ref}}))
    end

    test "RED: an undeclared payload field, kind, or enum value is refused" do
      assert {:error, _} = FrameSchema.validate(frame(:render, %{assigns: %{}, extra: 1}))
      assert {:error, _} = FrameSchema.validate(frame(:exit, %{reason: :exploded}))

      assert {:error, _} =
               FrameSchema.validate(%{seq: 1, at_ms: 1, kind: :telepathy, payload: %{}})

      assert {:error, _} =
               FrameSchema.validate(
                 frame(:render, %{assigns: %{r: %Redacted{kind: :invented, length: 1}}})
               )
    end
  end

  @tag :exit_code
  test "mix samen.verify.replay_schema exits 0 on the real schema" do
    {output, code} =
      System.cmd("mix", ["samen.verify.replay_schema"],
        cd: @project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "OK"
  end

  @tag :exit_code
  test "RED: mix samen.verify.replay_schema exits 1 on a seeded string field" do
    {output, code} =
      System.cmd("mix", ["samen.verify.replay_schema"],
        cd: @project_dir,
        env: [{"MIX_ENV", "test"}, {"SAMEN_REPLAY_SCHEMA_INJECT_STRING_FIELD", "typed_full_name"}],
        stderr_to_stdout: true
      )

    assert code == 1, output
    assert output =~ "typed_full_name"
    assert output =~ "FORBIDDEN"
  end
end

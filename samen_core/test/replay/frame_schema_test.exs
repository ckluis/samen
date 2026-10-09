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

    # ADR-052 §2.4.1 (P3 gate note 3): the validator accepted ANY code-identifier string for
    # `$id`, `$ref.pk` and a shape key, while the sanitizer only ever writes a lowercase UUID /
    # an integer / a server-known key there. A label-shaped name a row chose passed.
    test "RED: identifier fields accept exactly what the sanitizer emits, never a chosen name" do
      name = "Selectsecret#{System.unique_integer([:positive])}"
      uuid = Ash.UUID.generate()

      refused = [
        render: %{assigns: %{"a" => %{"$id" => %{"value" => "Jane.Doe"}}}},
        render: %{assigns: %{"a" => %{"$id" => %{"value" => String.upcase(uuid)}}}},
        render: %{
          assigns: %{
            "a" => %{"$ref" => %{"resource" => "My.Person", "pk" => name, "attribute" => "email"}}
          }
        },
        render: %{
          assigns: %{
            "a" => %{"$record" => %{"resource" => "My.Person", "pk" => name, "fields" => %{}}}
          }
        },
        render: %{
          assigns: %{
            "a" => %{"$ref" => %{"resource" => "jane.doe", "pk" => uuid, "attribute" => "email"}}
          }
        },
        render: %{
          assigns: %{
            "a" => %{
              "$ref" => %{"resource" => "My.Person", "pk" => uuid, "attribute" => "Jane.Doe"}
            }
          }
        },
        render: %{
          assigns: %{"a" => %{"$dropped" => %{"kind" => "struct", "struct" => "jane-doe"}}}
        },
        event: %{event: "sort", params: [%{"key" => name, "type" => "string"}]},
        mount: %{view: "jane_doe", assigns: %{}},
        mount: %{view: "My.View", view_md5: "Jane", assigns: %{}}
      ]

      for {kind, payload} <- refused do
        encoded = %{
          seq: 1,
          at_ms: 1,
          kind: kind,
          payload: Map.new(payload, fn {k, v} -> {Atom.to_string(k), v} end)
        }

        assert {:error, _} = FrameSchema.validate(encoded), "accepted #{inspect(payload)}"
      end

      # Positive control: the same slots holding what the sanitizer writes validate.
      ok = [
        render: %{assigns: %{"a" => %{"$id" => %{"value" => uuid}}}},
        render: %{
          assigns: %{
            "a" => %{
              "$ref" => %{
                "resource" => "My.Person",
                "pk" => uuid,
                "attribute" => "email",
                "label" => "email"
              }
            }
          }
        },
        render: %{
          assigns: %{
            "a" => %{"$record" => %{"resource" => "My.Person", "pk" => 42, "fields" => %{}}}
          }
        },
        event: %{
          event: "sort",
          params: [%{"key" => "field", "type" => "string"}, %{"key" => "$k0"}]
        },
        mount: %{view: "My.View", view_md5: String.duplicate("ab", 16), assigns: %{}}
      ]

      for {kind, payload} <- ok do
        encoded = %{
          seq: 1,
          at_ms: 1,
          kind: kind,
          payload: Map.new(payload, fn {k, v} -> {Atom.to_string(k), v} end)
        }

        assert :ok = FrameSchema.validate(encoded), "refused #{inspect(payload)}"
      end
    end

    test "RED: a tree key is a server-known identifier, never a name a row chose" do
      name = "Janesecret#{System.unique_integer([:positive])}"

      tree = fn key ->
        %{
          seq: 1,
          at_ms: 1,
          kind: :render,
          payload: %{"assigns" => %{"m" => %{key => 1, "page_title" => 2}}}
        }
      end

      assert {:error, _} = FrameSchema.validate(tree.(name))
      refute FrameSchema.tree_key?(name)

      for key <- ["count", Ash.UUID.generate(), "12", "$k3", "$more"] do
        assert :ok = FrameSchema.validate(tree.(key)), "refused #{key}"
      end
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

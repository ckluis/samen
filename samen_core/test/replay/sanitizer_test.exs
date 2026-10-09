defmodule Samen.Replay.SanitizerTest do
  @moduledoc """
  ADR-052 §2.2 rule 1 — the replay sanitizer's decision table, over a REAL vault-routed resource
  (`SamenCore.Support.Clinical.Patient`: vault-routed full_name/emails/phones/dob/mrn, a
  freeform `job_title`, a structural `consent_on_file`) read back and resolved on the TENANT
  plane, so the record the sanitizer sees carries real plaintext — exactly what a tenant
  LiveView holds in its assigns.

  Red paths: R5 (a vault-routed attribute never survives as a value — `Ref` only), R6 (a
  freeform column is shape only — the ADR-015 CDC classifier decides), and the bare-value rules.
  Each denial is paired with a positive control (the input DID carry the plaintext).
  """
  use ExUnit.Case, async: false

  alias Samen.Replay.{Count, Dropped, Id, Kept, More, Record, Redacted, Ref, Sanitizer, Shape}
  alias SamenCore.Support.Clinical.{Patient, Staff}

  @repo SamenCore.TestRepo
  @first "Grace"
  @last "Hopper"
  @mrn "MRN-SECRET-42"
  @title "Rear Admiral"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    :ok
  end

  defp tenant_patient! do
    org = Ash.UUID.generate()

    staff =
      Staff
      |> Ash.Changeset.for_create(:create, %{org_id: org, license_no: "LIC-1"})
      |> Ash.create!()

    p =
      Patient
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        full_name: %{first: @first, last: @last},
        mrn: @mrn,
        dob: ~D[1906-12-09],
        job_title: @title,
        consent_on_file: true,
        primary_provider_id: staff.id
      })
      |> Ash.create!()

    [read] =
      Patient
      |> Ash.Query.filter_input(%{id: p.id})
      |> Ash.Query.select(Patient |> Ash.Resource.Info.attribute_names() |> Enum.to_list())
      |> Ash.Query.load(:primary_provider)
      |> Ash.read!()
      |> Samen.Api.PiiResolution.resolve(Patient, %{plane: :tenant, org_id: org}, repo: @repo)

    read
  end

  describe "R5 — a vault-routed attribute is recorded by reference, never by value" do
    test "a tenant-plane CLEAR record: every vault field is a Ref; no plaintext survives" do
      patient = tenant_patient!()

      # Positive control: the tenant plane really resolved plaintext into the record.
      assert patient.mrn == @mrn
      assert inspect(patient.full_name) =~ @first

      assert %Record{resource: "SamenCore.Support.Clinical.Patient", pk: pk, fields: fields} =
               Sanitizer.value(patient)

      assert pk == patient.id

      for attr <- [:full_name, :emails, :phones, :dob, :mrn] do
        assert %Ref{
                 resource: "SamenCore.Support.Clinical.Patient",
                 pk: ^pk,
                 attribute: ^attr,
                 label: ^attr
               } =
                 fields[attr]
      end

      dump = inspect(Sanitizer.value(patient), limit: :infinity, printable_limit: :infinity)
      for secret <- [@first, @last, @mrn, "1906"], do: refute(dump =~ secret)
    end

    test "an in-flight Samen.Pii.Plaintext and an operator-plane Masked inside a record are Refs too" do
      patient = tenant_patient!()
      in_flight = %{patient | mrn: Samen.Pii.Plaintext.wrap(@mrn)}
      masked = %{patient | mrn: Samen.Masked.new("vt_abc123", :mrn)}

      for rec <- [in_flight, masked] do
        %Record{fields: fields} = Sanitizer.value(rec)
        assert %Ref{attribute: :mrn} = fields.mrn
        dump = inspect(Sanitizer.value(rec), limit: :infinity)
        refute dump =~ @mrn
        refute dump =~ "vt_abc123"
      end
    end

    test "a loaded relationship is walked under the same rules" do
      patient = tenant_patient!()
      %Record{fields: %{primary_provider: provider}} = Sanitizer.value(patient)
      assert %Record{resource: "SamenCore.Support.Clinical.Staff", fields: staff} = provider
      assert %Ref{attribute: :full_name} = staff.full_name
      # license_no is a freeform column → shape only.
      assert %Redacted{kind: :free_text, length: 5} = staff.license_no
    end
  end

  describe "R6 — a freeform column is recorded as shape only (the CDC classifier decides)" do
    test "job_title (freeform string) is Redacted free_text; structural columns are kept" do
      patient = tenant_patient!()
      # Positive control: the value is there to leak.
      assert patient.job_title == @title

      %Record{fields: fields} = Sanitizer.value(patient)
      assert %Redacted{kind: :free_text, length: 12} = fields.job_title
      assert fields.consent_on_file == true
      assert %Id{value: id} = fields.id
      assert id == patient.id
      assert %Id{} = fields.org_id
      refute inspect(fields, limit: :infinity) =~ @title
    end

    test "a two-reviewer non_pii!-cleared freeform column is recorded BY REFERENCE, never by value" do
      patient = tenant_patient!()

      cleared = [
        %{
          table_name: "pat_patient",
          column_name: "pat_job_title",
          cleared_by: "a",
          reviewed_by: "b"
        }
      ]

      # Positive control: the record DOES carry the cleared column's plaintext.
      assert patient.job_title == @title

      # Cleared ⇒ a Ref (the erasure arm overwrites the row on shred; a stored copy would
      # outlive it), never the value.
      %Record{fields: fields} = Sanitizer.value(patient, non_pii_entries: cleared)
      assert %Ref{attribute: :job_title, pk: pk} = fields.job_title
      assert pk == patient.id
      refute inspect(fields, limit: :infinity) =~ @title

      # Default (no injected entries): the sanitizer never queries the DB-backed registry from
      # the LiveView process — no clearance, so the column is shape only.
      %Record{fields: fields} = Sanitizer.value(patient)
      assert %Redacted{kind: :free_text} = fields.job_title

      # A self-reviewed clearance is not a clearance — default-deny holds.
      self_review = [%{hd(cleared) | reviewed_by: "a"}]
      %Record{fields: fields} = Sanitizer.value(patient, non_pii_entries: self_review)
      assert %Redacted{kind: :free_text} = fields.job_title
    end
  end

  describe "bare values" do
    test "bare strings are redacted unless the assign key is keep-listed (and bounded, non-PII)" do
      uuid = Ash.UUID.generate()

      out =
        Sanitizer.assigns(
          %{
            page_title: "Contacts",
            note: "Ada Lovelace",
            tab: "billing",
            email_title: "ada@example.com",
            long_title: String.duplicate("x", 500),
            org_id: uuid,
            raw: <<0xFF, 0xFE>>
          },
          keep: [:page_title, :tab, :email_title, :long_title]
        )

      assert out.page_title == %Kept{value: "Contacts"}
      assert out.tab == %Kept{value: "billing"}
      assert out.note == %Redacted{kind: :string, length: 12}
      # Keep-listed but email-shaped / over-long → still redacted.
      assert %Redacted{kind: :string} = out.email_title
      assert %Redacted{kind: :string, length: 500} = out.long_title
      assert out.org_id == %Id{value: uuid}
      assert %Redacted{kind: :binary, length: 2} = out.raw
    end

    test "a bare Masked keeps its label, never its vt_* token; a bare Plaintext keeps nothing" do
      out =
        Sanitizer.assigns(%{
          m: Samen.Masked.new("vt_tok_123", :email),
          p: Samen.Pii.Plaintext.wrap("ada@example.com")
        })

      assert out.m == %Redacted{kind: :masked, label: :email}
      assert out.p == %Redacted{kind: :vault_plaintext}
      refute inspect(out) =~ "vt_tok"
      refute inspect(out) =~ "ada@"
    end

    test "scope, actor, socket, pid, ref, fun, unknown structs are dropped" do
      out =
        Sanitizer.assigns(%{
          scope: %Samen.Scope{actor: %{id: "x"}},
          samen_tenant_principal: Ash.UUID.generate(),
          viewer: %{id: Ash.UUID.generate(), org_id: Ash.UUID.generate(), plane: :tenant},
          pid: self(),
          ref: make_ref(),
          fun: fn -> :ok end,
          form: URI.parse("https://example.com/?q=ada@example.com"),
          wrapped: %Samen.Scope{actor: nil}
        })

      assert out.scope == %Dropped{kind: :scope}
      assert out.samen_tenant_principal == %Dropped{kind: :actor}
      assert out.viewer == %Dropped{kind: :actor}
      assert out.pid == %Dropped{kind: :pid}
      assert out.ref == %Dropped{kind: :reference}
      assert out.fun == %Dropped{kind: :function}
      assert out.form == %Dropped{kind: :struct, struct: "URI"}
      refute inspect(out) =~ "ada@"
    end

    test "numbers, booleans, dates, decimals and label atoms are kept; odd atoms are not" do
      dt = ~U[2026-10-09 10:00:00Z]

      out =
        Sanitizer.assigns(%{
          n: 42,
          f: 1.5,
          b: false,
          d: ~D[2026-10-09],
          dt: dt,
          dec: Decimal.new("12.30"),
          status: :active,
          odd: :"Ada Lovelace",
          nothing: nil
        })

      assert %{n: 42, f: 1.5, b: false, d: ~D[2026-10-09], dt: ^dt, status: :active, nothing: nil} =
               out

      assert Decimal.equal?(out.dec, Decimal.new("12.30"))
      assert out.odd == %Redacted{kind: :atom}
    end

    test "maps and lists recurse with caps; PII-shaped keys become positional; charlists are text" do
      big = Enum.to_list(1..80)
      deep = Enum.reduce(1..12, :leaf, fn _, acc -> %{n: acc} end)

      out =
        Sanitizer.assigns(%{
          list: big,
          deep: deep,
          keyed: %{"ada@example.com" => 1, "status" => "x"},
          chars: ~c"Ada Lovelace",
          tuple: {:ok, "Ada"}
        })

      assert length(out.list) == 51
      assert List.last(out.list) == %More{n: 30}
      assert inspect(out.deep) =~ "Dropped"
      assert out.keyed["$k0"] == 1
      assert out.keyed["status"] == %Redacted{kind: :string, length: 1}
      refute inspect(out.keyed) =~ "ada@"
      assert out.chars == %Redacted{kind: :charlist, length: 12}
      assert out.tuple == {:ok, %Redacted{kind: :string, length: 3}}
    end

    test "streams and uploads are counts only" do
      out =
        Sanitizer.assigns(%{
          streams: %{
            rows: %{__struct__: Phoenix.LiveView.LiveStream, inserts: [1, 2]},
            __changed__: %{}
          },
          uploads: %{avatar: :cfg}
        })

      assert out.streams == %Count{kind: :streams, n: 1}
      assert out.uploads == %Count{kind: :uploads, n: 1}
    end

    test "only: limits a render to its changed keys" do
      out = Sanitizer.assigns(%{a: 1, b: 2, __changed__: %{a: true}}, only: [:a])
      assert out == %{a: 1}
    end
  end

  describe "never crashes its caller" do
    test "a term the walker cannot handle drops THAT assign only" do
      out = Sanitizer.assigns(%{bad: [?a | :improper], good: 1})
      assert out.bad == %Dropped{kind: :sanitizer_error}
      assert out.good == 1
    end

    test "a pathological assign is cut by the node budget, not walked forever" do
      huge = for _ <- 1..200, do: Enum.to_list(1..200)
      {us, out} = :timer.tc(fn -> Sanitizer.assigns(%{huge: huge}) end)
      assert inspect(out, limit: :infinity) =~ "More"
      assert us < 500_000
    end
  end

  describe "R7 — params are recorded as shape, values only for keep-listed keys" do
    test "typed form values never survive; their shape does" do
      params = %{
        "contact" => %{"email" => "ada@example.com", "full_name" => "Ada Lovelace"},
        "q" => "Grace",
        "page" => 3,
        "sort" => "inserted_at"
      }

      keep = [{"sort", ["inserted_at", "name"]}, "page"]
      %Shape{fields: fields} = Sanitizer.params(params, keep)
      by_key = Map.new(fields, &{&1.key, &1})

      assert by_key["sort"].value == "inserted_at"
      assert by_key["page"].value == 3
      # Not keep-listed → no value, even though "Grace" is label-shaped.
      refute Map.has_key?(by_key["q"], :value)
      assert by_key["q"] == %{key: "q", type: :string, length: 5, class: :none}

      contact = Map.new(by_key["contact"].fields, &{&1.key, &1})
      assert contact["email"] == %{key: "email", type: :string, length: 15, class: :email}
      assert contact["full_name"] == %{key: "full_name", type: :string, length: 12, class: :name}

      dump = inspect(Sanitizer.params(params, keep), limit: :infinity)
      for secret <- ["ada@", "Lovelace", "Grace"], do: refute(dump =~ secret)
    end

    test "a keep-listed key keeps only a bounded label value — never free text or PII" do
      params = %{"filter" => "Ada Lovelace", "status" => "ada@example.com"}
      %Shape{fields: fields} = Sanitizer.params(params, ["filter", "status"])
      for f <- fields, do: refute(Map.has_key?(f, :value))
    end

    test "a client-chosen PII-shaped key is positional" do
      %Shape{fields: [field]} = Sanitizer.params(%{"ada@example.com" => "1"})
      assert field.key == "$k0"
    end
  end

  # ADR-052 §2.2.1 gate fix — the gate wrote "Sortvaluesecret", "Jane.Selectsecret",
  # "Paramkeysecret" and "Urlkeysecret" into replay_frame through a real ContactsLive session:
  # every one is label-shaped, so the old rules (a keep-listed value or any key only had to be
  # label-shaped) stored the client's own string.
  describe "a client-chosen string never reaches a frame (keep values and keys)" do
    test "a bare keep-listed name keeps only an integer, a boolean or a UUID" do
      id = Ash.UUID.generate()

      for {value, kept?} <- [
            {"Jane.Selectsecret", false},
            {"inserted_at", false},
            {id, true},
            {7, true},
            {true, true},
            {1.5, false}
          ] do
        %Shape{fields: [field]} = Sanitizer.params(%{"id" => value}, ["id"])
        assert Map.has_key?(field, :value) == kept?, inspect(value)
        if kept?, do: assert(field.value == value)
      end
    end

    test "{name, allowed} keeps a string only from the declared closed set" do
      keep = [{"dir", ["next", "prev"]}]

      %Shape{fields: [ok]} = Sanitizer.params(%{"dir" => "next"}, keep)
      assert ok.value == "next"

      %Shape{fields: [no]} = Sanitizer.params(%{"dir" => "Sortvaluesecret"}, keep)
      refute Map.has_key?(no, :value)
      assert no == %{key: "dir", type: :string, length: 15, class: :none}

      # Positive control: the same value under a NON-declared key is shape only too, and the
      # old rule (label-shaped) WOULD have kept it.
      assert Sanitizer.label?("Sortvaluesecret")
      %Shape{fields: [other]} = Sanitizer.params(%{"dir" => "next"}, [{"sort", ["next"]}])
      refute Map.has_key?(other, :value)
    end

    test "an atom-keyed param is matched to its declared name" do
      %Shape{fields: [f]} = Sanitizer.params(%{dir: "prev"}, [{"dir", ["next", "prev"]}])
      assert f.key == "dir"
      assert f.value == "prev"
      %Shape{fields: [n]} = Sanitizer.params(%{nil => 3}, ["nil"])
      refute Map.has_key?(n, :value)
    end

    test "a param key survives only as a server-known identifier" do
      id = Ash.UUID.generate()
      email = Atom.to_string(:email)

      params = %{
        "Paramkeysecret" => "x",
        email => "y",
        "999" => 1,
        "1000" => 1,
        id => 1
      }

      %Shape{fields: fields} = Sanitizer.params(params)
      keys = Enum.map(fields, & &1.key)

      # Positive control: the refused keys ARE label-shaped (the old rule kept them).
      assert Sanitizer.label?("Paramkeysecret") and Sanitizer.label?("1000")
      refute "Paramkeysecret" in keys
      refute "1000" in keys
      assert email in keys
      assert "999" in keys
      assert id in keys
      assert Enum.count(keys, &String.starts_with?(&1, "$k")) == 2
    end

    test "an assigns map keyed by row data keeps no data-derived key" do
      email = Atom.to_string(:email)
      out = Sanitizer.assigns(%{groups: %{"Aurelia" => 1, email => 2, "0" => 3}})
      assert out.groups[email] == 2
      assert out.groups["0"] == 3
      refute Map.has_key?(out.groups, "Aurelia")
      assert Sanitizer.label?("Aurelia")
      refute inspect(out, limit: :infinity) =~ "Aurelia"
    end

    test "known_key?/1 refuses a non-label and a non-string" do
      refute Sanitizer.known_key?("a b")
      refute Sanitizer.known_key?(:email)
      assert Sanitizer.known_key?("email")
    end
  end

  describe "edges (the mutation gate's survivors, each pinned)" do
    alias SamenCore.Support.ReplayFixtureDomain.Gadget

    defp depth_of(%Dropped{kind: :depth}, n), do: n
    defp depth_of(%{n: inner}, n), do: depth_of(inner, n + 1)

    # Nodes the walker actually spent budget on (markers it emitted instead do not count).
    defp walked(%Dropped{kind: :budget}), do: 0
    defp walked(%More{}), do: 0
    defp walked(list) when is_list(list), do: 1 + Enum.sum(Enum.map(list, &walked/1))
    defp walked(_leaf), do: 1

    test "__changed__ is never captured; an `only:` key absent from the assigns is skipped" do
      out = Sanitizer.assigns(%{a: 1, __changed__: %{a: true}})
      assert out == %{a: 1}
      assert Sanitizer.assigns(%{a: 1}, only: [:a, :gone]) == %{a: 1}
    end

    test "params that are a struct or not a map are an empty shape" do
      assert Sanitizer.params(URI.parse("https://example.com")) == %Shape{fields: []}
      assert Sanitizer.params("ada@example.com") == %Shape{fields: []}
    end

    test "the depth cap cuts at exactly #{8} levels" do
      deep = Enum.reduce(1..12, :leaf, fn _, acc -> %{n: acc} end)
      assert depth_of(Sanitizer.assigns(%{deep: deep}).deep, 0) == 8
    end

    test "the node budget is exactly #{5000} nodes per capture" do
      cube = for _ <- 1..50, do: for(_ <- 1..50, do: Enum.to_list(1..50))
      out = Sanitizer.assigns(%{cube: cube}).cube
      assert inspect(out, limit: :infinity) =~ "budget"
      assert walked(out) == 5000
    end

    test "an actor map needs :plane plus an id; a row-like map without :plane is walked" do
      id = Ash.UUID.generate()

      out =
        Sanitizer.assigns(%{
          row: %{id: id, org_id: id, n: 1},
          a: %{plane: :tenant, id: id},
          b: %{plane: :tenant, org_id: id},
          c: %{plane: :tenant}
        })

      assert out.row == %{id: %Id{value: id}, org_id: %Id{value: id}, n: 1}
      assert out.a == %Dropped{kind: :actor}
      assert out.b == %Dropped{kind: :actor}
      assert out.c == %{plane: :tenant}
    end

    test "a map keeps exactly #{50} entries; a small map carries no $more marker" do
      big = Map.new(1..51, &{&1, &1})
      out = Sanitizer.assigns(%{big: big, small: %{a: 1}})
      assert map_size(out.big) == 51
      assert out.big["$more"] == %More{n: 1}
      refute Map.has_key?(out.small, "$more")
    end

    test "a sensitive? structural attribute is never kept; projected kinds are" do
      id = Ash.UUID.generate()
      rec = %Gadget{id: id, count: 7, secret_count: 42, note: "Ada Lovelace", status: :open}

      %Record{resource: "SamenCore.Support.ReplayFixtureDomain.Gadget", pk: ^id, fields: f} =
        Sanitizer.value(rec)

      assert f.count == 7
      assert f.status == :open
      assert f.id == %Id{value: id}
      assert f.secret_count == %Redacted{kind: :free_text}
      assert f.note == %Redacted{kind: :free_text, length: 12}
    end

    test "keep-listed strings: the exact length and byte bounds, and printability" do
      emoji = String.duplicate("😀", 120)

      out =
        Sanitizer.assigns(
          %{
            e: emoji,
            a120: String.duplicate("a", 120),
            a121: String.duplicate("a", 121),
            ctl: "a\u0001b"
          },
          keep: [:e, :a120, :a121, :ctl]
        )

      assert out.e == %Kept{value: emoji}
      assert out.a120 == %Kept{value: String.duplicate("a", 120)}
      assert out.a121 == %Redacted{kind: :string, length: 121}
      assert out.ctl == %Redacted{kind: :string, length: 3}
    end

    test "a Masked with a non-atom label keeps no label" do
      out = Sanitizer.assigns(%{m: %Samen.Masked{token: "vt_x", label: "Ada Lovelace"}})
      assert out.m == %Redacted{kind: :masked, label: nil}
    end

    test "a redacted string's length is computed up to 16 KiB, then omitted" do
      at = String.duplicate("a", 16_384)
      over = String.duplicate("a", 16_385)
      out = Sanitizer.assigns(%{at: at, over: over})
      assert out.at == %Redacted{kind: :string, length: 16_384}
      assert out.over == %Redacted{kind: :string, length: nil}
    end

    test "label? and uuid? boundaries" do
      assert Sanitizer.label?(String.duplicate("a", 64))
      refute Sanitizer.label?(String.duplicate("a", 65))
      refute Sanitizer.label?("a/b")
      refute Sanitizer.label?(nil)
      refute Sanitizer.label?(42)
      # Ecto.UUID.cast/1 would accept a RAW 16-byte binary; a 16-character string is not an id.
      refute Sanitizer.uuid?("abcdefghijklmnop")
      assert Sanitizer.uuid?(Ash.UUID.generate())
    end

    test "param keys: atoms by name; nil and booleans positional" do
      %Shape{fields: fields} = Sanitizer.params(%{:status => 1, nil => 2, true => 3})
      keys = fields |> Enum.map(& &1.key) |> Enum.sort()
      assert "status" in keys
      refute "nil" in keys
      refute "true" in keys
      assert Enum.count(keys, &String.starts_with?(&1, "$k")) == 2
    end

    test "param shapes nest exactly #{5} levels" do
      nested = Enum.reduce(1..8, 1, fn _, acc -> %{"a" => acc} end)
      %Shape{fields: [top]} = Sanitizer.params(nested)

      levels =
        Stream.unfold(top, fn
          nil -> nil
          f -> {f, f |> Map.get(:fields, []) |> List.first()}
        end)

      assert Enum.count(levels) == 5
    end

    test "a keep-listed float or map value is shape only" do
      %Shape{fields: fields} =
        Sanitizer.params(%{"rate" => 1.5, "m" => %{"x" => 1}}, ["rate", "m"])

      for f <- fields, do: refute(Map.has_key?(f, :value))
    end
  end
end

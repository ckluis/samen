defmodule Samen.Fleet.Report.SchemaTest do
  use ExUnit.Case, async: true

  alias Samen.Fleet.Report
  alias Samen.Fleet.Report.Schema

  describe "class discipline (RP-J-4 groundwork — T82's half)" do
    test "every declared field type is a member of Samen.WideEvent.Schema.bounded_types/0" do
      assert Schema.class_discipline_violations() == []
    end

    test "the fleet schema's permitted class set is a subset of WideEvent.Schema.bounded_types/0" do
      assert MapSet.subset?(MapSet.new(Schema.bounded_types()), MapSet.new(Samen.WideEvent.Schema.bounded_types()))
    end
  end

  describe "carried-LOW 3 — the residue budget correction" do
    test "three cohort lists x 256 x 16 bytes, corrected from the mis-stated 20 + 16x256" do
      # git_sha (20) + 16 bytes * 3 cohort lists * 256 max_len = 20 + 12_288 = 12_308
      assert Schema.residue_budget_bytes() == 20 + 16 * 3 * 256
      assert length(Schema.cohort_list_names()) == 3
    end

    test "%Suppressed{}'s five fields are bound: closed enum reason + ranges for the rest" do
      fields = Schema.suppressed_fields()
      assert {:reason, :enum, opts} = List.keyfind(fields, :reason, 0)
      assert Keyword.get(opts, :allowed) == [:k_anonymity, :l_diversity, :query_budget]

      for name <- [:k, :l, :observed, :limit] do
        assert {^name, :number, opts} = List.keyfind(fields, name, 0)
        assert Keyword.has_key?(opts, :range)
      end
    end
  end

  describe "carried-LOW 5 (T82 half) — since_us / activity_counts[].count ranges" do
    test "attention[].since_us carries a range" do
      {:attention, opts} = List.keyfind(Schema.list_fields(), :attention, 0)
      item_fields = Keyword.fetch!(opts, :fields)
      assert {:since_us, :number, field_opts} = List.keyfind(item_fields, :since_us, 0)
      assert Keyword.has_key?(field_opts, :range)
    end

    test "activity_counts[].count carries a range" do
      {:activity_counts, opts} = List.keyfind(Schema.list_fields(), :activity_counts, 0)
      item_fields = Keyword.fetch!(opts, :fields)
      assert {:count, :number, field_opts} = List.keyfind(item_fields, :count, 0)
      assert Keyword.has_key?(field_opts, :range)
    end
  end

  describe "validate/1 — ingest re-validation (green + red)" do
    test "GREEN: a well-formed embedded report round-trips clean" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")
      payload = Report.to_wire(report)
      assert :ok = Schema.validate(payload)
    end

    test "RED: an unknown key is rejected" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")
      payload = Report.to_wire(report) |> Map.put("notes", "attacker text")
      assert {:error, errors} = Schema.validate(payload)
      assert Enum.any?(errors, &String.contains?(&1, "notes"))
    end

    test "RED: an out-of-range number is rejected" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")
      payload = Report.to_wire(report) |> Map.put("health_score", 999)
      assert {:error, errors} = Schema.validate(payload)
      assert Enum.any?(errors, &String.contains?(&1, "health_score"))
    end

    test "RED: an over-max_len list is rejected" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")

      oversized =
        for i <- 1..257 do
          %{"handle" => String.duplicate("a", 32), "sent" => i, "bounced" => 0, "complained" => 0, "health_index" => 0}
        end

      payload = Report.to_wire(report) |> Map.put("deliverability", oversized)
      assert {:error, errors} = Schema.validate(payload)
      assert Enum.any?(errors, &String.contains?(&1, "max_len"))
    end

    test "RED: a malformed opaque_id form is rejected" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")
      payload = Report.to_wire(report) |> Map.put("app_id", "not-a-uuid")
      assert {:error, errors} = Schema.validate(payload)
      assert Enum.any?(errors, &String.contains?(&1, "app_id"))
    end

    test "GREEN: a suppressed cohort cell round-trips clean" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")

      cell = %{
        "handle" => String.duplicate("a", 32),
        "sent" => 10,
        "bounced" => 1,
        "complained" => 0,
        "health_index" => %{"suppressed" => true, "reason" => "k_anonymity", "k" => 5, "observed" => 2}
      }

      payload = Report.to_wire(report) |> Map.put("deliverability", [cell])
      assert :ok = Schema.validate(payload)
    end

    test "RED: a suppressed cell with an unbound reason is rejected" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")

      cell = %{
        "handle" => String.duplicate("a", 32),
        "sent" => 10,
        "bounced" => 1,
        "complained" => 0,
        "health_index" => %{"suppressed" => true, "reason" => "not_a_real_reason"}
      }

      payload = Report.to_wire(report) |> Map.put("deliverability", [cell])
      assert {:error, _errors} = Schema.validate(payload)
    end
  end

  describe "BLOCKER-2 (fix round, ATK-6/INV-2) — hole (a): the 'cohorts' wrapper" do
    test "RED: a top-level \"cohorts\" key is rejected as unknown, never validated-through" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")

      payload =
        Report.to_wire(report)
        |> Map.put("cohorts", %{
          "leak_note" => "alice@example.com / 123 Main St / SSN 111-22-3333",
          "nested" => [%{"name" => "Alice Anderson", "email" => "alice@acme.test"}]
        })

      assert {:error, errors} = Schema.validate(payload)
      assert Enum.any?(errors, &String.contains?(&1, "cohorts"))
    end

    test "RED: an oversized \"cohorts\" blob is rejected, not merely truncated or ignored" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")
      payload = Report.to_wire(report) |> Map.put("cohorts", String.duplicate("x", 300_000))

      assert {:error, errors} = Schema.validate(payload)
      assert Enum.any?(errors, &String.contains?(&1, "cohorts"))
    end

    test "GREEN (control): the same report WITHOUT a cohorts key still validates :ok" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")
      payload = Report.to_wire(report)
      refute Map.has_key?(payload, "cohorts")
      assert :ok = Schema.validate(payload)
    end
  end

  describe "BLOCKER-2 (fix round, ATK-6/INV-2) — hole (b): closed-catalog fields are bounded" do
    test "RED: checks[].name carrying PII/free text is rejected" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")

      check = %{"name" => "alice.anderson@acme.test -- 4111 1111 1111 1111", "status" => "ok"}
      payload = Report.to_wire(report) |> Map.put("checks", [check])

      assert {:error, errors} = Schema.validate(payload)
      assert Enum.any?(errors, &String.contains?(&1, "name"))
    end

    test "RED: activity_counts[].event_kind carrying a large free-text blob is rejected" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")

      entries =
        for _ <- 1..3, do: %{"event_kind" => String.duplicate("a", 3000), "count" => 1}

      payload = Report.to_wire(report) |> Map.put("activity_counts", entries)

      assert {:error, errors} = Schema.validate(payload)
      assert Enum.any?(errors, &String.contains?(&1, "event_kind"))
    end

    test "RED: mrr_by_tier[].tier and oban[].queue reject an unbounded label" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")

      payload =
        Report.to_wire(report)
        |> Map.put("mrr_by_tier", [%{"tier" => "Not A Real Tier!", "mrr_cents" => 0, "tenant_count" => 0}])
        |> Map.put("oban", [
          %{
            "queue" => String.duplicate("q", 100),
            "available" => 0,
            "executing" => 0,
            "retryable" => 0,
            "discarded" => 0,
            "oldest_available_age_s" => 0
          }
        ])

      assert {:error, errors} = Schema.validate(payload)
      assert Enum.any?(errors, &String.contains?(&1, "tier"))
      assert Enum.any?(errors, &String.contains?(&1, "queue"))
    end

    test "GREEN (control): a genuinely bounded catalog label (^[a-z][a-z0-9_]{0,39}$) passes" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")

      check = %{"name" => "db_connectivity", "status" => "ok"}
      payload = Report.to_wire(report) |> Map.put("checks", [check])

      assert :ok = Schema.validate(payload)
    end

    test "end-to-end (mirrors the live reproduction): free-text cohorts + PII in checks[] together are rejected" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")

      payload =
        Report.to_wire(report)
        |> Map.put("cohorts", %{"leak_note" => "attacker-controlled PII"})
        |> Map.put("checks", [%{"name" => "leaked-name@example.com", "status" => "ok"}])

      assert {:error, _errors} = Schema.validate(payload)
    end
  end

  # ---------------------------------------------------------------------------
  # H1 (phase-6 SEC dogfood, ADR-044 §5.2b / INV-2) — the closed-member premise
  # reaches the NESTED level. T82's BLOCKER-2 fix rejected undeclared keys at the
  # TOP level only; `validate_item/5` + `validate_suppressed/4` walked only the
  # DECLARED field tables, so a valid-credential producer could smuggle free text /
  # PII in an undeclared key inside any list item or suppressed cell and
  # `Registry.record_report/4` stored it verbatim.
  # ---------------------------------------------------------------------------
  describe "H1 (phase6 SEC, INV-2 hole) — undeclared keys in list items + suppressed cells" do
    test "RED: an undeclared PII-bearing key inside a cohort LIST ITEM is rejected, never validated-through" do
      item =
        declared_section_items()
        |> Map.fetch!("deliverability")
        # the smuggled undeclared key — free text / PII the closed schema must reject.
        |> Map.put("leak_note", "alice@example.com / 123 Main St / SSN 111-22-3333")

      assert {:error, errors} = Schema.validate(wire_with("deliverability", item))
      assert Enum.any?(errors, &String.contains?(&1, "leak_note"))
    end

    test "RED: an undeclared PII-bearing key inside a SUPPRESSED cell is rejected" do
      item =
        declared_section_items()
        |> Map.fetch!("deliverability")
        |> Map.put("sent", %{
          "suppressed" => true,
          "reason" => "k_anonymity",
          "k" => 5,
          # the smuggled undeclared key inside the suppressed sub-map.
          "leak_note" => "bob@example.com card 4111 1111 1111 1111"
        })

      assert {:error, errors} = Schema.validate(wire_with("deliverability", item))
      assert Enum.any?(errors, &String.contains?(&1, "leak_note"))
    end

    test "RED: an undeclared item key is rejected across EVERY declared list section" do
      # Non-vacuity: the section list is the schema's OWN declared list table, so a
      # newly declared section cannot silently escape this sweep.
      declared = Enum.map(Schema.list_fields(), fn {name, _opts} -> Atom.to_string(name) end)
      assert Enum.sort(declared) == Enum.sort(Map.keys(declared_section_items()))

      for {section, valid_item} <- declared_section_items() do
        item = Map.put(valid_item, "leak_note", "pii@example.com")

        assert {:error, errors} = Schema.validate(wire_with(section, item)),
               "expected a #{section} item carrying an undeclared key to be REJECTED"

        assert Enum.any?(errors, &String.contains?(&1, "leak_note")),
               "expected the #{section} rejection to name the undeclared key, got: #{inspect(errors)}"
      end
    end

    test "GREEN (control): the SAME items WITHOUT the undeclared key validate :ok in every section" do
      for {section, valid_item} <- declared_section_items() do
        assert :ok = Schema.validate(wire_with(section, valid_item)),
               "expected a clean #{section} item to validate :ok (the RED cases above must be " <>
                 "the undeclared key firing, not a broken fixture)"
      end
    end

    test "GREEN (control): a suppressed cell with ONLY declared keys still validates :ok" do
      item =
        declared_section_items()
        |> Map.fetch!("deliverability")
        |> Map.put("sent", %{"suppressed" => true, "reason" => "k_anonymity", "k" => 5, "observed" => 2})

      assert :ok = Schema.validate(wire_with("deliverability", item))
    end

    test "RED: an over-long string inside a list item is rejected (nested length bound)" do
      # The secondary H1 angle: item values had no length ceiling, so a smuggled value
      # could be arbitrarily large (storage amplification / covert channel). The bound
      # applies to DECLARED keys too — this uses `handle`, whose 32-hex form already
      # rejects it, so assert on the length-bound reason specifically.
      over = String.duplicate("a", Schema.max_nested_string_bytes() + 1)

      item = Map.put(declared_section_items()["deliverability"], "handle", over)

      assert {:error, errors} = Schema.validate(wire_with("deliverability", item))
      assert Enum.any?(errors, &String.contains?(&1, "nested value bound"))
    end

    test "R6: the attacker-controlled KEY NAME echoed back in the error is itself bounded" do
      # The rejection message travels into logs / the verifier's stdout — an unbounded
      # key name would make the REJECTION path the very free-text channel the closed
      # schema exists to deny.
      huge_key = String.duplicate("k", 5_000)
      item = Map.put(declared_section_items()["deliverability"], huge_key, 1)

      assert {:error, errors} = Schema.validate(wire_with("deliverability", item))
      assert Enum.any?(errors, &String.contains?(&1, "truncated from 5000 bytes"))

      # No single error string carries the whole 5,000-byte name (bounded echo + prose).
      for e <- errors, do: assert(byte_size(e) < 500)
    end

    test "GREEN (control): a string exactly AT the nested bound is not rejected for length" do
      at_bound = String.duplicate("a", Schema.max_nested_string_bytes())
      item = Map.put(declared_section_items()["deliverability"], "handle", at_bound)

      assert {:error, errors} = Schema.validate(wire_with("deliverability", item))
      # rejected for its FORM (not 32 hex chars), never for the length bound.
      refute Enum.any?(errors, &String.contains?(&1, "nested value bound"))
    end
  end

  describe "fix round MED — J5 §8.2 rule 2: business metrics are optional, never fabricated" do
    test "GREEN: a report with every business metric OMITTED still validates :ok" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")
      payload = Report.to_wire(report)

      for key <- ~w(mrr_cents arr_cents active_subscriptions delinquent_subs tenant_count
                    active_tenant_count new_tenants_24h open_tickets breaching_sla
                    oldest_open_age_s sent delivered bounced complained suppressed
                    deliverability_health_index rules_active rules_tripped_24h
                    kill_switches_engaged) do
        refute Map.has_key?(payload, key), "expected #{key} to be omitted, not fabricated"
      end

      assert :ok = Schema.validate(payload)
    end

    test "GREEN: a vertical that DOES compute a metric can include it, still bounded" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")
      payload = Report.to_wire(report) |> Map.put("tenant_count", 42)
      assert :ok = Schema.validate(payload)
    end

    test "RED: a present business metric is still range-checked (optional does not mean unbounded)" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")
      payload = Report.to_wire(report) |> Map.put("deliverability_health_index", 999)
      assert {:error, errors} = Schema.validate(payload)
      assert Enum.any?(errors, &String.contains?(&1, "deliverability_health_index"))
    end

    test "health_status/health_score remain REQUIRED (the framework's own liveness claim)" do
      report = Report.build(app_id: "11111111-1111-4111-8111-111111111111")
      payload = Report.to_wire(report) |> Map.delete("health_status")
      assert {:error, errors} = Schema.validate(payload)
      assert Enum.any?(errors, &String.contains?(&1, "health_status"))
    end
  end

  # The valid, minimal item for every DECLARED list section — the GREEN control
  # each RED case below is derived from by adding exactly one undeclared key.
  defp declared_section_items do
    %{
      "checks" => %{"name" => "db_connectivity", "status" => "ok"},
      "mrr_by_tier" => %{"tier" => "pro", "mrr_cents" => 0, "tenant_count" => 0},
      "oban" => %{
        "queue" => "mailer",
        "available" => 0,
        "executing" => 0,
        "retryable" => 0,
        "discarded" => 0,
        "oldest_available_age_s" => 0
      },
      "attention" => %{
        "kind" => "incident",
        "severity" => "warn",
        "count" => 1,
        "since_us" => 1_700_000_000_000_000
      },
      "activity_counts" => %{"event_kind" => "login", "count" => 1},
      "deliverability" => %{
        "handle" => String.duplicate("a", 32),
        "sent" => 5,
        "bounced" => 0,
        "complained" => 0,
        "health_index" => 90
      },
      "automation" => %{
        "handle" => String.duplicate("b", 32),
        "rules_tripped" => 0,
        "kill_switches_engaged" => 0
      },
      "activity" => %{
        "handle" => String.duplicate("c", 32),
        "event_kind" => "login",
        "count" => 1
      }
    }
  end

  defp wire_with(section, item) do
    Report.build(app_id: "11111111-1111-4111-8111-111111111111")
    |> Report.to_wire()
    |> Map.put(section, [item])
  end
end

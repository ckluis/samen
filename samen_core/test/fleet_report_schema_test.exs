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
end

defmodule Demo.ApiContractVerifierTest do
  @moduledoc """
  T3.12 — `mix samen.verify.api_contract` verifier (C6).

  Scope from the plan (§C6 + task T3.12):
    - Snapshot the v1 contract to a committed `demo/api_contract.v1.json`
      (deterministic ordering like `schema.dict.json`).
    - The mix task diffs current vs snapshot and FAILS (exit 1) on un-versioned
      STRUCTURAL breaks: removed/renamed field, narrowed type, dropped route,
      new required arg.
    - Additive changes PASS (new field, new route, new optional arg, new resource).
    - Semantic breaks explicitly OUT OF SCOPE; each diagnostic states this.

  ## Red paths (four break classes, each seeded and caught)

    1. `field_removed`      — a previously exposed field is removed from show_fields.
    2. `type_narrowed`      — an exposed field's Ash type changes.
    3. `route_dropped`      — a previously declared route is removed.
    4. `required_arg_added` — an action gains a new required argument.

  ## Additive pass

    - New field added to a resource's show_fields does NOT raise a violation.
    - New route added does NOT raise a violation.

  ## Anti-tautology probe

  The probe directly sabotages `Samen.ApiContract.Differ.diff/2` by seeding a
  stored snapshot that ALREADY CONTAINS a field_removed violation, then confirming
  the verifier returns that violation (not a false-clear). This proves the diff
  logic is a genuine discriminator, not an always-pass tautology.

  See HARD RULE 2: the probe uses a scratch dir created at runtime inside this test
  (no file-system mutation of the committed snapshot), and the diff is exercised via
  `check/2` rather than `:erlang.halt/1` — so no process termination occurs.
  """

  use ExUnit.Case, async: false

  alias Samen.ApiContract
  alias Samen.ApiContract.Differ

  # ---------------------------------------------------------------------------
  # Helpers: build synthetic snapshots for unit-level diff testing.
  # We test `Samen.ApiContract.diff/2` (which calls `Differ.diff/2`) directly
  # rather than spawning a child mix process — this keeps tests fast and lets us
  # inspect violation text without parsing stderr.
  # ---------------------------------------------------------------------------

  # A minimal valid snapshot with one resource, two routes, two fields.
  defp base_snapshot(extra_fields \\ [], extra_routes \\ [], extra_required \\ []) do
    %{
      "version" => "v1",
      "resources" => [
        %{
          "type" => "contact",
          "module" => "Elixir.Demo.Crm.Contact",
          "fields" =>
            [
              %{"name" => "display_name", "type" => "Ash.Type.String", "required" => false},
              %{"name" => "id", "type" => "Ash.Type.UUID", "required" => true}
            ] ++ extra_fields,
          "routes" =>
            [
              %{
                "method" => "GET",
                "path" => "/contacts",
                "action" => "read",
                "required_args" => extra_required
              },
              %{
                "method" => "GET",
                "path" => "/contacts/:id",
                "action" => "read",
                "required_args" => extra_required
              }
            ] ++ extra_routes
        }
      ]
    }
  end

  # ---------------------------------------------------------------------------
  # RED PATH 1 — field_removed
  # ---------------------------------------------------------------------------

  describe "red path: field_removed" do
    test "diff detects a field removed from the live contract" do
      # Stored snapshot has 'display_name'; live snapshot does NOT.
      stored =
        base_snapshot()

      # Live snapshot has 'display_name' removed.
      live = %{
        "version" => "v1",
        "resources" => [
          %{
            "type" => "contact",
            "module" => "Elixir.Demo.Crm.Contact",
            "fields" => [
              %{"name" => "id", "type" => "Ash.Type.UUID", "required" => true}
              # 'display_name' deliberately absent → structural break
            ],
            "routes" => [
              %{
                "method" => "GET",
                "path" => "/contacts",
                "action" => "read",
                "required_args" => []
              },
              %{
                "method" => "GET",
                "path" => "/contacts/:id",
                "action" => "read",
                "required_args" => []
              }
            ]
          }
        ]
      }

      {:error, violations} = ApiContract.diff(live, stored)

      assert length(violations) >= 1,
             "Expected at least 1 violation for removed field, got: #{inspect(violations)}"

      assert Enum.any?(violations, &String.contains?(&1, "field_removed")),
             "Expected a field_removed violation, got: #{inspect(violations)}"

      assert Enum.any?(violations, &String.contains?(&1, "display_name")),
             "Expected violation to name the removed field, got: #{inspect(violations)}"

      # Verify the semantic-break note is present in the diagnostic.
      assert Enum.any?(violations, &String.contains?(&1, "semantic breaks")),
             "Expected semantic-break note in diagnostic, got: #{inspect(violations)}"
    end
  end

  # ---------------------------------------------------------------------------
  # RED PATH 2 — type_narrowed
  # ---------------------------------------------------------------------------

  describe "red path: type_narrowed" do
    test "diff detects a type change on an exposed field" do
      # Stored snapshot: display_name is Ash.Type.String
      stored = base_snapshot()

      # Live snapshot: display_name changed to Ash.Type.Integer (a narrowing)
      live = %{
        "version" => "v1",
        "resources" => [
          %{
            "type" => "contact",
            "module" => "Elixir.Demo.Crm.Contact",
            "fields" => [
              %{"name" => "display_name", "type" => "Ash.Type.Integer", "required" => false},
              %{"name" => "id", "type" => "Ash.Type.UUID", "required" => true}
            ],
            "routes" => [
              %{
                "method" => "GET",
                "path" => "/contacts",
                "action" => "read",
                "required_args" => []
              },
              %{
                "method" => "GET",
                "path" => "/contacts/:id",
                "action" => "read",
                "required_args" => []
              }
            ]
          }
        ]
      }

      {:error, violations} = ApiContract.diff(live, stored)

      assert length(violations) >= 1,
             "Expected at least 1 violation for type change, got: #{inspect(violations)}"

      assert Enum.any?(violations, &String.contains?(&1, "type_narrowed")),
             "Expected a type_narrowed violation, got: #{inspect(violations)}"

      assert Enum.any?(violations, &String.contains?(&1, "display_name")),
             "Expected violation to name the affected field, got: #{inspect(violations)}"

      assert Enum.any?(violations, &String.contains?(&1, "Ash.Type.String")),
             "Expected violation to name the old type, got: #{inspect(violations)}"

      assert Enum.any?(violations, &String.contains?(&1, "semantic breaks")),
             "Expected semantic-break note in diagnostic, got: #{inspect(violations)}"
    end
  end

  # ---------------------------------------------------------------------------
  # RED PATH 3 — route_dropped
  # ---------------------------------------------------------------------------

  describe "red path: route_dropped" do
    test "diff detects a route removed from the live contract" do
      # Stored snapshot has GET /contacts/:id; live does NOT.
      stored = base_snapshot()

      live = %{
        "version" => "v1",
        "resources" => [
          %{
            "type" => "contact",
            "module" => "Elixir.Demo.Crm.Contact",
            "fields" => [
              %{"name" => "display_name", "type" => "Ash.Type.String", "required" => false},
              %{"name" => "id", "type" => "Ash.Type.UUID", "required" => true}
            ],
            "routes" => [
              # GET /contacts/:id deliberately removed → structural break
              %{
                "method" => "GET",
                "path" => "/contacts",
                "action" => "read",
                "required_args" => []
              }
            ]
          }
        ]
      }

      {:error, violations} = ApiContract.diff(live, stored)

      assert length(violations) >= 1,
             "Expected at least 1 violation for dropped route, got: #{inspect(violations)}"

      assert Enum.any?(violations, &String.contains?(&1, "route_dropped")),
             "Expected a route_dropped violation, got: #{inspect(violations)}"

      assert Enum.any?(violations, &String.contains?(&1, "/contacts/:id")),
             "Expected violation to name the dropped route path, got: #{inspect(violations)}"

      assert Enum.any?(violations, &String.contains?(&1, "semantic breaks")),
             "Expected semantic-break note in diagnostic, got: #{inspect(violations)}"
    end

    test "diff detects an entire resource dropped from the live contract" do
      # Stored snapshot has a 'membership' resource; live does NOT.
      stored = %{
        "version" => "v1",
        "resources" => [
          %{
            "type" => "contact",
            "module" => "Elixir.Demo.Crm.Contact",
            "fields" => [%{"name" => "id", "type" => "Ash.Type.UUID", "required" => true}],
            "routes" => [
              %{"method" => "GET", "path" => "/contacts", "action" => "read", "required_args" => []}
            ]
          },
          %{
            "type" => "membership",
            "module" => "Elixir.Demo.Identity.Membership",
            "fields" => [%{"name" => "id", "type" => "Ash.Type.UUID", "required" => true}],
            "routes" => [
              %{
                "method" => "GET",
                "path" => "/memberships",
                "action" => "read",
                "required_args" => []
              }
            ]
          }
        ]
      }

      live = %{
        "version" => "v1",
        "resources" => [
          %{
            "type" => "contact",
            "module" => "Elixir.Demo.Crm.Contact",
            "fields" => [%{"name" => "id", "type" => "Ash.Type.UUID", "required" => true}],
            "routes" => [
              %{"method" => "GET", "path" => "/contacts", "action" => "read", "required_args" => []}
            ]
          }
          # 'membership' resource deliberately absent → route_dropped
        ]
      }

      {:error, violations} = ApiContract.diff(live, stored)

      assert Enum.any?(violations, &String.contains?(&1, "route_dropped")),
             "Expected a route_dropped violation for the dropped resource, got: #{inspect(violations)}"

      assert Enum.any?(violations, &String.contains?(&1, "membership")),
             "Expected violation to name the dropped resource type, got: #{inspect(violations)}"
    end
  end

  # ---------------------------------------------------------------------------
  # RED PATH 4 — required_arg_added
  # ---------------------------------------------------------------------------

  describe "red path: required_arg_added" do
    test "diff detects a new required argument added to a route" do
      # Stored snapshot: GET /contacts has no required args.
      stored = base_snapshot()

      # Live snapshot: GET /contacts now requires a 'filter_by_status' arg.
      live = %{
        "version" => "v1",
        "resources" => [
          %{
            "type" => "contact",
            "module" => "Elixir.Demo.Crm.Contact",
            "fields" => [
              %{"name" => "display_name", "type" => "Ash.Type.String", "required" => false},
              %{"name" => "id", "type" => "Ash.Type.UUID", "required" => true}
            ],
            "routes" => [
              %{
                "method" => "GET",
                "path" => "/contacts",
                "action" => "read",
                # Previously optional, now required → structural break
                "required_args" => ["filter_by_status"]
              },
              %{
                "method" => "GET",
                "path" => "/contacts/:id",
                "action" => "read",
                "required_args" => []
              }
            ]
          }
        ]
      }

      {:error, violations} = ApiContract.diff(live, stored)

      assert length(violations) >= 1,
             "Expected at least 1 violation for new required arg, got: #{inspect(violations)}"

      assert Enum.any?(violations, &String.contains?(&1, "required_arg_added")),
             "Expected a required_arg_added violation, got: #{inspect(violations)}"

      assert Enum.any?(violations, &String.contains?(&1, "filter_by_status")),
             "Expected violation to name the new required arg, got: #{inspect(violations)}"

      assert Enum.any?(violations, &String.contains?(&1, "semantic breaks")),
             "Expected semantic-break note in diagnostic, got: #{inspect(violations)}"
    end
  end

  # ---------------------------------------------------------------------------
  # ADDITIVE CHANGES PASS
  # ---------------------------------------------------------------------------

  describe "additive changes: no violation" do
    test "a new field in the live contract does NOT cause a violation" do
      # Stored snapshot has display_name + id.
      stored = base_snapshot()

      # Live adds 'active' — additive, backward-compatible.
      live = %{
        "version" => "v1",
        "resources" => [
          %{
            "type" => "contact",
            "module" => "Elixir.Demo.Crm.Contact",
            "fields" => [
              %{"name" => "active", "type" => "Ash.Type.Boolean", "required" => false},
              %{"name" => "display_name", "type" => "Ash.Type.String", "required" => false},
              %{"name" => "id", "type" => "Ash.Type.UUID", "required" => true}
            ],
            "routes" => [
              %{
                "method" => "GET",
                "path" => "/contacts",
                "action" => "read",
                "required_args" => []
              },
              %{
                "method" => "GET",
                "path" => "/contacts/:id",
                "action" => "read",
                "required_args" => []
              }
            ]
          }
        ]
      }

      assert {:ok, []} = ApiContract.diff(live, stored),
             "Expected no violations for additive field addition"
    end

    test "a new route in the live contract does NOT cause a violation" do
      stored = base_snapshot()

      # Live adds POST /contacts — additive.
      live = %{
        "version" => "v1",
        "resources" => [
          %{
            "type" => "contact",
            "module" => "Elixir.Demo.Crm.Contact",
            "fields" => [
              %{"name" => "display_name", "type" => "Ash.Type.String", "required" => false},
              %{"name" => "id", "type" => "Ash.Type.UUID", "required" => true}
            ],
            "routes" => [
              %{
                "method" => "GET",
                "path" => "/contacts",
                "action" => "read",
                "required_args" => []
              },
              %{
                "method" => "GET",
                "path" => "/contacts/:id",
                "action" => "read",
                "required_args" => []
              },
              # New POST route — additive
              %{
                "method" => "POST",
                "path" => "/contacts",
                "action" => "create",
                "required_args" => []
              }
            ]
          }
        ]
      }

      assert {:ok, []} = ApiContract.diff(live, stored),
             "Expected no violations for additive route addition"
    end

    test "a new resource in the live contract does NOT cause a violation" do
      # Stored only has 'contact'.
      stored = base_snapshot()

      # Live adds 'org' — additive. The existing 'contact' resource keeps ALL its routes.
      live = %{
        "version" => "v1",
        "resources" => [
          %{
            "type" => "contact",
            "module" => "Elixir.Demo.Crm.Contact",
            "fields" => [
              %{"name" => "display_name", "type" => "Ash.Type.String", "required" => false},
              %{"name" => "id", "type" => "Ash.Type.UUID", "required" => true}
            ],
            "routes" => [
              %{
                "method" => "GET",
                "path" => "/contacts",
                "action" => "read",
                "required_args" => []
              },
              %{
                "method" => "GET",
                "path" => "/contacts/:id",
                "action" => "read",
                "required_args" => []
              }
            ]
          },
          %{
            "type" => "org",
            "module" => "Elixir.Demo.Identity.Org",
            "fields" => [%{"name" => "id", "type" => "Ash.Type.UUID", "required" => true}],
            "routes" => [
              %{"method" => "GET", "path" => "/orgs", "action" => "read", "required_args" => []}
            ]
          }
        ]
      }

      assert {:ok, []} = ApiContract.diff(live, stored),
             "Expected no violations for additive resource addition"
    end

    test "a new optional argument does NOT cause a violation" do
      stored = base_snapshot()

      # Live adds an optional arg (required_args remains empty because it's optional).
      live = %{
        "version" => "v1",
        "resources" => [
          %{
            "type" => "contact",
            "module" => "Elixir.Demo.Crm.Contact",
            "fields" => [
              %{"name" => "display_name", "type" => "Ash.Type.String", "required" => false},
              %{"name" => "id", "type" => "Ash.Type.UUID", "required" => true}
            ],
            "routes" => [
              %{
                "method" => "GET",
                "path" => "/contacts",
                "action" => "read",
                # Still no required_args — optional args don't change required_args
                "required_args" => []
              },
              %{
                "method" => "GET",
                "path" => "/contacts/:id",
                "action" => "read",
                "required_args" => []
              }
            ]
          }
        ]
      }

      assert {:ok, []} = ApiContract.diff(live, stored),
             "Expected no violations for optional argument addition"
    end

    test "live contract identical to stored → no violations" do
      stored = base_snapshot()
      assert {:ok, []} = ApiContract.diff(stored, stored)
    end
  end

  # ---------------------------------------------------------------------------
  # COMMITTED SNAPSHOT ROUND-TRIP
  # ---------------------------------------------------------------------------

  describe "committed snapshot round-trip" do
    test "the committed api_contract.v1.json passes the verifier against the live demo app" do
      # Load the committed snapshot and build the live snapshot from the demo domains.
      snapshot_path = Path.join(File.cwd!(), "api_contract.v1.json")

      assert File.exists?(snapshot_path),
             "api_contract.v1.json must exist at #{snapshot_path}. Run `mix samen.verify.api_contract --version v1 --update`."

      stored = snapshot_path |> File.read!() |> Samen.ApiContract.decode!()

      live = ApiContract.snapshot([Demo.Crm, Demo.Identity], "v1")

      assert {:ok, []} = ApiContract.diff(live, stored),
             "Live API contract diverged from committed snapshot! " <>
               "This means an un-versioned structural break was introduced. " <>
               "Run `mix samen.verify.api_contract --version v1 --update` if this is an intentional versioned change."
    end
  end

  # ---------------------------------------------------------------------------
  # X9 non-emptiness floor — POSITIVE CONTROL (luminary pre-merge)
  #
  # The task now fails closed when the live contract discovers zero AshJsonApi
  # resources (samen_core/test/verify_api_contract_task_test.exs proves the red
  # side). These are the green side: demo's contract genuinely discovers
  # resources, so the round-trip test above is a real diff, not empty-vs-empty.
  # ---------------------------------------------------------------------------

  describe "non-emptiness floor (X9): positive control" do
    test "the live demo contract discovers a NON-empty resource set" do
      live = ApiContract.snapshot([Demo.Crm, Demo.Identity], "v1")

      assert length(live["resources"]) > 0,
             "The demo live API contract introspected ZERO resources — the " <>
               "committed-snapshot round-trip above would be a vacuous empty-vs-empty diff."
    end

    test "the committed api_contract.v1.json pins a NON-empty resource set" do
      stored =
        File.cwd!()
        |> Path.join("api_contract.v1.json")
        |> File.read!()
        |> Samen.ApiContract.decode!()

      assert length(stored["resources"]) > 0,
             "The committed snapshot is EMPTY — it pins nothing, so no structural " <>
               "break could ever flip the gate. Re-run `mix samen.verify.api_contract " <>
               "--version v1 --update` (the task now refuses to write an empty snapshot)."
    end
  end

  # ---------------------------------------------------------------------------
  # SNAPSHOT FORMAT — deterministic ordering
  # ---------------------------------------------------------------------------

  describe "snapshot format" do
    test "encode! produces deterministic JSON (sorted keys, sorted resources)" do
      snapshot = ApiContract.snapshot([Demo.Crm, Demo.Identity], "v1")
      json1 = ApiContract.encode!(snapshot)
      json2 = ApiContract.encode!(snapshot)

      assert json1 == json2, "Snapshot encoding is not deterministic"

      # Decode and verify top-level key order is alphabetical.
      # Jason preserves insertion order, so if sort_deeply is working, "resources"
      # comes before "version" alphabetically → check the file starts correctly.
      assert String.starts_with?(json1, "{\n  \"resources\""),
             "Expected 'resources' key before 'version' (alphabetical), got: #{String.slice(json1, 0, 50)}"
    end

    test "resources are sorted alphabetically by type" do
      snapshot = ApiContract.snapshot([Demo.Crm, Demo.Identity], "v1")
      types = Enum.map(snapshot["resources"], & &1["type"])
      assert types == Enum.sort(types), "Resources not sorted by type: #{inspect(types)}"
    end

    test "fields within each resource are sorted alphabetically by name" do
      snapshot = ApiContract.snapshot([Demo.Crm, Demo.Identity], "v1")

      Enum.each(snapshot["resources"], fn resource ->
        names = Enum.map(resource["fields"], & &1["name"])
        assert names == Enum.sort(names),
               "Fields for #{resource["type"]} not sorted by name: #{inspect(names)}"
      end)
    end

    test "routes within each resource are sorted by method then path" do
      snapshot = ApiContract.snapshot([Demo.Crm, Demo.Identity], "v1")

      Enum.each(snapshot["resources"], fn resource ->
        keys = Enum.map(resource["routes"], fn r -> {r["method"], r["path"]} end)
        assert keys == Enum.sort(keys),
               "Routes for #{resource["type"]} not sorted: #{inspect(keys)}"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # ANTI-TAUTOLOGY PROBE (HARD RULE 2)
  #
  # Directly sabotage the stored snapshot so it contains a field_removed
  # violation scenario, then confirm the differ returns a violation (not a
  # false-clear). This proves Differ.diff/2 is a genuine discriminator and not
  # an always-pass tautology.
  #
  # The probe operates on in-memory maps only (no file I/O, no `:erlang.halt/1`,
  # no mutation of the committed snapshot). The scratch state is local to this
  # test and is discarded at the end.
  # ---------------------------------------------------------------------------

  describe "anti-tautology probe" do
    test "sabotaged snapshot (field added to stored) yields field_removed violation — not a tautology" do
      # Step 1: Build the live snapshot from the demo app.
      live = ApiContract.snapshot([Demo.Crm, Demo.Identity], "v1")

      # Step 2: Sabotage the stored snapshot by injecting a field that does NOT
      # exist in the live contract. This simulates what happens if a developer
      # removed 'display_name' from the live resource without bumping the contract.
      contact_resource = Enum.find(live["resources"], &(&1["type"] == "contact"))
      refute is_nil(contact_resource), "Expected contact resource in live snapshot"

      sabotaged_contact =
        Map.update!(contact_resource, "fields", fn fields ->
          # Add a ghost field that the live contract does NOT expose.
          [
            %{
              "name" => "GHOST_FIELD_NOT_IN_LIVE",
              "type" => "Ash.Type.String",
              "required" => false
            }
            | fields
          ]
        end)

      sabotaged_stored = %{
        live
        | "resources" =>
            Enum.map(live["resources"], fn r ->
              if r["type"] == "contact", do: sabotaged_contact, else: r
            end)
      }

      # Step 3: Run the diff. The live contract does NOT have GHOST_FIELD_NOT_IN_LIVE
      # in the contact resource's fields — so the differ must report field_removed.
      {:error, violations} = Differ.diff(live, sabotaged_stored)

      assert Enum.any?(violations, &String.contains?(&1, "field_removed")),
             "ANTI-TAUTOLOGY PROBE FAILED: the differ did not catch the seeded field_removed " <>
               "violation — this means the verifier is a tautology (always passes). " <>
               "Got: #{inspect(violations)}"

      assert Enum.any?(violations, &String.contains?(&1, "GHOST_FIELD_NOT_IN_LIVE")),
             "Expected the violation to name the ghost field, got: #{inspect(violations)}"

      # Step 4 (revert): The sabotaged_stored is an in-memory map — no file to
      # revert. Confirm the LIVE snapshot itself (which was not mutated) still
      # passes against itself (the un-sabotaged baseline).
      assert {:ok, []} = Differ.diff(live, live),
             "The live snapshot does not pass against itself — something is wrong with the baseline"
    end
  end

  # ---------------------------------------------------------------------------
  # SEMANTIC BREAKS NOTE
  # ---------------------------------------------------------------------------

  describe "semantic break out-of-scope note" do
    test "same field, same type, same route → no violation (semantic break is out of scope)" do
      # This test documents that the verifier does NOT catch semantic breaks.
      # A field named 'amount' that changes from dollars to cents keeps the same
      # type (Ash.Type.Integer) and the same field name — the diff cannot detect it.
      stored = %{
        "version" => "v1",
        "resources" => [
          %{
            "type" => "invoice",
            "module" => "Elixir.Demo.Billing.Invoice",
            "fields" => [
              # 'amount' is in dollars in the stored snapshot
              %{"name" => "amount", "type" => "Ash.Type.Integer", "required" => false}
            ],
            "routes" => [
              %{"method" => "GET", "path" => "/invoices", "action" => "read", "required_args" => []}
            ]
          }
        ]
      }

      live = %{
        "version" => "v1",
        "resources" => [
          %{
            "type" => "invoice",
            "module" => "Elixir.Demo.Billing.Invoice",
            "fields" => [
              # 'amount' is now in cents in the live resource — semantic break!
              # But the diff cannot detect this. This is the documented limitation.
              %{"name" => "amount", "type" => "Ash.Type.Integer", "required" => false}
            ],
            "routes" => [
              %{"method" => "GET", "path" => "/invoices", "action" => "read", "required_args" => []}
            ]
          }
        ]
      }

      # The verifier correctly passes (it cannot see the semantic break).
      assert {:ok, []} = ApiContract.diff(live, stored),
             "Semantic breaks (same shape, changed meaning) must be out of scope — " <>
               "they remain the author's responsibility per the vision doc"
    end
  end
end

defmodule PawChart.ReadsHonestFailureP4Test do
  @moduledoc """
  WP6 phase 4 — "a failed read never renders as empty or `not found`", and "a failed write tells the
  user", for the PAWCHART vertical: the clinic surface (`/clinic`: patients, pets, patient detail), the
  operator impersonation console (masked patient roster) and the authorized-orgs membership seam.

  The framework's fault seam (`inject_read_faults/1`) is compiled out of a vertical build, so every
  failure here is REAL: Postgres DDL is transactional, so a `RENAME COLUMN` / a `CHECK (false) NOT
  VALID` constraint inside the sandbox transaction makes the very query or insert the screen runs
  fail, and rolls back with the test. Each failure is paired with a POSITIVE CONTROL (the same screen
  over a genuinely empty or healthy result still renders the real empty state / the real data) and with
  the recovery (the same call succeeds once the table is healthy again).

  The operator plane stays masked: an error state carries no name, no email and no `vt_` token.
  """
  use PawChart.DataCase, async: false

  import ExUnit.CaptureLog

  alias PawChartWeb.ClinicLive
  alias PawChartWeb.ClinicReads, as: Reads
  alias PawChartWeb.OperatorImpersonationLive, as: Console
  alias Samen.Web.CurrentOrg

  @org "c1112d00-0000-4000-8000-0000000000f4"
  @other_org "c1112d00-0000-4000-8000-0000000000f5"

  # -- harness -----------------------------------------------------------------------------------

  defp ddl!(sql), do: Ecto.Adapters.SQL.query!(PawChart.Repo, sql, [])
  defp break_select!(table, column), do: ddl!("ALTER TABLE #{table} RENAME COLUMN #{column} TO #{column}_renamed")
  defp break_writes!(table), do: ddl!("ALTER TABLE #{table} ADD CONSTRAINT zz_p4_broken CHECK (false) NOT VALID")
  defp quiet(fun), do: fun |> with_log() |> elem(0)

  defp raised_with_stack(fun) do
    fun.()
    flunk("expected a raise")
  rescue
    e in ExUnit.AssertionError -> reraise e, __STACKTRACE__
    e -> {e, __STACKTRACE__}
  end

  defp mount do
    Samen.Web.Mount.new(:crm, PawChart.Crm, PawChart.Repo,
      plane: Samen.Web.Plane.tenant(),
      labels: %{title: "Happy Paws Clinic", glyph: "V", org_directory: {PawChart.Directory, :orgs, []}}
    )
  end

  defp clinic_socket(org \\ @org, params \\ %{}, extra \\ []) do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    |> Phoenix.Component.assign([samen_mount: mount(), samen_acting_as: false] ++ extra)
    |> ClinicLive.load(org, params)
  end

  defp clinic_html(socket) do
    socket.assigns
    |> Map.put(:__changed__, %{})
    |> ClinicLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp clinic_event(socket, name, params \\ %{}) do
    {:noreply, socket} = ClinicLive.handle_event(name, params, socket)
    socket
  end

  defp assert_error_state(rendered) do
    assert rendered =~ "error-state"
    assert rendered =~ ~s(role="alert")
    assert rendered =~ "Nothing was lost"
    refute rendered =~ "vt_"
  end

  defp create_owner!(org \\ @org, first \\ "Alice", opts \\ []) do
    {:ok, owner} =
      Reads.create_owner(org, %{
        "first" => first,
        "last" => "Owner",
        "email" => Keyword.get(opts, :email, "#{String.downcase(first)}@example.test"),
        "phone" => "+15550000000"
      })

    owner
  end

  defp create_pet!(org \\ @org, name \\ "Rex", owner_id \\ nil) do
    {:ok, pet} = Reads.create_pet(org, %{"name" => name, "species" => "canine", "owner_id" => owner_id || ""})
    pet
  end

  # ===========================================================================
  # Clinic surface: each pane reads through its tagged result and fails alone
  # ===========================================================================

  describe "clinic patients and pets panes" do
    test "a failed patient roster is the error state with a retry, not 'No patients yet.'; the pets pane fails alone" do
      owner = create_owner!()
      create_pet!(@org, "Rex", owner.id)
      break_select!("own_patient", "own_marketing_opt_in")

      socket = quiet(fn -> clinic_socket() end)
      rendered = clinic_html(socket)

      assert socket.assigns.owners_error == :unavailable
      assert socket.assigns.pets_error == nil
      assert_error_state(rendered)
      assert rendered =~ "retry_load"
      refute rendered =~ "No patients yet."
      refute rendered =~ "patients-empty"
      refute rendered =~ "patient-row"
      # the pets pane is another read and still renders — but its Owner column does not claim "no owner"
      assert rendered =~ "pet-row"
      assert rendered =~ "unavailable"
    end

    test "a failed pet roster is the error state, not 'No pets yet.'" do
      create_owner!()
      create_pet!()
      break_select!("pet_pet", "pet_species")

      socket = quiet(fn -> clinic_socket() end)
      rendered = clinic_html(socket)

      assert socket.assigns.pets_error == :unavailable
      assert_error_state(rendered)
      refute rendered =~ "No pets yet."
      refute rendered =~ "pets-empty"
      assert rendered =~ "patient-row"
    end

    test "retry recovers once the table is healthy again" do
      create_owner!()
      ddl!("ALTER TABLE own_patient RENAME COLUMN own_marketing_opt_in TO own_marketing_opt_in_x")
      socket = quiet(fn -> clinic_socket() end)
      assert socket.assigns.owners_error == :unavailable

      ddl!("ALTER TABLE own_patient RENAME COLUMN own_marketing_opt_in_x TO own_marketing_opt_in")
      socket = clinic_event(socket, "retry_load")
      rendered = clinic_html(socket)

      assert socket.assigns.owners_error == nil
      refute rendered =~ "error-state"
      assert rendered =~ "patient-row"
    end

    test "POSITIVE CONTROL: a genuinely empty clinic still renders its real empty states" do
      socket = clinic_socket()
      rendered = clinic_html(socket)

      assert socket.assigns.owners_error == nil
      refute rendered =~ "error-state"
      assert rendered =~ "No patients yet."
      assert rendered =~ "No pets yet."
    end

    test "a failed patient-detail read is 'didn't load', not a silent 'no selection'; a missing or malformed id is not an error" do
      owner = create_owner!()
      healthy = clinic_socket(@org, %{"patient" => owner.id})
      assert clinic_html(healthy) =~ "patient-detail"

      break_select!("own_patient", "own_marketing_opt_in")
      failed = quiet(fn -> clinic_socket(@org, %{"patient" => owner.id}) end)
      rendered = clinic_html(failed)

      assert failed.assigns.selected_error == :unavailable
      assert rendered =~ "This patient didn&#39;t load" or rendered =~ "This patient didn't load"
      refute rendered =~ "patient-detail"

      ddl!("ALTER TABLE own_patient RENAME COLUMN own_marketing_opt_in_renamed TO own_marketing_opt_in")

      log =
        capture_log(fn ->
          for bad <- ["not-a-uuid", Ecto.UUID.generate(), "../x"] do
            socket = clinic_socket(@org, %{"patient" => bad})
            assert socket.assigns.selected_error == nil
            refute clinic_html(socket) =~ "patient-detail"
          end
        end)

      refute log =~ "read=pawchart"
    end

    test "the pet form does not open while the patient list is unavailable (it would save an ownerless pet)" do
      owner = create_owner!()
      pet = create_pet!(@org, "Rex", owner.id)
      socket = clinic_socket()
      break_select!("own_patient", "own_marketing_opt_in")
      socket = quiet(fn -> clinic_event(socket, "retry_load") end)

      for {event, params} <- [{"new_pet", %{}}, {"edit_pet", %{"id" => pet.id}}] do
        failed = clinic_event(socket, event, params)
        assert failed.assigns.flash["error"] =~ "Couldn't open the pet form", event
        assert failed.assigns.pet_modal == nil
      end
    end
  end

  # ===========================================================================
  # Reads: an outage is never "not found"
  # ===========================================================================

  describe "get_owner_result" do
    test "an outage is :unavailable, a missing or malformed id is :not_found (and logs nothing)" do
      owner = create_owner!()
      scope = Reads.tenant_scope(@org)

      assert {:ok, %{id: id}} = Reads.get_owner_result(scope, owner.id)
      assert id == owner.id

      log =
        capture_log(fn ->
          assert {:error, :not_found} = Reads.get_owner_result(scope, "not-a-uuid")
          assert {:error, :not_found} = Reads.get_owner_result(scope, Ecto.UUID.generate())
          assert {:error, :not_found} = Reads.get_owner_result(scope, nil)
          # the legacy shape keeps its contract for these
          assert :error = Reads.get_owner(scope, "not-a-uuid")
        end)

      refute log =~ "read=pawchart"

      break_select!("own_patient", "own_marketing_opt_in")
      log = capture_log(fn -> assert {:error, :unavailable} = Reads.get_owner_result(scope, owner.id) end)
      assert log =~ "read=pawchart_get_owner"
      refute log =~ "alice"
      assert quiet(fn -> Reads.get_owner(scope, owner.id) end) == :error
    end

    test "edit_owner names an outage as a failed check, not 'Patient not found in this clinic.'" do
      owner = create_owner!()
      socket = clinic_socket()
      break_select!("own_patient", "own_marketing_opt_in")

      failed = quiet(fn -> clinic_event(socket, "edit_owner", %{"id" => owner.id}) end)

      assert failed.assigns.flash["error"] =~ "Couldn't open that patient"
      assert failed.assigns.owner_error == nil
    end

    test "POSITIVE CONTROL: a genuinely missing patient is still 'not found in this clinic'" do
      failed = clinic_event(clinic_socket(), "edit_owner", %{"id" => Ecto.UUID.generate()})
      assert failed.assigns.owner_error == "Patient not found in this clinic."
    end
  end

  # ===========================================================================
  # Writes: a failed write tells the user, with outage copy and not validation copy
  # ===========================================================================

  describe "patient and pet writes" do
    test "create_owner on a failing table is {:error, :unavailable}, not a validation changeset" do
      break_writes!("own_patient")

      log = capture_log(fn -> assert {:error, :unavailable} = Reads.create_owner(@org, %{"first" => "Zed", "last" => "Z"}) end)
      assert log =~ "write failed write=pawchart_create_owner"
      refute log =~ "Zed"

      socket = clinic_socket(@org, %{}, owner_modal: :new, owner_form: %{})

      failed =
        quiet(fn -> clinic_event(socket, "save_owner", %{"owner" => %{"first" => "Zed", "last" => "Z"}}) end)

      assert failed.assigns.owner_error =~ "Couldn't save that patient"
      refute failed.assigns.owner_error =~ "first and last name are required"
      # what the user typed is kept
      assert failed.assigns.owner_form == %{"first" => "Zed", "last" => "Z"}
      assert failed.assigns.owner_modal == :new
    end

    test "POSITIVE CONTROL: a real refusal keeps the validation copy; a valid save saves" do
      other_owner = create_owner!(@other_org, "Boris")
      pet_socket = clinic_socket(@org, %{}, pet_modal: :new, pet_form: %{})

      refused =
        clinic_event(pet_socket, "save_pet", %{"pet" => %{"name" => "Cross", "species" => "feline", "owner_id" => other_owner.id}})

      assert refused.assigns.pet_error =~ "owner must be a patient of this clinic"

      socket = clinic_socket(@org, %{}, owner_modal: :new, owner_form: %{})
      saved = clinic_event(socket, "save_owner", %{"owner" => %{"first" => "Ok", "last" => "Saved"}})
      assert saved.assigns.flash["info"] == "Patient saved."
      assert saved.assigns.owner_modal == nil
    end

    test "update_owner on a failing table writes nothing and is :unavailable, never :not_found; the stored contacts survive" do
      owner = create_owner!(@org, "Edie")
      scope = Reads.tenant_scope(@org)
      {:ok, before} = Reads.get_owner_result(scope, owner.id)

      break_select!("own_patient", "own_marketing_opt_in")
      assert {:error, :unavailable} = quiet(fn -> Reads.update_owner(@org, owner.id, %{"first" => "Edie", "last" => "Owner", "email" => "new@example.test"}) end)

      ddl!("ALTER TABLE own_patient RENAME COLUMN own_marketing_opt_in_renamed TO own_marketing_opt_in")
      {:ok, after_} = Reads.get_owner_result(scope, owner.id)
      assert after_.emails == before.emails
      assert after_.phones == before.phones

      # POSITIVE CONTROL: with the table healthy the same update applies
      assert {:ok, _} = Reads.update_owner(@org, owner.id, %{"first" => "Edie", "last" => "Owner", "email" => "new@example.test"})
    end

    test "update_owner / update_pet with a malformed id are :not_found with no failure logged" do
      log =
        capture_log(fn ->
          assert {:error, :not_found} = Reads.update_owner(@org, "not-a-uuid", %{"first" => "A", "last" => "B"})
          assert {:error, :not_found} = Reads.update_pet(@org, "not-a-uuid", %{"name" => "A"})
          assert {:error, :not_found} = Reads.update_owner(@other_org, Ecto.UUID.generate(), %{"first" => "A", "last" => "B"})
        end)

      refute log =~ "failed"
    end

    test "create_pet / update_pet on a failing table are outage copy" do
      pet = create_pet!()
      break_writes!("pet_pet")

      assert {:error, :unavailable} = quiet(fn -> Reads.create_pet(@org, %{"name" => "Fido", "species" => "canine"}) end)
      assert {:error, :unavailable} = quiet(fn -> Reads.update_pet(@org, pet.id, %{"name" => "Renamed"}) end)

      socket = clinic_socket(@org, %{}, pet_modal: :new, pet_form: %{})
      failed = quiet(fn -> clinic_event(socket, "save_pet", %{"pet" => %{"name" => "Fido", "species" => "canine"}}) end)

      assert failed.assigns.pet_error =~ "Couldn't save that pet"
      refute failed.assigns.pet_error =~ "pet name is required"
    end

    test "POSITIVE CONTROL: a cross-org owner is still refused as a refusal, not an outage" do
      other_owner = create_owner!(@other_org, "Boris")

      assert {:error, refusal} = Reads.create_pet(@org, %{"name" => "CrossPet", "species" => "feline", "owner_id" => other_owner.id})
      refute refusal in [:unavailable, :forbidden]
    end
  end

  # ===========================================================================
  # Operator impersonation console: masked roster fails honestly
  # ===========================================================================

  describe "operator impersonation console" do
    @operator "op-pawchart-p4"

    setup do
      create_owner!(@org, "Olivia", email: "olivia@example.com")
      {:ok, _} = Samen.Web.Operator.Impersonation.open(@operator, :operator_support, @org, "ticket #4404: p4 honest reads")
      :ok
    end

    defp console_load, do: Console.load(%Phoenix.LiveView.Socket{}, @operator, @org)

    defp console_html(socket) do
      socket.assigns
      |> Map.put(:__changed__, %{})
      |> Console.render()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
    end

    test "a failed masked roster is an error state with a retry, not an empty patient table; nothing PII in it" do
      break_select!("own_patient", "own_marketing_opt_in")

      socket = quiet(fn -> console_load() end)
      rendered = console_html(socket)

      assert socket.assigns.impersonating
      assert socket.assigns.patients_error == :unavailable
      assert rendered =~ ~s(id="patients-error")
      assert rendered =~ "Nothing was lost"
      assert rendered =~ "retry_gate"
      refute rendered =~ "patient-row"
      refute rendered =~ "<table"
      refute rendered =~ "Olivia"
      refute rendered =~ "olivia@example.com"
      refute rendered =~ "vt_"
    end

    test "POSITIVE CONTROL: the same console over a healthy table renders the masked roster and no error" do
      socket = console_load()
      rendered = console_html(socket)

      assert socket.assigns.patients_error == nil
      refute rendered =~ "patients-error"
      assert rendered =~ "patient-row"
      assert rendered =~ "••••"
      refute rendered =~ "Olivia"
      refute rendered =~ "vt_"
    end

    test "a failing directory read shows the org id it was given and is reported, never a name it could not look up" do
      break_select!("poo_org", "poo_name")

      log = capture_log(fn -> send(self(), {:socket, console_load()}) end)
      assert_received {:socket, socket}

      assert socket.assigns.org_name == @org
      assert log =~ "pawchart_org_name"
    end
  end

  # ===========================================================================
  # Authorization seam: a failing membership read fails CLOSED and is reported by name
  # ===========================================================================

  describe "authorized-orgs seam" do
    @session_user_key "samen_current_user"

    setup do
      prev = Application.get_env(:pawchart, :auth_required?)
      Application.put_env(:pawchart, :auth_required?, true)

      on_exit(fn ->
        if prev == nil,
          do: Application.delete_env(:pawchart, :auth_required?),
          else: Application.put_env(:pawchart, :auth_required?, prev)
      end)

      :ok
    end

    defp armed_mount do
      Samen.Web.Mount.new(:crm, PawChart.Crm, PawChart.Repo,
        plane: Samen.Web.Plane.tenant(),
        labels: %{
          authn: {:app_env, :pawchart, :auth_required?},
          authorized_orgs: {PawChart.Auth, :authorized_org_ids, []},
          identity_namespace: PawChart.Operator
        }
      )
    end

    defp seed_member!(org_id) do
      user =
        PawChart.Operator.User
        |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: "clinic-p4-#{System.unique_integer([:positive])}"})
        |> Ash.create!(authorize?: false)

      PawChart.Operator.Membership
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: :admin})
      |> Ash.create!(authorize?: false)

      user
    end

    test "a membership read that FAILS resolves no org (closed) and is reported by name; the healthy path resolves the org" do
      org_id = Ecto.UUID.generate()
      user = seed_member!(org_id)
      session = %{@session_user_key => user.id}

      # POSITIVE CONTROL: healthy, the member resolves its own org through the seam
      assert PawChart.Auth.authorized_org_ids(user.id) == [org_id]
      assert CurrentOrg.resolve(armed_mount(), %{}, session) == org_id

      break_select!("pom_membership", "pom_org_id")

      log = capture_log(fn -> send(self(), {:org, CurrentOrg.resolve(armed_mount(), %{"org" => org_id}, session)}) end)
      assert_received {:org, resolved}

      assert resolved == nil
      assert log =~ "current_org_authorized_orgs"
      assert log =~ "Ash.Error"
      refute log =~ user.id
    end

    test "the seam itself raises on a failed read instead of answering 'no orgs'" do
      user = seed_member!(Ecto.UUID.generate())
      break_select!("pom_membership", "pom_org_id")

      assert_raise Ash.Error.Unknown, fn -> PawChart.Auth.authorized_org_ids(user.id) end
    end
  end

  # ===========================================================================
  # Seeds: a failed probe is a failed seed, not a repeated one
  # ===========================================================================

  describe "operator seeds" do
    test "seed/0 is re-runnable: a second run on a seeded database adds nothing" do
      assert :ok = PawChart.OperatorSeeds.seed()
      before = PawChart.Repo.aggregate(PawChart.Operator.Org, :count)
      assert before > 1

      assert :ok = PawChart.OperatorSeeds.seed()
      assert PawChart.Repo.aggregate(PawChart.Operator.Org, :count) == before
    end

    test "a failing 'operator org already seeded?' probe raises instead of answering 'no, seed it again'" do
      assert :ok = PawChart.OperatorSeeds.seed()
      break_select!("poo_org", "poo_id")

      # Every statement on `poo_org` fails with this fault, the fallback create included, so the exception alone
      # cannot tell the probe's failure from the old 'probe said false, create failed' one. The raising frame can:
      # the probe is where it must come from, and nothing past it ran.
      {error, stacktrace} = raised_with_stack(fn -> PawChart.OperatorSeeds.seed() end)

      assert %Ash.Error.Unknown{} = error
      formatted = Exception.format_stacktrace(stacktrace)
      assert formatted =~ "Ash.exists?"
      refute formatted =~ "Ash.create"
      refute formatted =~ "seed_operator_org"
    end

    # Real DDL fault that ONLY the seed's last per-account step hits: the support ticket carries the tenant org id in
    # its custom bag, and nothing else in the seed writes `pqk_ticket`.
    @last_tenant "c1112d00-0000-4000-8000-000000000003"

    test "a seed that fails on its LAST step leaves nothing behind (no marker without its rows), and the re-run completes it" do
      orgs = PawChart.Repo.aggregate(PawChart.Operator.Org, :count)

      ddl!(
        "ALTER TABLE pqk_ticket ADD CONSTRAINT zz_seed_fault CHECK ((pqk_custom->>'requester_org_id') IS DISTINCT FROM '#{@last_tenant}') NOT VALID"
      )

      {error, _stack} = quiet(fn -> raised_with_stack(fn -> PawChart.OperatorSeeds.seed() end) end)
      assert is_exception(error)
      # Old behaviour: the operator org and two whole accounts stayed, and every later run answered :ok "seeded".
      assert PawChart.Repo.aggregate(PawChart.Operator.Org, :count) == orgs

      # POSITIVE CONTROL: with the fault lifted the same call completes the whole book.
      ddl!("ALTER TABLE pqk_ticket DROP CONSTRAINT zz_seed_fault")
      assert :ok = PawChart.OperatorSeeds.seed()
      assert PawChart.Repo.aggregate(PawChart.Operator.Org, :count) == orgs + 4

      %{rows: [[tickets]]} =
        Ecto.Adapters.SQL.query!(PawChart.Repo, "SELECT count(*) FROM pqk_ticket WHERE pqk_custom->>'requester_org_id' = '#{@last_tenant}'", [])

      assert tickets == 1
    end
  end

  # ===========================================================================
  # MCP key auth: a failing key lookup fails closed and is reported, not silent
  # ===========================================================================

  describe "mcp key lookup" do
    test "a key lookup that FAILS is :error (closed) and reported by name; a healthy lookup of an unknown key is silent" do
      alias PawChartWeb.Api.McpKeyResolver

      log = capture_log(fn -> assert :error = McpKeyResolver.resolve_scope("some-unknown-key") end)
      refute log =~ "mcp_key_lookup"

      break_select!("pok_api_key", "pok_token_digest")
      log = capture_log(fn -> assert :error = McpKeyResolver.resolve_scope("some-unknown-key") end)

      assert log =~ "read=pawchart_mcp_key_lookup"
      refute log =~ "some-unknown-key"
    end
  end
end

defmodule Samen.Web.ReadsGuardTest do
  @moduledoc """
  WP6 — the read-failure convention (`Samen.Web.Reads.Guard`): a failed read is distinguishable
  from an empty one, is logged ONCE with the read's name and the org id and NEVER with row data
  (PII, tokens, the exception's interpolated values), emits one telemetry event, leaves honest
  non-exception outcomes (`:not_configured`, `:not_implemented`) alone and keeps an
  authorization denial a denial.

  The PII canary is a REAL vaulted value: the seeded contact's full name, resolved on the
  tenant plane to clear text, then planted in the message of the exception the read raises.
  """
  use Samen.WebTest.DataCase, async: false

  import ExUnit.CaptureLog

  alias Samen.Web.CRM.Reads
  alias Samen.Web.Mount
  alias Samen.Web.Page
  alias Samen.Web.Reads.Guard

  setup do
    seeded = Seeds.seed_all()
    %{org_id: seeded.org_id}
  end

  describe "run/3" do
    test "a value is {:ok, value}; an EMPTY value is an honest empty, not a failure", %{org_id: org_id} do
      assert {:ok, [1, 2]} = Guard.run(:t_values, org_id, fn -> [1, 2] end)
      assert {:ok, []} = Guard.run(:t_empty, org_id, fn -> [] end)
    end

    test "honest non-exception outcomes pass through untouched (not turned into errors)", %{org_id: org_id} do
      assert {:ok, {:error, :not_configured}} = Guard.run(:t_nc, org_id, fn -> {:error, :not_configured} end)
      assert {:ok, {:error, :not_implemented}} = Guard.run(:t_ni, org_id, fn -> {:error, :not_implemented} end)

      log = capture_log(fn -> Guard.run(:t_nc, org_id, fn -> {:error, :not_configured} end) end)
      assert log == ""
    end

    test "a raise is {:error, :unavailable}, logged once with the read name and org id", %{org_id: org_id} do
      log =
        capture_log(fn ->
          assert {:error, :unavailable} = Guard.run(:t_boom, org_id, fn -> raise ArgumentError, "boom" end)
        end)

      assert length(String.split(log, "[Samen.Web.Reads] read failed")) - 1 == 1
      assert log =~ "read=t_boom"
      assert log =~ "org=#{org_id}"
      assert log =~ "cause=ArgumentError"
    end

    test "an exit and a throw are failures too (a total screen must not crash)", %{org_id: org_id} do
      capture_log(fn ->
        assert {:error, :unavailable} = Guard.run(:t_exit, org_id, fn -> exit(:db_gone) end)
        assert {:error, :unavailable} = Guard.run(:t_throw, org_id, fn -> throw(:nope) end)
      end)
    end

    test "an authorization denial stays a denial: {:error, :forbidden}, not logged as an outage", %{org_id: org_id} do
      log =
        capture_log(fn ->
          assert {:error, :forbidden} =
                   Guard.run(:t_denied, org_id, fn -> raise Ash.Error.Forbidden, errors: [] end)
        end)

      assert log == ""
      refute Guard.unavailable?({:error, :forbidden})
      assert Guard.unavailable?({:error, :unavailable})
    end

    test "value/2 is the legacy projection: the value, or the default for ANY error" do
      assert Guard.value({:ok, [1]}, []) == [1]
      assert Guard.value({:error, :unavailable}, []) == []
      assert Guard.value({:error, :forbidden}, :d) == :d
    end
  end

  describe "page/4" do
    test "a page passes through; a failed read is an EMPTY page marked :unavailable", %{org_id: org_id} do
      state = %Samen.Web.ListState{page_size: 7}
      ok = %Page{items: [:a], page_size: 7}

      assert Guard.page(:t_page, org_id, state, fn -> ok end) == ok

      capture_log(fn ->
        failed = Guard.page(:t_page, org_id, state, fn -> raise "down" end)
        assert failed.items == []
        assert failed.error == :unavailable
        assert failed.page_size == 7
        assert Guard.unavailable?(failed)
      end)

      assert Guard.page(:t_page, org_id, state, fn -> raise Ash.Error.Forbidden, errors: [] end).error == nil
    end
  end

  describe "what is logged — never row data" do
    test "the exception message (carrying a RESOLVED VAULTED value) never reaches the log or telemetry", %{org_id: org_id} do
      mount = build_mount(:crm)
      scope = Mount.scope(mount, org_id)
      canary = Seeds.contact_full_name()

      # The value really is vault-routed PII, resolved to clear text on the tenant plane.
      assert {:ok, [person | _]} = Reads.contacts_result(mount, scope)
      assert render_name(person.full_name) =~ canary

      handler = "guard-pii-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:samen, :web, :read, :error],
        fn _event, measurements, metadata, _ -> send(test_pid, {:telemetry, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      log =
        capture_log(fn ->
          assert {:error, :unavailable} =
                   Guard.run(:crm_contacts_for_company, scope, fn ->
                     # An Ash/driver error interpolates the values being processed; model it.
                     raise ArgumentError, "row #{inspect(person)} name=#{canary} token=vt_secret_token_1"
                   end)
        end)

      assert log =~ "read=crm_contacts_for_company"
      assert log =~ "org=#{org_id}"
      refute log =~ canary
      refute log =~ "vt_secret_token_1"
      refute log =~ "email"
      refute log =~ Seeds.contact_email()

      assert_receive {:telemetry, %{count: 1}, metadata}
      assert metadata == %{read: :crm_contacts_for_company, cause: "ArgumentError"}
      refute inspect(metadata) =~ canary
      # The bounded metadata carries no org id (a forbidden metric dimension).
      refute Map.has_key?(metadata, :org_id)
    end

    test "a wrapped Ash error logs module names only, not its (value-bearing) message", %{org_id: org_id} do
      canary = Seeds.contact_full_name()

      error =
        Ash.Error.to_error_class(
          Ash.Error.Unknown.UnknownError.exception(error: "boom #{canary}"),
          []
        )

      log = capture_log(fn -> assert {:error, :unavailable} = Guard.run(:t_ash, org_id, fn -> raise error end) end)
      assert log =~ "Ash.Error.Unknown"
      refute log =~ canary
    end
  end

  describe "the fault seam" do
    test "inject_faults/1 fails exactly the named reads through the real path; clear_faults/0 restores", %{org_id: org_id} do
      inject_read_faults([:t_named])

      capture_log(fn ->
        assert {:error, :unavailable} = Guard.run(:t_named, org_id, fn -> :fine end)
      end)

      assert {:ok, :fine} = Guard.run(:t_other, org_id, fn -> :fine end)

      clear_read_faults()
      assert {:ok, :fine} = Guard.run(:t_named, org_id, fn -> :fine end)
    end
  end

  describe "write/3 (phase 2)" do
    test "the write's own tagged return passes through untouched, logging nothing", %{org_id: org_id} do
      log =
        capture_log(fn ->
          assert :ok = Guard.write(:t_w_ok, org_id, fn -> :ok end)
          assert {:ok, :row} = Guard.write(:t_w_row, org_id, fn -> {:ok, :row} end)
          assert {:error, :not_configured} = Guard.write(:t_w_nc, org_id, fn -> {:error, :not_configured} end)
          assert {:error, :not_found} = Guard.write(:t_w_nf, org_id, fn -> {:error, :not_found} end)
        end)

      assert log == ""
    end

    test "a raise / exit becomes {:error, :unavailable}, logged by name and cause only", %{org_id: org_id} do
      canary = "write-canary-#{System.unique_integer([:positive])}"

      log =
        capture_log(fn ->
          assert {:error, :unavailable} = Guard.write(:t_w_boom, org_id, fn -> raise ArgumentError, canary end)
          assert {:error, :unavailable} = Guard.write(:t_w_exit, org_id, fn -> exit(:db_gone) end)
        end)

      assert log =~ "write failed write=t_w_boom"
      refute log =~ "read failed"
      assert log =~ "cause=ArgumentError"
      refute log =~ canary
    end

    test "a failed write emits its OWN telemetry event, never the read-error one", %{org_id: org_id} do
      test_pid = self()
      handler = "guard-write-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [[:samen, :web, :write, :error], [:samen, :web, :read, :error]],
        fn event, _m, metadata, _ -> send(test_pid, {:telemetry, event, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      capture_log(fn -> Guard.write(:t_w_tele, org_id, fn -> raise ArgumentError, "x" end) end)

      assert_receive {:telemetry, [:samen, :web, :write, :error], %{write: :t_w_tele, cause: "ArgumentError"}}
      refute_receive {:telemetry, [:samen, :web, :read, :error], _}
    end

    test "a RETURNED Unknown / Framework error is an outage; Invalid and Forbidden pass through untouched", %{org_id: org_id} do
      unknown = Ash.Error.to_error_class(Ash.Error.Unknown.UnknownError.exception(error: "boom"), [])
      framework = Ash.Error.to_error_class(Ash.Error.Framework.PendingCodegen.exception(diff: "x"), [])
      invalid = Ash.Error.to_error_class(Ash.Error.Changes.Required.exception(field: :name), [])
      forbidden = Ash.Error.to_error_class(Ash.Error.Forbidden.Policy.exception([]), [])

      assert %Ash.Error.Unknown{} = unknown
      assert %Ash.Error.Framework{} = framework
      assert %Ash.Error.Invalid{} = invalid
      assert %Ash.Error.Forbidden{} = forbidden

      log =
        capture_log(fn ->
          assert {:error, :unavailable} = Guard.write(:t_w_unknown, org_id, fn -> {:error, unknown} end)
          assert {:error, :unavailable} = Guard.write(:t_w_framework, org_id, fn -> {:error, framework} end)
        end)

      assert log =~ "write failed write=t_w_unknown"
      assert log =~ "write failed write=t_w_framework"

      # POSITIVE CONTROL: a real refusal / validation error is NOT an outage and logs nothing.
      silent =
        capture_log(fn ->
          assert {:error, ^invalid} = Guard.write(:t_w_invalid, org_id, fn -> {:error, invalid} end)
          assert {:error, ^forbidden} = Guard.write(:t_w_forbidden, org_id, fn -> {:error, forbidden} end)
        end)

      assert silent == ""
    end

    test "a REAL data-layer failure (the table is gone) is returned as Ash.Error.Unknown by the bare write — and Guard tells it",
         %{org_id: org_id} do
      Application.put_env(:samen_core, :delivery_env, :test)
      on_exit(fn -> Application.delete_env(:samen_core, :delivery_env) end)

      mount = Mount.new(:settings, Samen.WebTest.Operator, Samen.WebTest.Repo)

      scope = %Samen.Scope{
        actor: %{id: Ash.UUID.generate(), org_id: org_id, role: :admin, kind: :tenant, plane: :tenant, verified?: true}
      }

      # Control: the healthy write succeeds, so the failure below is the table, not the call.
      assert {:ok, _invitation, _raw} = Samen.Web.Settings.Invitations.create(mount, scope, "ok-#{org_id}@example.com", "member")

      table = AshPostgres.DataLayer.Info.table(Samen.WebTest.Operator.Invitation)
      # Postgres DDL is transactional: the rename is undone with the sandbox transaction.
      Ecto.Adapters.SQL.query!(Samen.WebTest.Repo, "ALTER TABLE #{table} RENAME TO zz_gone_#{table}")

      # What the bare, non-bang write returns for the outage: a RETURNED error, not a raise.
      bare = fn ->
        Samen.Identity.Invite.revoke(Samen.Web.Settings.Invitations.mods(mount), scope, Ash.UUID.generate())
      end

      assert {:error, %Ash.Error.Unknown{}} = bare.()

      log =
        capture_log(fn ->
          assert {:error, :unavailable} = Samen.Web.Settings.Invitations.revoke(mount, scope, Ash.UUID.generate())
          assert {:error, :unavailable} = Samen.Web.Settings.Invitations.create(mount, scope, "down@example.com", "member")
        end)

      assert log =~ "write failed write=settings_invitation_revoke"
      assert log =~ "write failed write=settings_invitation_create"
      # Module names only — the Postgrex message (relation, query) never reaches the log.
      refute log =~ "zz_gone"
      refute log =~ "SELECT"
    end

    test "a denial stays a denial; the seam fails a named write", %{org_id: org_id} do
      assert {:error, :forbidden} =
               Guard.write(:t_w_denied, org_id, fn -> raise Ash.Error.Forbidden, errors: [] end)

      inject_read_faults([:t_w_named])

      capture_log(fn ->
        assert {:error, :unavailable} = Guard.write(:t_w_named, org_id, fn -> :ok end)
      end)

      clear_read_faults()
      assert :ok = Guard.write(:t_w_named, org_id, fn -> :ok end)
    end
  end

  defp render_name(name) when is_binary(name) do
    case Jason.decode(name) do
      {:ok, %{"first" => f, "last" => l}} -> "#{f} #{l}"
      _ -> name
    end
  end

  defp render_name(%Samen.Type.FullName{first: f, last: l}), do: "#{f} #{l}"
  defp render_name(other), do: inspect(other)
end

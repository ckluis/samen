defmodule Samen.Web.FormSubmitOutageTest do
  @moduledoc """
  `Samen.Web.Reads.Guard.submit_form/4` (cookbook Recipe 11) and the framework form submits that adopt it: a form submit
  whose WRITE failed is not a validation error. An outage (`Ash.Error.Unknown` on the form's changeset) is value-free
  "couldn't save — nothing was saved, try again"; an `Ash.Error.Forbidden` is denial copy; a real refusal keeps its
  field errors; nothing typed is lost. Every failure here is REAL — a `CHECK (false) NOT VALID` constraint on the table
  inside the sandbox transaction — and paired with a positive control.
  """
  use Samen.WebTest.DataCase, async: false

  import ExUnit.CaptureLog

  alias Samen.Web.CRM.ContactsLive
  alias Samen.Web.Reads.Guard
  alias Samen.WebTest.Crm.Person

  defp ddl!(sql), do: Ecto.Adapters.SQL.query!(Samen.WebTest.Repo, sql, [])

  defp break_writes!(resource),
    do: ddl!("ALTER TABLE #{AshPostgres.DataLayer.Info.table(resource)} ADD CONSTRAINT zz_submit_broken CHECK (false) NOT VALID")

  defp person_form(org_id, opts \\ []) do
    Person |> AshPhoenix.Form.for_create(:create, [scope: Samen.Scope.new(%{org_id: org_id, role: :admin, id: Ash.UUID.generate()})] ++ opts)
  end

  defp valid_params(org_id), do: %{"org_id" => org_id, "display_name" => "Nova Quill"}

  describe "Guard.submit_form/4" do
    test "a saved form is {:ok, record}; a validation refusal stays {:error, form} with its field errors" do
      org_id = Ash.UUID.generate()

      assert {:ok, %Person{}} = Guard.submit_form(:p5_submit, org_id, person_form(org_id), valid_params(org_id))

      assert {:error, %AshPhoenix.Form{} = form} =
               Guard.submit_form(:p5_submit, org_id, person_form(org_id), %{"org_id" => org_id, "company_id" => "not-a-uuid"})

      assert form.source.errors != []
    end

    test "a write that fails in the data layer is {:error, :unavailable} (reported by name, value-free), never field errors" do
      org_id = Ash.UUID.generate()
      break_writes!(Person)

      log =
        capture_log(fn ->
          send(self(), {:res, Guard.submit_form(:p5_submit, org_id, person_form(org_id), valid_params(org_id))})
        end)

      assert_received {:res, {:error, :unavailable}}
      assert log =~ "write failed write=p5_submit"
      refute log =~ "Nova"
    end

    test "an authorization denial is {:error, :forbidden} (denial copy), not field errors and not an outage" do
      org_id = Ash.UUID.generate()
      # no scope/actor: the OrgScope policy denies the create
      form = Person |> AshPhoenix.Form.for_create(:create)

      log = capture_log(fn -> send(self(), {:res, Guard.submit_form(:p5_submit, org_id, form, valid_params(org_id))}) end)
      assert_received {:res, {:error, :forbidden}}
      refute log =~ "write failed"
    end

    test "write_copy/2: outage copy says nothing was saved; denial copy is not 'try again'" do
      assert Guard.write_copy(:unavailable, "save that contact") =~ "Nothing was changed — try again"
      assert Guard.write_copy(:forbidden, "save that contact") == "You don't have permission to save that contact."
    end
  end

  describe "ContactsLive save_new (a framework form submit)" do
    defp mount_socket(org_id) do
      %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
      |> Phoenix.Component.assign(:samen_mount, build_mount(:crm, []))
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Phoenix.Component.assign(:return_to, nil)
      |> ContactsLive.load(org_id)
      |> then(fn s ->
        {:noreply, s} = ContactsLive.handle_event("new_contact", %{}, s)
        s
      end)
    end

    defp save(socket, params) do
      {:noreply, socket} = ContactsLive.handle_event("save_new", %{"form" => params}, socket)
      socket
    end

    defp person_count(org_id) do
      Person |> Ash.Query.ensure_selected([:org_id]) |> Ash.read!(authorize?: false) |> Enum.count(&(&1.org_id == org_id))
    end

    test "an outage on the write is a flash 'couldn't save', not a field error; the modal stays open; the DB is unchanged" do
      org_id = Ash.UUID.generate()
      socket = mount_socket(org_id)

      # POSITIVE CONTROL: with the table healthy the same submit saves
      saved = save(socket, %{"display_name" => "Healthy Hana"})
      refute saved.assigns.show_new
      assert person_count(org_id) == 1

      break_writes!(Person)

      failed = ExUnit.CaptureLog.with_log(fn -> save(socket, %{"display_name" => "Doomed Dan"}) end) |> elem(0)

      assert failed.assigns.show_new
      assert failed.assigns.flash["error"] == "Couldn't save that contact right now. Nothing was changed — try again."
      refute inspect(failed.assigns.flash) =~ "Doomed"
      # the form is the one the user was typing in: no manufactured validation errors
      assert AshPhoenix.Form.errors(failed.assigns.new_form.source) == []
      assert person_count(org_id) == 1
    end

    test "a real validation refusal still renders field errors and no outage flash" do
      org_id = Ash.UUID.generate()
      refused = save(mount_socket(org_id), %{"display_name" => "Half", "company_id" => "not-a-uuid"})

      assert refused.assigns.show_new
      assert refused.assigns.flash == %{}
      assert AshPhoenix.Form.errors(refused.assigns.new_form.source) != []
    end
  end

  describe "adoption" do
    # Source scan (the lint reads text only): every framework form submit goes through Guard.submit_form/4, so none can
    # show an outage as field errors. A new `AshPhoenix.Form.submit(` anywhere under samen_web/lib fails here.
    test "no framework LiveView calls AshPhoenix.Form.submit/2 directly; the scan sees the tree and the adopters" do
      root = Path.expand("../../../lib", __DIR__)
      files = Path.wildcard(Path.join(root, "**/*.ex"))
      assert length(files) > 200

      direct = for f <- files, File.read!(f) =~ "AshPhoenix.Form.submit(", do: Path.relative_to(f, root)
      assert direct == ["samen/web/reads/guard.ex"]

      adopters = for f <- files, File.read!(f) =~ "Guard.submit_form(", do: f
      assert length(adopters) >= 16
    end
  end
end

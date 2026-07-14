defmodule Samen.Web.AnalyticsChokePointsTest do
  @moduledoc """
  WS-B / Phase B7 — AC-G12-4 (I/X): the framework CHOKE POINTS emit the seed product
  events through a REAL flow, so verticals inherit emission at 0 LOC. Each test drives a
  real framework surface (the session controller, the shared list-filter search path, the
  CRM create path) and asserts EXACTLY the expected `pae` row(s) LAND in the ledger.

  The ledger here is the samen_web test host's own `Samen.WebTest.Analytics.ProductEvent`
  (`wan`) — the same `Samen.Scopes.Analytics` blueprint demo mounts, wired as the framework
  emit target for the duration of each test (as a real host does once in config). With that
  config ABSENT `track/1` is inert; wiring it here proves the choke point genuinely reaches
  the write.

  Best-effort is proven end-to-end: with a POISONED emit target (a resource whose create
  raises) the SAME flows still complete their primary write — a failing tracker never
  aborts the action that fired it (the `Engine.emit/2` / `mov` posture, ADR-021 §2).

    * `session.signed_in`  — driven through `Samen.Web.SessionController.put_current_org/2`.
    * `search.used`        — driven through `Samen.Web.ListLive.handle_list_event("filter")`
      on the real list mixin fixture (0-LOC inheritance); carries the bounded SURFACE +
      result count, NEVER the query text.
    * `record.created` + `first_run.completed` — driven through the CRM
      `Samen.Web.CRM.ContactsLive` create path; the FIRST create in an empty org emits the
      empty→non-empty `first_run.completed` too, a later create does not.
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  require Ash.Query

  alias Samen.Web.CRM.ContactsLive
  alias Samen.Web.ListLive
  alias Samen.Web.SessionController
  alias Samen.WebTest.Analytics.ProductEvent
  alias Samen.WebTest.ListFixture

  setup do
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)

    Application.put_env(:samen_core, Samen.Analytics,
      product_event_resource: ProductEvent
    )

    on_exit(fn ->
      Application.delete_env(:samen_core, Samen.Analytics)
    end)

    :ok
  end

  # -- ledger helpers ------------------------------------------------------------

  defp events(org_id) do
    ProductEvent
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.ensure_selected([:org_id, :event_name, :event_kind, :entity_ref, :props, :occurred_at])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp names(org_id), do: org_id |> events() |> Enum.map(& &1.event_name)

  # -- session.signed_in ---------------------------------------------------------

  defp session_conn do
    opts = Plug.Session.init(store: :cookie, key: "_t", signing_salt: "s", encryption_salt: "e")

    conn(:get, "/")
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(opts)
    |> fetch_session()
  end

  test "session.signed_in — the session controller choke point lands one pae row" do
    org_id = Ash.UUID.generate()

    conn = SessionController.put_current_org(session_conn(), %{"org_id" => org_id})

    # The PRIMARY write happened (the current-org session cookie).
    assert get_session(conn, Samen.Web.CurrentOrg.session_key()) == org_id

    assert [row] = events(org_id)
    assert row.event_name == :"session.signed_in"
    assert row.event_kind == :session
    assert row.org_id == org_id
  end

  # -- search.used ---------------------------------------------------------------

  defp create_person(org_id, display_name) do
    [first, last] = String.split(display_name, " ", parts: 2)

    Samen.WebTest.Crm.Person
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        display_name: display_name,
        job_title: "Broker",
        full_name: %Samen.Type.FullName{first: first, last: last}
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp list_socket(org_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:crm))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> ListFixture.ContactsLive.load(org_id)
  end

  defp filter(socket, q) do
    {:noreply, socket} = ListLive.handle_list_event("filter", %{"filter" => q}, socket)
    socket
  end

  test "search.used — the list-mixin filter choke point lands a bounded pae row (surface + count, no query text)" do
    org_id = Ash.UUID.generate()
    _ = create_person(org_id, "Nova Quillwright")
    _ = create_person(org_id, "Bram Ashfield")

    socket = list_socket(org_id)
    # A real filter query narrows the (bounded) read AND fires search.used.
    socket = filter(socket, "Nova")

    # The PRIMARY effect (the narrowed read) happened.
    assert Enum.map(socket.assigns.page.items, & &1.display_name) == ["Nova Quillwright"]

    assert [row] = events(org_id)
    assert row.event_name == :"search.used"
    assert row.event_kind == :search
    # Bounded surface (the mount kind) + an integer result count — NEVER the query text.
    assert row.props["surface"] == "crm"
    assert row.props["result_count"] == 1
    refute row.props |> Map.values() |> Enum.any?(&(&1 == "Nova"))
  end

  test "search.used — a BLANK filter (clear-search) emits nothing" do
    org_id = Ash.UUID.generate()
    _ = create_person(org_id, "Nova Quillwright")

    list_socket(org_id) |> filter("")

    assert events(org_id) == []
  end

  # -- record.created + first_run.completed --------------------------------------

  defp crm_socket(org_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:crm))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> ContactsLive.load(org_id)
  end

  defp save_contact(socket, name) do
    [first, last] = String.split(name, " ", parts: 2)

    {:noreply, socket} =
      ContactsLive.handle_event(
        "save_new",
        %{"form" => %{"full_name" => %{"first" => first, "last" => last}, "display_name" => name}},
        socket
      )

    socket
  end

  defp person_count(org_id) do
    Samen.WebTest.Crm.Person
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == org_id))
  end

  test "record.created + first_run.completed — the CRM create choke point lands both on the FIRST create" do
    org_id = Ash.UUID.generate()

    socket = crm_socket(org_id) |> save_contact("Nova Quillwright")

    # The PRIMARY write landed.
    refute socket.assigns.show_new
    assert person_count(org_id) == 1

    rows = events(org_id)
    assert Enum.map(rows, & &1.event_name) |> Enum.sort() ==
             Enum.sort([:"record.created", :"first_run.completed"])

    created = Enum.find(rows, &(&1.event_name == :"record.created"))
    assert created.event_kind == :record
    # Bounded resource label (module last segment), never a field value.
    assert created.props["resource"] == "person"
    # The created row's opaque id rides as entity_ref.
    [person] = socket.assigns.page.items
    assert created.entity_ref == person.id
  end

  test "record.created only (NO first_run.completed) on a SECOND create — the transition fires once" do
    org_id = Ash.UUID.generate()
    # Seed a pre-existing row so the org is NOT empty (past its first-run).
    _ = create_person(org_id, "Bram Ashfield")

    crm_socket(org_id) |> save_contact("Nova Quillwright")

    # Only record.created — the empty→non-empty transition already happened.
    assert names(org_id) == [:"record.created"]
  end

  # -- best-effort (a failing tracker never aborts the primary write) ------------

  test "BEST-EFFORT — with the emit target POISONED, every choke point's PRIMARY write still lands" do
    # Point the emitter at a resource that raises on create: the ledger is "down".
    Application.put_env(:samen_core, Samen.Analytics, product_event_resource: __MODULE__.Unwritable)

    # 1) session controller — the cookie is still written.
    org_id = Ash.UUID.generate()
    conn = SessionController.put_current_org(session_conn(), %{"org_id" => org_id})
    assert get_session(conn, Samen.Web.CurrentOrg.session_key()) == org_id

    # 2) list filter — the narrowed read still runs.
    _ = create_person(org_id, "Nova Quillwright")
    socket = list_socket(org_id) |> filter("Nova")
    assert Enum.map(socket.assigns.page.items, & &1.display_name) == ["Nova Quillwright"]

    # 3) CRM create — the person is still persisted.
    crm_socket(org_id) |> save_contact("Bram Ashfield")
    assert person_count(org_id) == 2
  end

  # A resource module `track/1` will try to `Ash.Changeset.for_create(:append, ...)` against.
  # It is NOT a valid Ash resource, so the changeset build raises — `track/1`'s rescue belt
  # swallows it and returns an error tuple, never propagating into the caller.
  defmodule Unwritable do
    def spark_dsl_config, do: raise("ledger down")
  end
end

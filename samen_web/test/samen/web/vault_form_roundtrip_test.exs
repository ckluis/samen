defmodule Samen.Web.VaultFormRoundtripTest do
  @moduledoc """
  ADR-052 §2.1 item 3 (gate finding) — a vault-routed field's IN-FLIGHT value is held as a
  redacting `%Samen.Pii.Plaintext{}` between cast and the vault write, so
  `AshPhoenix.Form.value/2` (and therefore `@form[:field].value`) returns the WRAPPER after
  a `validate`. Every form component that renders a vaulted field must still echo the
  caller's OWN pending input back — otherwise a re-render after a phx-change (or a failed
  submit) blanks the input, the browser resubmits the blank, and the vault stores a
  corrupted value (the user's last name silently erased).

  These tests emulate the browser: render after validate, SCRAPE the input values the DOM
  now carries, and submit exactly those — the round trip a real user performs.

    * composite (`Samen.Type.FullName` via `Samen.Web.CRM.Live.full_name_field/1`): the
      Contact EDIT modal (a phx-change that touched only `job_title`) and the Contacts
      CREATE modal (a failed submit, then a corrected resubmit);
    * scalar (`Samen.UI.form_field/1`, text + textarea): the wrapped value renders as the
      value itself — never `**redacted**`, never the struct name.

  Positive control (anti-tautology): the SAME scrape on the first, pre-validate render finds
  the stored name — so a blank after validate is a real regression, not a scrape miss.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.CRM.{ContactLive, ContactsLive}

  @first ~s(name="form[full_name][first]")
  @last ~s(name="form[full_name][last]")

  defp socket_for(module, load_args) do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, build_mount(:crm, []))
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Phoenix.Component.assign(:return_to, nil)

    apply(module, :load, [socket | load_args])
  end

  defp event(module, socket, name, params) do
    {:noreply, socket} = module.handle_event(name, params, socket)
    socket
  end

  # The value the browser shows for the input carrying `name_attr` ("" when the
  # re-render dropped the value attribute — morphdom then clears an unfocused input).
  defp input_value(html, name_attr) do
    [tag] = Regex.run(~r/<input[^>]*#{Regex.escape(name_attr)}[^>]*>/, html)

    case Regex.run(~r/\bvalue="([^"]*)"/, tag) do
      [_, v] -> v
      nil -> ""
    end
  end

  defp scraped_name(html), do: %{"first" => input_value(html, @first), "last" => input_value(html, @last)}

  test "Contact EDIT: a phx-change re-render keeps the vaulted name; the browser's resubmit preserves it" do
    seeded = Seeds.seed_all()
    org_id = seeded.org_id
    contact_id = seeded.crm.person.id

    socket = socket_for(ContactLive, [org_id, contact_id])
    socket = event(ContactLive, socket, "edit_contact", %{})
    html0 = render_html(ContactLive, socket.assigns)

    # Positive control: the first render (stored, plane-resolved) value scrapes clear.
    assert scraped_name(html0) == %{"first" => "Aurelia", "last" => "Sentinelson"}

    # The user edits ONLY job_title; the browser sends the WHOLE form on phx-change.
    socket =
      event(ContactLive, socket, "validate_edit", %{
        "form" => %{"full_name" => scraped_name(html0), "job_title" => "Ops Lead"}
      })

    html1 = render_html(ContactLive, socket.assigns)
    assert scraped_name(html1) == %{"first" => "Aurelia", "last" => "Sentinelson"}
    refute html1 =~ "redacted"
    refute html1 =~ "Samen.Pii.Plaintext"

    # Submit what the DOM now holds — the user never retyped the name.
    socket =
      event(ContactLive, socket, "save_edit", %{
        "form" => %{"full_name" => scraped_name(html1), "job_title" => "Ops Lead"}
      })

    refute socket.assigns.show_edit
    rendered = render_html(ContactLive, socket.assigns)
    assert rendered =~ "Sentinelson"
    assert rendered =~ "Ops Lead"
  end

  test "Contacts CREATE: a failed submit re-renders the typed name; the corrected resubmit stores it" do
    org_id = Ash.UUID.generate()
    socket = socket_for(ContactsLive, [org_id]) |> then(&event(ContactsLive, &1, "new_contact", %{}))

    typed = %{"first" => "Nova", "last" => "Quillwright"}

    socket =
      event(ContactsLive, socket, "save_new", %{
        "form" => %{"full_name" => typed, "display_name" => "N Q", "company_id" => "not-a-uuid"}
      })

    assert socket.assigns.show_new
    html1 = render_html(ContactsLive, socket.assigns)
    assert html1 =~ "field-error"
    assert scraped_name(html1) == typed
    refute html1 =~ "redacted"

    socket =
      event(ContactsLive, socket, "save_new", %{
        "form" => %{"full_name" => scraped_name(html1), "display_name" => "N Q"}
      })

    refute socket.assigns.show_new
    [person] = socket.assigns.page.items
    assert render_html(ContactsLive, socket.assigns) =~ "Nova Quillwright"
    # Still vaulted at rest (the fix opens the value for the form only, not the write path).
    raw = Ash.get!(Samen.WebTest.Crm.Person, person.id, authorize?: false)
    refute inspect(raw.full_name) =~ "Quillwright"
  end

  test "scalar kit form_field renders a wrapped in-flight value as the value itself (text + textarea)" do
    wrapped = Samen.Pii.Plaintext.wrap(~s(a&b@example.test))

    for type <- ["text", "textarea"] do
      field = %Phoenix.HTML.FormField{
        id: "f_email",
        name: "f[email]",
        field: :email,
        errors: [],
        form: Phoenix.Component.to_form(%{}, as: :f),
        value: wrapped
      }

      html =
        %{field: field, label: "Email", type: type, rest: %{}, prompt: nil, options: [], __changed__: nil}
        |> Samen.UI.form_field()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      # HTML-escaped by the inner value's own impl — the value, not the wrapper.
      assert html =~ "a&amp;b@example.test"
      refute html =~ "redacted"
      refute html =~ "Plaintext"
    end
  end
end

defmodule Samen.UI.FormComponentsTest do
  @moduledoc """
  Unit tests for the A2 form/modal/empty-state primitives (ADR-016 §2/§5, WS-A design
  §1.1/§3.1; AC-G1-2 component half, AC-G1-9, AC-G5-1 component half):
  `simple_form/1`, `form_field/1` (inline errors + a11y + the MASKED read-only
  branch), `modal/1` (role=dialog, focus trap, escape/click-away), `delete_confirm/1`
  (data-confirm interlock), and `empty_state/1` (title/body/icon + `:actions`/`:sample`).

  The load-bearing red path lives here: a `%Samen.Masked{}` field value renders
  `••••` DISABLED with **no `name` attribute** — it cannot submit, and the vault
  token never reaches the DOM.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2]

  @token "vt_SECRET_TOKEN_should_never_render"
  @masked %Samen.Masked{token: @token, label: :pii_name}

  defp raw_slot(html) do
    [%{inner_block: fn _, _ -> Phoenix.HTML.raw(html) end}]
  end

  defp let_slot(fun) do
    [%{inner_block: fn _, arg -> Phoenix.HTML.raw(fun.(arg)) end}]
  end

  defp field(params, name, opts \\ []) do
    to_form(params, Keyword.merge([as: "person"], opts))[name]
  end

  defp render_field(assigns) do
    render_component(&Samen.UI.form_field/1, assigns)
  end

  # ---------------------------------------------------------------------------
  # simple_form
  # ---------------------------------------------------------------------------

  test "simple_form renders a <form> with the phx bindings and hands the form to :let" do
    html =
      render_component(&Samen.UI.simple_form/1, %{
        for: to_form(%{"name" => "Acme"}, as: "company"),
        id: "company-form",
        "phx-submit": "save",
        "phx-change": "validate",
        inner_block: let_slot(fn f -> ~s(<span id="got-form">#{f[:name].name}=#{f[:name].value}</span>) end),
        actions: raw_slot(~s(<button type="submit" id="save-btn">Save</button>))
      })

    assert html =~ "<form"
    assert html =~ ~s(id="company-form")
    assert html =~ ~s(phx-submit="save")
    assert html =~ ~s(phx-change="validate")
    assert html =~ ~s(class="simple-form")
    # The :let received the real form (field name + value round-trip).
    assert html =~ ~s(<span id="got-form">company[name]=Acme</span>)
    # The :actions slot rendered in the form-actions row.
    assert html =~ ~s(class="form-actions")
    assert html =~ ~s(id="save-btn")
  end

  test "simple_form is AshPhoenix.Form-backed: an invalid validate renders inline field errors" do
    form =
      Samen.WebTest.Crm.Company
      |> AshPhoenix.Form.for_create(:create)
      |> AshPhoenix.Form.validate(%{"name" => ""})
      |> to_form([])

    html =
      render_component(&Samen.UI.simple_form/1, %{
        for: form,
        id: "company-form",
        inner_block:
          let_slot(fn f ->
            render_field(%{field: f[:name], label: "Name"})
          end)
      })

    assert html =~ ~s(class="field-error")
    assert html =~ "is required"
    assert html =~ ~s(aria-invalid="true")
  end

  # ---------------------------------------------------------------------------
  # form_field — inputs, labels, a11y (AC-G1-9)
  # ---------------------------------------------------------------------------

  test "form_field renders a labelled text input wired by for/id, with name + value" do
    html = render_field(%{field: field(%{"job_title" => "Broker"}, :job_title), label: "Job title"})

    assert html =~ ~s(<label for="person_job_title")
    assert html =~ "Job title"
    assert html =~ ~s(id="person_job_title")
    assert html =~ ~s(name="person[job_title]")
    assert html =~ ~s(value="Broker")
    assert html =~ ~s(type="text")
    # No errors → no error block, no aria-invalid.
    refute html =~ "field-error"
    refute html =~ "aria-invalid"
    refute html =~ "aria-describedby"
  end

  test "form_field renders inline errors with aria-invalid + aria-describedby (AC-G1-2/G1-9)" do
    f = field(%{"name" => ""}, :name, as: "company", errors: [name: {"is required", []}])
    html = render_field(%{field: f, label: "Name"})

    assert html =~ ~s(class="field field-invalid")
    assert html =~ ~s(aria-invalid="true")
    assert html =~ ~s(aria-describedby="company_name-errors")
    assert html =~ ~s(id="company_name-errors")
    assert html =~ ~s(class="field-error")
    assert html =~ "is required"
  end

  test "form_field interpolates %{var} error opts" do
    f = field(%{"name" => "ab"}, :name, errors: [name: {"should be at least %{count} characters", [count: 3]}])
    html = render_field(%{field: f, label: "Name"})

    assert html =~ "should be at least 3 characters"
  end

  test "form_field type=select renders prompt + options with the current value selected" do
    f = field(%{"industry" => "Freight"}, :industry)

    html =
      render_field(%{
        field: f,
        label: "Industry",
        type: "select",
        prompt: "Pick one",
        options: ["Freight", "Veterinary"]
      })

    assert html =~ "<select"
    assert html =~ ~s(name="person[industry]")
    assert html =~ ~s(<option value="">Pick one</option>)
    assert html =~ ~s(<option selected value="Freight">Freight</option>)
    assert html =~ ~s(<option value="Veterinary">Veterinary</option>)
  end

  test "form_field type=textarea renders the value as content" do
    html = render_field(%{field: field(%{"notes" => "Line one"}, :notes), label: "Notes", type: "textarea"})

    assert html =~ "<textarea"
    assert html =~ ~s(name="person[notes]")
    assert html =~ "Line one"
  end

  # ---------------------------------------------------------------------------
  # form_field — THE MASKED BRANCH (MC-1 render half; the A2 red path)
  # ---------------------------------------------------------------------------

  test "MASKED: a %Masked{} field value renders •••• read-only with NO name attr and NO token" do
    html = render_field(%{field: field(%{"full_name" => @masked}, :full_name), label: "Full name"})

    # Read-only masked placeholder…
    assert html =~ ~s(class="field field-masked")
    assert html =~ ~s(value="••••")
    assert html =~ "disabled"
    assert html =~ "readonly"
    assert html =~ "data-masked"
    assert html =~ ~s(aria-disabled="true")
    # …that CANNOT submit: no name attribute anywhere in the masked render…
    refute html =~ "name="
    # …and the vault token NEVER reaches the DOM.
    refute html =~ @token
    refute html =~ "vt_"
  end

  test "MASKED red path: the requested type cannot re-open an editable surface (textarea/select stay masked)" do
    for type <- ["textarea", "select"] do
      html =
        render_field(%{
          field: field(%{"full_name" => @masked}, :full_name),
          label: "Full name",
          type: type,
          options: ["a", "b"]
        })

      # The masked branch wins regardless of type — no editable element, no name, no token.
      refute html =~ "<textarea"
      refute html =~ "<select"
      refute html =~ "name="
      refute html =~ @token
      assert html =~ ~s(value="••••")
      assert html =~ "disabled"
    end
  end

  # ---------------------------------------------------------------------------
  # modal (role=dialog + focus trap + escape/click-away — AC-G1-9)
  # ---------------------------------------------------------------------------

  defp render_modal(extra \\ %{}) do
    render_component(
      &Samen.UI.modal/1,
      Map.merge(
        %{
          id: "test-modal",
          title: "New company",
          on_cancel: "close_modal",
          inner_block: raw_slot(~s(<p id="modal-body">Body</p>))
        },
        extra
      )
    )
  end

  test "modal renders role=dialog with aria-modal + aria-labelledby wired to the title" do
    html = render_modal()

    assert html =~ ~s(role="dialog")
    assert html =~ ~s(aria-modal="true")
    assert html =~ ~s(aria-labelledby="test-modal-title")
    assert html =~ ~s(id="test-modal-title")
    assert html =~ "New company"
    assert html =~ ~s(id="modal-body")
  end

  test "modal traps focus (focus_wrap) and closes on escape, click-away, and the ✕ button" do
    html = render_modal()

    # Focus trap: Phoenix.Component.focus_wrap with its guard anchors.
    assert html =~ ~s(phx-hook="Phoenix.FocusWrap")
    assert html =~ ~s(id="test-modal-content")
    # Escape (window keydown), click-away, and the ✕ all fire on_cancel.
    assert html =~ ~s(phx-window-keydown="close_modal")
    assert html =~ ~s(phx-key="escape")
    assert html =~ ~s(phx-click-away="close_modal")
    assert html =~ ~s(phx-click="close_modal")
    assert html =~ ~s(aria-label="Close")
  end

  test "modal without a title omits aria-labelledby (no dangling reference)" do
    html = render_modal(%{title: nil})

    refute html =~ "aria-labelledby"
    refute html =~ ~s(id="test-modal-title")
  end

  # ---------------------------------------------------------------------------
  # delete_confirm (the destructive-action interlock)
  # ---------------------------------------------------------------------------

  test "delete_confirm renders a data-confirm danger button passing phx-click/phx-value through" do
    html =
      render_component(&Samen.UI.delete_confirm/1, %{
        "phx-click": "delete",
        "phx-value-id": "row-9"
      })

    assert html =~ ~s(type="button")
    assert html =~ ~s(class="btn danger")
    assert html =~ ~s(data-confirm="Delete this record? This cannot be undone.")
    assert html =~ ~s(phx-click="delete")
    assert html =~ ~s(phx-value-id="row-9")
    assert html =~ "Delete"
  end

  test "delete_confirm takes a custom message + label / inner block" do
    html =
      render_component(&Samen.UI.delete_confirm/1, %{
        message: "Remove this invoice?",
        label: "Remove"
      })

    assert html =~ ~s(data-confirm="Remove this invoice?")
    assert html =~ "Remove"

    slotted =
      render_component(&Samen.UI.delete_confirm/1, %{
        inner_block: raw_slot(~s(<span id="custom-label">Destroy</span>))
      })

    assert slotted =~ ~s(id="custom-label")
  end

  # ---------------------------------------------------------------------------
  # empty_state (AC-G5-1 component half)
  # ---------------------------------------------------------------------------

  test "empty_state renders icon + title + body with the :actions and :sample slots" do
    html =
      render_component(&Samen.UI.empty_state/1, %{
        title: "No contacts yet",
        body: "Add your first contact to get started.",
        icon: "👥",
        actions: raw_slot(~s(<button id="cta">New contact</button>)),
        sample: raw_slot(~s(<button id="sample">Load sample data</button>))
      })

    assert html =~ ~s(class="card empty-state")
    assert html =~ "No contacts yet"
    assert html =~ "Add your first contact to get started."
    # The icon is decorative — hidden from the accessibility tree.
    assert html =~ ~s(<div class="empty-icon" aria-hidden="true")
    assert html =~ "👥"
    assert html =~ ~s(class="empty-actions")
    assert html =~ ~s(id="cta")
    assert html =~ ~s(class="empty-sample")
    assert html =~ ~s(id="sample")
  end

  test "empty_state renders minimal (title only) without empty slot/body/icon scaffolding" do
    html = render_component(&Samen.UI.empty_state/1, %{title: "Nothing here yet."})

    assert html =~ "Nothing here yet."
    refute html =~ "empty-icon"
    refute html =~ "empty-body"
    refute html =~ "empty-actions"
    refute html =~ "empty-sample"
  end
end

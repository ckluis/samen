defmodule Samen.UI.Form do
  @moduledoc """
  Form primitives of the `Samen.UI` kit (ADR-016 §2): the `simple_form/1` wrapper
  and the `form_field/1` field (with its LOAD-BEARING `%Samen.Masked{}` render half,
  MC-1). Split out of the `Samen.UI` god-module (behaviour-identical). `simple_form/1`
  uses `<.form>` from `use Phoenix.Component`; no sibling-kit imports are needed.
  `Samen.UI` re-exports each via `defdelegate`.
  """
  use Phoenix.Component

  @doc """
  The kit form wrapper (ADR-016 §2): an `AshPhoenix.Form`-backed `<form>` (any
  `Phoenix.HTML.FormData` source works — `AshPhoenix.Form` is the framework
  convention; A3's CRUD wiring hands one in). The inner block receives the form via
  `:let={f}`; compose fields with `form_field/1` (which owns inline errors). The
  `:actions` slot renders the submit/cancel row.

  ## Masking (LOAD-BEARING — the write-form half of MC-1)

  `simple_form` is a dumb container: it never reads, echoes, or serializes a field
  VALUE itself — values render only through `form_field/1`, whose `%Samen.Masked{}`
  branch emits a read-only `••••` placeholder with NO `name` attribute, so a vaulted
  field on the operator/impersonation plane can never round-trip plaintext (or the
  vault token) through this form. The Ash-write-path rejection (Invariant L1) lands
  in A3; this component guarantees the RENDER half by construction.
  """
  attr :for, :any, required: true, doc: "an AshPhoenix.Form / %Phoenix.HTML.Form{} / FormData source"
  attr :id, :string, default: nil
  attr :as, :any, default: nil
  attr :rest, :global,
    include: ~w(action method autocomplete novalidate phx-submit phx-change phx-target phx-auto-recover)

  slot :inner_block, required: true
  slot :actions, doc: "the submit/cancel row (receives the form via :let)"

  def simple_form(assigns) do
    # Re-name the form only when `as` is SET — passing `as: nil` through would reset
    # the name a caller already baked in via `to_form(..., as: ...)`.
    assigns =
      case assigns.as do
        nil -> assigns
        as -> assign(assigns, :for, to_form(assigns.for, as: as))
      end

    ~H"""
    <.form :let={f} for={@for} id={@id} class="simple-form" {@rest}>
      {render_slot(@inner_block, f)}
      <div :if={@actions != []} class="form-actions" style="display:flex;align-items:center;gap:8px;margin-top:14px">
        {render_slot(@actions, f)}
      </div>
    </.form>
    """
  end

  @doc """
  One labelled form field (ADR-016 §2, AC-G1-9): label + input/select/textarea +
  inline errors. `field` is the `%Phoenix.HTML.FormField{}` from `simple_form/1`'s
  `:let={f}` (`f[:name]`). Errors come from `field.errors` (populated by
  `AshPhoenix.Form.validate/submit`) and render in a `field-errors` block wired to
  the input via `aria-describedby` + `aria-invalid` — the AC-G1-2 inline-error path.

  ## Masking (LOAD-BEARING — MC-1's render half)

  A field whose CURRENT VALUE is a `%Samen.Masked{}` (a vaulted attribute resolved on
  the operator/impersonation plane) renders a DISABLED, read-only input whose literal
  value is `••••` and which carries **no `name` attribute** — it cannot submit
  anything, so no operator-authored plaintext (and never the vault token) can enter
  the params through this field. The component never unwraps, stringifies, or
  inspects the `%Masked{}`; the requested `type` (textarea/select included) is
  ignored on the masked branch — there is no editable-masked variant by construction.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, default: nil

  attr :type, :string,
    default: "text",
    values: ~w(text email tel url password number date time datetime-local search hidden textarea select)

  attr :options, :list, default: [], doc: "select options (`options_for_select/2` shapes)"
  attr :prompt, :string, default: nil, doc: "select prompt option"
  attr :rest, :global, include: ~w(placeholder autocomplete rows cols min max step required disabled readonly phx-debounce)

  # MASKED branch (MC-1 render half): value is %Samen.Masked{} → a read-only ••••
  # placeholder with NO name attr (nothing can submit) and NO token in the DOM. The
  # match happens HERE, on the struct — the value itself is never rendered or unwrapped.
  def form_field(%{field: %Phoenix.HTML.FormField{value: %Samen.Masked{}}} = assigns) do
    ~H"""
    <div class="field field-masked" style="display:flex;flex-direction:column;gap:4px;margin-bottom:10px">
      <label :if={@label} for={@field.id} class="field-label" style="font-size:12px;font-weight:600">{@label}</label>
      <input
        type="text"
        id={@field.id}
        value="••••"
        disabled
        readonly
        data-masked
        aria-disabled="true"
        title="Masked on this plane"
      />
    </div>
    """
  end

  def form_field(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = Enum.map(field.errors, &translate_form_error/1)

    assigns =
      assigns
      |> assign(:errors, errors)
      |> assign(:error_id, if(errors != [], do: "#{field.id}-errors"))

    ~H"""
    <div
      class={["field", @errors != [] && "field-invalid"]}
      style="display:flex;flex-direction:column;gap:4px;margin-bottom:10px"
    >
      <label :if={@label} for={@field.id} class="field-label" style="font-size:12px;font-weight:600">{@label}</label>
      <%= case @type do %>
        <% "textarea" -> %>
          <textarea
            id={@field.id}
            name={@field.name}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={@error_id}
            {@rest}
          >{Phoenix.HTML.Form.normalize_value("textarea", @field.value)}</textarea>
        <% "select" -> %>
          <select
            id={@field.id}
            name={@field.name}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={@error_id}
            {@rest}
          >
            <option :if={@prompt} value="">{@prompt}</option>
            {Phoenix.HTML.Form.options_for_select(@options, @field.value)}
          </select>
        <% type -> %>
          <input
            type={type}
            id={@field.id}
            name={@field.name}
            value={Phoenix.HTML.Form.normalize_value(type, @field.value)}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={@error_id}
            {@rest}
          />
      <% end %>
      <div :if={@errors != []} class="field-errors" id={@error_id}>
        <p :for={msg <- @errors} class="field-error" style="margin:0;color:var(--bad, #b91c1c);font-size:12px">{msg}</p>
      </div>
    </div>
    """
  end

  # Interpolate `{msg, opts}` error tuples (the Phoenix/Ash error shape). This touches
  # ERROR MESSAGES only — framework copy + bounded vars — never a field value.
  defp translate_form_error({msg, opts}) when is_binary(msg) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp translate_form_error(msg) when is_binary(msg), do: msg
end

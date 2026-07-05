defmodule DemoWeb.ContactLive do
  @moduledoc """
  Minimal LiveView page proving %Masked{} renders "••••" in real HEEx (T1.9
  acceptance clause: LiveView page proving •••• in real HEEx).

  This view intentionally renders masked values (the normal read path) and
  optionally grants a reveal. The test suite exercises the HEEx render path
  directly using Phoenix.LiveViewTest helpers.

  ## What this proves

  The Gate-0 fix task #1: `Phoenix.HTML.Safe` is implemented on `%Masked{}` so
  a HEEx `<%= @contact.emails %>` renders "••••" and never raises
  `Protocol.UndefinedError`. The `masked_render_test.exs` in samen_core already
  covers the protocol; this LiveView covers the real end-to-end LiveView render.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    # In a real app we'd load the contact from the DB. For the dogfood, we use
    # a synthetic masked value to prove the HEEx render path.
    masked_emails = Samen.Masked.new("vt_demo_token_001", :emails)
    masked_full_name = Samen.Masked.new("vt_demo_token_002", :full_name)
    masked_dob = Samen.Masked.new("vt_demo_token_003", :dob)

    {:ok,
     assign(socket,
       contact_name: "Demo Contact",
       emails: masked_emails,
       full_name: masked_full_name,
       dob: masked_dob,
       granted: false
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="contact-card">
      <h2>Contact: {@contact_name}</h2>
      <dl>
        <dt>Full Name</dt>
        <dd id="full-name">{@full_name}</dd>

        <dt>Email(s)</dt>
        <dd id="emails">{@emails}</dd>

        <dt>Date of Birth</dt>
        <dd id="dob">{@dob}</dd>
      </dl>

      <%= if @granted do %>
        <p id="reveal-status">Plaintext revealed (grant active)</p>
      <% else %>
        <p id="reveal-status">Access masked — request a reveal grant to see PII</p>
      <% end %>
    </div>
    """
  end
end

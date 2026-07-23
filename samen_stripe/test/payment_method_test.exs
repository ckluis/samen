defmodule SamenStripe.PaymentMethodTest do
  @moduledoc """
  B5 payment methods (T23; ADR-038 §3.1 `create_portal_session`, §3.5 no-PAN +
  cross-reference rules) — proven hermetically (keyless, M2 default; no
  network, no Stripe credential).

  The full real path runs through the CORE, vendor-generic logic (ADR-038 §2 —
  "adapters translate and transport; core owns state and convergence"):

      Samen.Billing.PaymentMethod.create_portal_session/2   (validates attrs,
                                                              FORCES org-scoped
                                                              return_url, reduces
                                                              attrs to a CLOSED
                                                              whitelist)
        → SamenStripe.Provider.create_portal_session/2       (optionally syncs the
             served by an injected CAPTURING transport         Stripe customer
             (config[:transport], §7.1 lane 0)                 object, THEN builds
                                                                 the hosted portal
                                                                 session form)

  Done-criteria proven here:

    1. (repo-wide schema probe) lives in `samen_core/test/no_pan_columns_red_path_test.exs`
       — this file additionally proves the ADAPTER never puts a PAN/CVC-shaped
       key on the wire, for real captured HTTP forms.
    2. the payment-method flow emits ONLY a Stripe-HOSTED URL (never a local
       samen route/card form) — asserted below AND via the cross-package
       template grep probe (no card-form fields in ANY samen_web/samen_stripe
       template, anti-tautology).
    3. customer sync sends ONLY the ADR-whitelisted vault-resolved fields
       (`billing_name` → `name`, `billing_email` → `email`) — snapshot-tested
       against the captured HTTP form, including with deliberately-injected
       junk attrs that must NOT survive. `provider_customer_ref` (the vendor-neutral
       name after the T106 INV-4 rename, ratchet 24→0) is the sole cross-reference to
       the provider; `samen_core/test/billing_vendor_free_test.exs` asserts a strict
       zero vendor strings in `samen_core/lib`.
  """
  use ExUnit.Case, async: true

  alias Samen.Billing.PaymentMethod
  alias SamenStripe.Provider

  @secret_key "sk_test_pm"
  @org_id "org_pm_1"
  @customer_ref "cus_pm_1"
  @portal_url "https://billing.stripe.com/session/test_abc123"

  @repo_root Path.expand("../..", __DIR__)

  # --- helpers -----------------------------------------------------------------

  defp capturing_transport(response_fun) do
    parent = self()

    fn request ->
      send(parent, {:captured_request, request})
      response_fun.(request)
    end
  end

  defp portal_attrs(overrides \\ %{}) do
    Map.merge(
      %{org_id: @org_id, customer_ref: @customer_ref, return_url: "https://app.example.test/billing"},
      overrides
    )
  end

  defp create_portal_session(attrs, config_overrides) do
    config = Map.merge(%{secret_key: @secret_key}, config_overrides)
    PaymentMethod.create_portal_session(attrs, provider: Provider, provider_config: config)
  end

  # A responder that answers BOTH the (optional) customer-sync POST and the
  # portal-session POST with distinguishable fixture bodies, keyed on URL shape.
  defp portal_responder do
    fn %{url: url} ->
      if String.ends_with?(url, "/billing_portal/sessions") do
        {:ok, %{status: 200, body: %{"id" => "bps_test_1", "url" => @portal_url}}}
      else
        {:ok, %{status: 200, body: %{"id" => @customer_ref}}}
      end
    end
  end

  defp drain_captured_requests(acc \\ []) do
    receive do
      {:captured_request, req} -> drain_captured_requests([req | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ---------------------------------------------------------------------------
  # done-criterion 2 — ONLY a Stripe-hosted URL is ever emitted.
  # ---------------------------------------------------------------------------

  describe "done-criterion 2 — the flow emits ONLY a Stripe-hosted URL (no local card form)" do
    test "a configured create_portal_session returns the provider's hosted URL, unaltered" do
      transport = capturing_transport(portal_responder())

      assert {:ok, %{url: url}} = create_portal_session(portal_attrs(), %{transport: transport})
      assert url == @portal_url
      assert String.starts_with?(url, "https://billing.stripe.com/")
    end

    test "missing required attrs refuse BEFORE any provider call (never a partial/local session)" do
      transport = capturing_transport(portal_responder())

      assert {:error, {:missing_attrs, missing}} =
               create_portal_session(%{org_id: @org_id}, %{transport: transport})

      assert :customer_ref in missing
      assert :return_url in missing
      refute_received {:captured_request, _}
    end

    test "unconfigured provider refuses with :not_configured (fail-honest, ADR-014)" do
      assert {:error, :not_configured} =
               PaymentMethod.create_portal_session(portal_attrs(), provider: Provider, provider_config: %{})
    end

    test "the portal-session HTTP form itself carries ONLY customer/return_url — no PAN, no PII" do
      transport = capturing_transport(portal_responder())

      assert {:ok, _} = create_portal_session(portal_attrs(), %{transport: transport})

      [request] = drain_captured_requests()
      assert request.method == :post
      assert String.ends_with?(request.url, "/billing_portal/sessions")
      assert Enum.sort(Map.keys(request.form)) == ["customer", "return_url"]
      assert request.form["customer"] == @customer_ref
    end
  end

  # ---------------------------------------------------------------------------
  # done-criterion 3 — customer sync sends ONLY the ADR-whitelisted fields.
  # ---------------------------------------------------------------------------

  describe "done-criterion 3 — customer sync sends ONLY billing_name→name / billing_email→email" do
    test "absent billing_name/billing_email — no sync call happens at all (pure no-op)" do
      transport = capturing_transport(portal_responder())

      assert {:ok, _} = create_portal_session(portal_attrs(), %{transport: transport})

      # Exactly ONE captured request (the portal session) — no sync round-trip wasted.
      requests = drain_captured_requests()
      assert length(requests) == 1
      assert String.ends_with?(hd(requests).url, "/billing_portal/sessions")
    end

    test "present billing_name/billing_email sync a customer-update form carrying ONLY name/email" do
      transport = capturing_transport(portal_responder())

      attrs = portal_attrs(%{billing_name: "Alice Accountant", billing_email: "alice@billing.example"})
      assert {:ok, _} = create_portal_session(attrs, %{transport: transport})

      requests = drain_captured_requests()
      assert length(requests) == 2

      sync_request = Enum.find(requests, &String.ends_with?(&1.url, "/customers/#{@customer_ref}"))
      portal_request = Enum.find(requests, &String.ends_with?(&1.url, "/billing_portal/sessions"))

      assert sync_request
      assert portal_request

      # Snapshot: the whitelist is EXACTLY {name, email} — nothing else, ever.
      assert sync_request.form == %{"name" => "Alice Accountant", "email" => "alice@billing.example"}
    end

    test "anti-tautology: injected junk attrs (PAN-shaped, PII-shaped, or otherwise) NEVER survive into the sync form" do
      transport = capturing_transport(portal_responder())

      # The core module already whitelists (proven in samen_core's own test); this
      # proves the ADAPTER'S OWN whitelist is a real, independent second gate — it
      # holds even if handed a raw map that bypassed the core module entirely
      # (an operator script, or a future caller, calling the adapter directly).
      junky_attrs = %{
        customer_ref: @customer_ref,
        return_url: "https://app.example.test/billing",
        billing_name: "Carol CFO",
        billing_email: "carol@billing.example",
        card_number: "4242424242424242",
        cvc: "123",
        phone: "+15551234567",
        address: "1 Main St",
        ssn: "123-45-6789"
      }

      assert {:ok, _} =
               Provider.create_portal_session(junky_attrs, %{secret_key: @secret_key, transport: transport})

      requests = drain_captured_requests()
      sync_request = Enum.find(requests, &String.ends_with?(&1.url, "/customers/#{@customer_ref}"))

      assert sync_request
      assert map_size(sync_request.form) == 2
      assert sync_request.form == %{"name" => "Carol CFO", "email" => "carol@billing.example"}
    end

    test "a customer-sync HTTP failure surfaces as an error (never a silent partial success)" do
      transport =
        capturing_transport(fn %{url: url} ->
          if String.ends_with?(url, "/billing_portal/sessions") do
            {:ok, %{status: 200, body: %{"id" => "bps_x", "url" => @portal_url}}}
          else
            {:ok, %{status: 402, body: %{"error" => "card_declined_or_whatever"}}}
          end
        end)

      attrs = portal_attrs(%{billing_name: "Dan Director"})
      assert {:error, {:http_error, 402}} = create_portal_session(attrs, %{transport: transport})
    end
  end

  # ---------------------------------------------------------------------------
  # done-criterion 1 (adapter-level slice) — no PAN/CVC-shaped key or value ever
  # appears on the wire, across EVERY captured request this file exercises.
  # ---------------------------------------------------------------------------

  describe "done-criterion 1 (adapter slice) — no PAN/CVC-shaped key ever reaches the wire" do
    test "across portal-session AND customer-sync requests, no captured form key/value is PAN/CVC-shaped" do
      transport = capturing_transport(portal_responder())

      attrs = portal_attrs(%{billing_name: "Eve Engineer", billing_email: "eve@billing.example"})
      assert {:ok, _} = create_portal_session(attrs, %{transport: transport})

      requests = drain_captured_requests()
      assert length(requests) == 2

      for %{form: form} <- requests, {k, v} <- form do
        refute Samen.Verifiers.NoPanColumns.pan_shaped?(to_string(k)),
               "form key #{k} is PAN/CVC-shaped — must never appear on the wire"

        refute is_binary(v) and Samen.Verifiers.NoPanColumns.pan_shaped?(v),
               "form value for #{k} (#{inspect(v)}) is PAN/CVC-shaped"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # done-criterion 2 (template slice) — grep probe over samen_web + samen_stripe
  # templates: NO card form fields anywhere. Anti-tautology: a synthetic
  # scratch template WITH a card field is proven caught by the SAME extraction
  # + matching logic (never touches real repo files).
  # ---------------------------------------------------------------------------

  describe "done-criterion 2 (template slice) — no card form fields in ANY samen template" do
    test "GREEN: samen_web/lib + samen_stripe/lib carry zero card-form-field-shaped identifiers in any HEEx template" do
      offenders =
        ["samen_web/lib", "samen_stripe/lib"]
        |> Enum.flat_map(fn rel -> scan_dir_for_pan_shaped_template_identifiers(Path.join(@repo_root, rel)) end)

      assert offenders == [],
             "PAN/CVC-shaped identifier(s) found in a samen template — samen must NEVER render a " <>
               "card form (B5 hosted-surfaces-only rule): #{inspect(offenders)}"
    end

    test "RED (anti-tautology): a synthetic scratch template WITH a card-number field IS caught by the same probe" do
      scratch_dir = Path.join(System.tmp_dir!(), "pan_template_probe_#{System.unique_integer([:positive])}")
      File.mkdir_p!(scratch_dir)

      # A plain `.heex` file needs no `~H` sigil wrapping — scanned as raw
      # template text by `scan_dir_for_pan_shaped_template_identifiers/1`.
      bad_heex = """
      <form>
        <input type="text" name="card_number" />
        <input type="text" name="cvc" />
      </form>
      """

      File.write!(Path.join(scratch_dir, "bad_card_form.heex"), bad_heex)

      offenders = scan_dir_for_pan_shaped_template_identifiers(scratch_dir)

      assert offenders != [],
             "the anti-tautology fixture MUST be caught by the probe — if this ever passes empty, the probe is broken"

      assert Enum.any?(offenders, fn {_file, ids} -> "card_number" in ids end)
      assert Enum.any?(offenders, fn {_file, ids} -> "cvc" in ids end)
    after
      scratch_dirs = Path.wildcard(Path.join(System.tmp_dir!(), "pan_template_probe_*"))
      Enum.each(scratch_dirs, &File.rm_rf!/1)
    end
  end

  # Extract every `~H"""..."""` HEEx sigil block from `.ex` files, plus the
  # whole content of any `.heex` file, under `dir`. Returns
  # `[{path, [pan_shaped_identifier, ...]}]` for files with a hit — empty means
  # clean. Reuses `Samen.Verifiers.NoPanColumns.pan_shaped?/1`, the SAME shape
  # rule the schema probe uses (one rule, two surfaces, no drift).
  defp scan_dir_for_pan_shaped_template_identifiers(dir) do
    heex_sigil = ~r/~H"""(.*?)"""/s

    (Path.wildcard(Path.join(dir, "**/*.ex")) ++ Path.wildcard(Path.join(dir, "**/*.heex")))
    |> Enum.map(fn path ->
      content = File.read!(path)

      template_text =
        if String.ends_with?(path, ".heex") do
          content
        else
          heex_sigil
          |> Regex.scan(content)
          |> Enum.map_join("\n", fn [_, body] -> body end)
        end

      hits =
        ~r/[a-zA-Z_][a-zA-Z0-9_]*/
        |> Regex.scan(template_text)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.filter(&Samen.Verifiers.NoPanColumns.pan_shaped?/1)

      {path, hits}
    end)
    |> Enum.filter(fn {_path, hits} -> hits != [] end)
  end
end

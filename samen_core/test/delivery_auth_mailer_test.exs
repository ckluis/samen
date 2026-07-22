defmodule Samen.Delivery.AuthMailerTest do
  @moduledoc """
  ADR-035 §5 A2/A3/A5 (T03; T05 extends the context set with `:invite`) —
  `Samen.Delivery.AuthMailer` dispatches auth-token emails (`:email_verify`,
  `:password_reset`, `:invite`) through the SAME fail-honest
  `Samen.Delivery.Lifecycle.EmailWorker` decision (`decide/3`), honoring its
  CURRENT `:blocked` state exactly — never faking a send (Invariant D1,
  ADR-014 §3), the property the binding addendum names explicitly.
  """
  use ExUnit.Case, async: false

  alias Samen.Delivery.AuthMailer
  alias Samen.Delivery.Lifecycle.EmailWorker
  alias Samen.Delivery.Message

  defmodule OkAdapter do
    @behaviour Samen.Delivery.Adapter
    @impl true
    def configured?(_config), do: true
    @impl true
    def deliver(%Message{} = m, _config), do: {:ok, %{provider_id: "auth-#{m.send_id}"}}
  end

  defmodule UnconfiguredAdapter do
    @behaviour Samen.Delivery.Adapter
    @impl true
    def configured?(_config), do: false
    @impl true
    def deliver(%Message{}, _config), do: {:ok, %{lie: true}}
  end

  setup do
    prev = Application.get_env(:samen_core, EmailWorker)
    prev_mkt = Application.get_env(:samen_core, Samen.Scopes.Marketing.SendWorker)
    prev_env = Application.get_env(:samen_core, :delivery_env)

    on_exit(fn ->
      restore(EmailWorker, prev)
      restore(Samen.Scopes.Marketing.SendWorker, prev_mkt)

      if prev_env,
        do: Application.put_env(:samen_core, :delivery_env, prev_env),
        else: Application.delete_env(:samen_core, :delivery_env)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:samen_core, key)
  defp restore(key, val), do: Application.put_env(:samen_core, key, val)

  test "contexts/0 is the bounded auth-token email set" do
    assert AuthMailer.contexts() == [:email_verify, :password_reset, :invite]
  end

  test ":invite dispatches on `:invitation_id` (an invite has no Credential yet)" do
    Application.delete_env(:samen_core, EmailWorker)
    Application.delete_env(:samen_core, Samen.Scopes.Marketing.SendWorker)
    Application.put_env(:samen_core, :delivery_env, :test)

    assert {:ok, _receipt} = AuthMailer.dispatch(:invite, invitation_id: "inv-1", org_id: "org-1")
  end

  test "GREEN: :test env with no adapter captures via LocalSink (honest, not a fake send)" do
    Application.delete_env(:samen_core, EmailWorker)
    Application.delete_env(:samen_core, Samen.Scopes.Marketing.SendWorker)
    Application.put_env(:samen_core, :delivery_env, :test)

    assert {:ok, receipt} = AuthMailer.dispatch(:email_verify, credential_id: "cred-1")
    assert receipt.sink == true
  end

  test "RP-D1: a non-:test env with NO configured adapter is honestly BLOCKED, never faked to :ok" do
    Application.delete_env(:samen_core, EmailWorker)
    Application.delete_env(:samen_core, Samen.Scopes.Marketing.SendWorker)
    Application.put_env(:samen_core, :delivery_env, :prod)

    assert {:error, :adapter_unconfigured} = AuthMailer.dispatch(:password_reset, credential_id: "cred-1")
  end

  test "RP-D1: an UNCONFIGURED adapter in a non-:test env is honestly BLOCKED" do
    Application.put_env(:samen_core, EmailWorker, adapter: UnconfiguredAdapter, adapter_config: %{})
    Application.put_env(:samen_core, :delivery_env, :prod)

    assert {:error, :adapter_unconfigured} = AuthMailer.dispatch(:email_verify, credential_id: "cred-1")
  end

  test "anti-tautology: a CONFIGURED adapter genuinely dispatches" do
    Application.put_env(:samen_core, EmailWorker, adapter: OkAdapter, adapter_config: %{})
    Application.put_env(:samen_core, :delivery_env, :prod)

    assert {:ok, %{provider_id: provider_id}} =
             AuthMailer.dispatch(:email_verify, credential_id: "cred-1", org_id: "org-1")

    assert is_binary(provider_id)
  end

  test "password_reset requests are org-less (org_id: nil is accepted, still dispatches)" do
    Application.put_env(:samen_core, EmailWorker, adapter: OkAdapter, adapter_config: %{})
    Application.put_env(:samen_core, :delivery_env, :prod)

    assert {:ok, _receipt} = AuthMailer.dispatch(:password_reset, credential_id: "cred-1", org_id: nil)
  end

  test "a host that wired ONE delivery adapter (the marketing SendWorker) gets auth mail through it for free" do
    Application.delete_env(:samen_core, EmailWorker)

    Application.put_env(:samen_core, Samen.Scopes.Marketing.SendWorker,
      adapter: OkAdapter,
      adapter_config: %{}
    )

    Application.put_env(:samen_core, :delivery_env, :prod)

    assert {:ok, _receipt} = AuthMailer.dispatch(:email_verify, credential_id: "cred-1")
  end
end

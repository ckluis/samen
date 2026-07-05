defmodule Samen.RevealTest do
  @moduledoc """
  Acceptance (plan S0.5): `:reveal` returns plaintext exactly through the one
  chokepoint (`Samen.Vault.reveal/2`).
  """
  use ExUnit.Case, async: false

  alias Samen.Masked
  alias Samen.Vault

  @secret "bob.secret@example.com"

  setup do
    S05Vault.DBCase.truncate!()
    Samen.Kms.FileBacked.simulate_outage(false)
    subject = "subj-reveal-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
    {:ok, person} = Vault.store_email(subject, "Bob", @secret)
    %{subject: subject, person: person}
  end

  test "reveal returns exact plaintext from a %Masked{}", %{person: person} do
    assert {:ok, @secret} = Vault.reveal(person.email)
  end

  test "reveal returns exact plaintext from a Person", %{person: person} do
    assert {:ok, @secret} = Vault.reveal(person)
  end

  test "reveal round-trips exactly (property-ish over several values)" do
    for _ <- 1..25 do
      subject = "subj-rt-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
      value = "user+#{:rand.uniform(10_000)}@example.org"
      {:ok, person} = Vault.store_email(subject, "X", value)
      assert {:ok, ^value} = Vault.reveal(person.email)
    end
  end

  test "a %Masked{} carries no plaintext — reveal is the only source", %{person: person} do
    masked = person.email
    assert %Masked{} = masked
    # The struct fields expose only the token + label, never the secret.
    refute masked.token =~ @secret
    assert masked.label == :email
    # The plaintext only appears via the chokepoint.
    assert {:ok, @secret} = Vault.reveal(masked)
  end

  test "reveal of an unknown token returns :not_found, never plaintext" do
    bogus = Masked.new("vt_deadbeef", :email)
    assert {:error, :not_found} = Vault.reveal(bogus)
  end
end

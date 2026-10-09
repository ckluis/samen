defmodule Samen.Observability.VaultInspectRedactionTest do
  @moduledoc """
  ADR-052 §2.1 item 3 — "Ash changeset/error inspection of vault-routed attributes is verified
  to print redacted; if it does not, it is fixed at the attribute, not in Logger."

  Verified on this tree: Ash redacts a `sensitive?` changeset ARGUMENT and hides a `sensitive?`
  field on a RECORD, but prints a changeset ATTRIBUTE verbatim — `inspect(changeset)` showed the
  typed email until `Samen.Vault.Change` swapped in the token. Fixed at the type:
  `Samen.Type.VaultField.cast_input/2` holds plaintext as `%Samen.Pii.Plaintext{}`, whose
  `Inspect` is `**redacted**`.

  Each assertion pairs with a positive control: the plaintext really is ON the changeset (so
  "not in the inspect output" is not vacuous), and already-vaulted values pass through.
  """
  use ExUnit.Case, async: true

  alias Samen.Masked
  alias Samen.Pii.Plaintext
  alias SamenCore.Support.RevealDomain.RevealPerson

  @secret "inspect-probe-secret@example.test"

  defp changeset(attrs) do
    Ash.Changeset.for_create(RevealPerson, :create, attrs)
  end

  test "inspect(changeset) never prints a vault-routed attribute's plaintext" do
    cs = changeset(%{emails: [%{"value" => @secret, "label" => "work"}]})

    # POSITIVE CONTROL: the plaintext IS on the changeset, held for the vault write.
    assert [%{"value" => @secret}] =
             cs |> Ash.Changeset.get_attribute(:emails) |> Plaintext.unwrap()

    out = inspect(cs, limit: :infinity, printable_limit: :infinity)
    refute out =~ @secret
    assert out =~ "**redacted**"
  end

  test "a FAILING create: neither the error's message nor its inspect carries the plaintext" do
    # display_name: a map is not a string → the create is invalid before any vault write.
    cs = changeset(%{emails: [%{"value" => @secret}], display_name: %{not: "a string"}})
    refute cs.valid?

    assert {:error, error} = Ash.create(cs, authorize?: false)

    refute Exception.message(error) =~ @secret
    refute inspect(error, limit: :infinity, printable_limit: :infinity) =~ @secret
    refute inspect(cs.errors, limit: :infinity, printable_limit: :infinity) =~ @secret
  end

  test "a FunctionClauseError blame over a changeset does not print the plaintext" do
    cs = changeset(%{emails: [%{"value" => @secret}]})

    message =
      try do
        apply(__MODULE__, :only_atoms, [cs])
      rescue
        e in FunctionClauseError ->
          # `blame/3` is what renders "The following arguments were given" (ExUnit and the
          # crash formatters call it): the arguments are INSPECTED into the message.
          {blamed, _stack} = Exception.blame(:error, e, __STACKTRACE__)
          Exception.message(blamed)
      end

    # POSITIVE CONTROL: the blame really did render the changeset argument.
    assert message =~ "#Ash.Changeset<"
    refute message =~ @secret
  end

  test "already-vaulted values (a %Masked{} round-trip, a vt_ token, nil) pass through unwrapped" do
    masked = Masked.new("vt_abc", :emails)
    assert {:ok, ^masked} = Samen.Type.VaultField.cast_input(masked, [])
    assert {:ok, "vt_abc"} = Samen.Type.VaultField.cast_input("vt_abc", [])
    assert {:ok, nil} = Samen.Type.VaultField.cast_input(nil, [])
    assert {:ok, %Plaintext{value: "x"}} = Samen.Type.VaultField.cast_input("x", [])
  end

  test "an unrouted wrapped plaintext still FAILS CLOSED at dump (never written)" do
    assert :error = Samen.Type.VaultField.dump_to_native(Plaintext.wrap(@secret), [])
  end

  @doc false
  def only_atoms(a) when is_atom(a), do: a
end

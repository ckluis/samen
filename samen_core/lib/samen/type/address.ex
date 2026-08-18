defmodule Samen.Type.Address do
  @moduledoc """
  Composite PII type `%Samen.Type.Address{}` — a postal address (ADR-036 H4/D4).

  Modeled on `Samen.Type.FullName`'s composite shape:

      pii_attribute :address, Samen.Type.Address, vault: :pii_address

  The value is:

      %Samen.Type.Address{
        line1: "123 Main St",
        line2: nil,
        city: "Springfield",
        region: "IL",
        postal_code: "62704",
        country: "US"
      }

  Every field is OPTIONAL (H4 done-criterion 1: a **partial** address — e.g. just
  `city`/`country` — casts and dumps fine; there is no required-field set).

  ## `Address` is ALWAYS PII — no gate, unlike `EmailAddress`/`PhoneNumber`

  `samen_pii_class/0 => :pii` is exported unconditionally, so
  `Samen.Pii.Classification.classify/1` returns `:pii` for this module with NO
  `TypeClearance` able to override it (a type that self-classifies `:pii` is
  always honored — see `Classification`'s precedence order). Unlike the H3 scalars
  (email/phone, which are PII-by-default but type-*unclassified*, letting a
  per-column `NonPii.register/1` clear an org-contact column), an address is
  categorically a subject's own data (ADR-036 D4/H4) and has no org-contact
  analogue in this contract — it is ALWAYS vault-routed (`pii_attribute … vault:
  :pii_address`) or, if used plainly for test/demo purposes, still classifies
  `:pii` and is caught by the `pii_classify` verifier same as any other PII-typed
  plain column.

  ## Composite routing / classification

  As a composite type (`storage_type/1 => :map`) it routes by vault name (abbrev
  prefix, no `pii_` column prefix) — the same "PII routing note" convention as
  `FullName`/`Emails`/`Phones`.

  ## `country` is the one field with a real format rule

  `line1`/`line2`/`city`/`region`/`postal_code` accept any string (postal formats
  vary too widely across countries to bound further) — but if PRESENT they must
  actually be a string, not silently coerced (a wrong-shaped value like an
  integer is REFUSED, mirroring `EmailAddress`/`PhoneNumber`'s "no coercion"
  discipline). `country`, when present, is normalized (trim + upcase) and then
  validated as a two-letter alpha-2 country code (shape check, not ISO-3166-1 set
  membership) via `~r/^[A-Z]{2}$/` — a 3-letter code
  (`"USA"`), digits, or garbage is REFUSED. This is the type's own format check,
  the H4/H5 analogue of `EmailAddress`'s regex / `PhoneNumber`'s E.164 shape —
  and it is what the ADR-036 §10 addendum's "garbage-Address red test" exercises:
  a malformed `country` cannot vault (see `Samen.Vault.CastValidationTest` and
  `samen_core/test/type/address_test.exs`).

  ## Vault write-path validation (ADR-036 §10 addendum — T14, post-T99)

  T99 (ADR-036 §10) left COMPOSITE PII types unvalidated on the vaulted write
  path (`Samen.Vault.Change`'s `cast_declared_types/1` skips any field whose
  `field.composite?` is true, to avoid reshaping `FullName`/`Emails`/`Phones` and
  breaking shipped loose-shape writers like `Invitation.email`). `Address` is
  BRAND NEW — it has no shipped loose writers to break — so `Samen.Vault.Change`
  carries a narrow, Address-specific carve-out: a value routed to a
  `Samen.Type.Address`-typed `pii_attribute` DOES re-run this module's own
  `cast_input/2` before it reaches the vault, exactly like the H3 scalars. A
  malformed `Address` is refused as a normal changeset error — it never vaults.
  `FullName`/`Emails`/`Phones` are untouched (still byte-exact, per T99).
  """
  use Ash.Type

  @enforce_keys []
  defstruct [:line1, :line2, :city, :region, :postal_code, :country]

  @type t :: %__MODULE__{
          line1: String.t() | nil,
          line2: String.t() | nil,
          city: String.t() | nil,
          region: String.t() | nil,
          postal_code: String.t() | nil,
          country: String.t() | nil
        }

  @impl true
  def storage_type(_constraints), do: :map

  @doc "Self-classification for `Samen.Pii.Classification`: an address is PII (ADR-036 D4, always honored, no gate)."
  def samen_pii_class, do: :pii

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(%__MODULE__{} = v, _constraints), do: build(struct_map(v))
  def cast_input(%{} = map, _constraints), do: build(map)
  def cast_input(_other, _constraints), do: :error

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(%{} = map, _constraints) do
    {:ok,
     %__MODULE__{
       line1: fetch(map, :line1),
       line2: fetch(map, :line2),
       city: fetch(map, :city),
       region: fetch(map, :region),
       postal_code: fetch(map, :postal_code),
       country: fetch(map, :country)
     }}
  end

  def cast_stored(_other, _constraints), do: :error

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(%__MODULE__{} = v, _constraints) do
    {:ok,
     %{
       "line1" => v.line1,
       "line2" => v.line2,
       "city" => v.city,
       "region" => v.region,
       "postal_code" => v.postal_code,
       "country" => v.country
     }}
  end

  def dump_to_native(_other, _constraints), do: :error

  # ---------------------------------------------------------------------------
  # Validation — the type's OWN input boundary (ADR-036 §10 addendum). Every
  # field is optional (partial addresses are valid), but a PRESENT field must be
  # the right shape: a plain string, and — for `country` — an ISO-3166-1 alpha-2
  # code. This runs on EVERY cast_input/2 call, so it is the single choke point
  # both the plain-attribute path (a bare `attribute :x, Samen.Type.Address`) and
  # the vaulted write path (once `Samen.Vault.Change` re-invokes it, see above)
  # share — the same parity guarantee `EmailAddress`/`PhoneNumber` already have.
  # ---------------------------------------------------------------------------

  defp build(map) do
    with {:ok, line1} <- text(fetch(map, :line1)),
         {:ok, line2} <- text(fetch(map, :line2)),
         {:ok, city} <- text(fetch(map, :city)),
         {:ok, region} <- text(fetch(map, :region)),
         {:ok, postal_code} <- text(fetch(map, :postal_code)),
         {:ok, country} <- country(fetch(map, :country)) do
      {:ok,
       %__MODULE__{
         line1: line1,
         line2: line2,
         city: city,
         region: region,
         postal_code: postal_code,
         country: country
       }}
    end
  end

  defp text(nil), do: {:ok, nil}
  defp text(v) when is_binary(v), do: {:ok, v}
  defp text(_), do: :error

  defp country(nil), do: {:ok, nil}

  defp country(v) when is_binary(v) do
    normalized = v |> String.trim() |> String.upcase()

    if Regex.match?(~r/^[A-Z]{2}$/, normalized) do
      {:ok, normalized}
    else
      :error
    end
  end

  defp country(_), do: :error

  defp struct_map(%__MODULE__{} = v), do: Map.from_struct(v)

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

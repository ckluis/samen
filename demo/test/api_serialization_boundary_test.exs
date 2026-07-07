defmodule Demo.ApiSerializationBoundaryTest do
  @moduledoc """
  T3.11 — the serialization boundary as a STRUCTURAL property of the allowlist
  (`show_fields`), independent of any live request. This is the "a newly added
  storage column does not appear" proof at the introspection level:

    * `AshJsonApi.Resource.Info.show_field?/2` is the gate every serialized field
      passes through. A field NOT in `show_fields` returns `false` → it can never be
      serialized, even via `?fields=`.
    * So simulating a "newly added storage column" (a public attribute name the
      resource does not allowlist) proves absence WITHOUT touching the schema: the
      gate returns false for it and true for the allowlisted catalog names.
    * The exposed names are the CATALOG names (`:full_name`, `:display_name`), and
      NONE of them is a physical storage column name (`cnt_*`, `pii_*`, `vt_*`).
  """
  use ExUnit.Case, async: true

  alias AshJsonApi.Resource.Info, as: JsonApi

  @exposed_resources [
    {Demo.Crm.Contact, [:id, :display_name, :active, :full_name, :emails, :dob]},
    {Demo.Identity.User, [:id, :handle, :status, :full_name, :emails]},
    {Demo.Identity.Org, [:id, :name, :plan]},
    {Demo.Identity.Membership, [:id, :role, :status]}
  ]

  test "every allowlisted field passes show_field? (positive control — not vacuous)" do
    for {resource, allowlisted} <- @exposed_resources, field <- allowlisted do
      assert JsonApi.show_field?(resource, field),
             "#{inspect(resource)}.#{field} is allowlisted but show_field? denied it"
    end
  end

  test "a NEWLY ADDED storage column (unallowlisted public attr) does NOT pass show_field?" do
    # `org_id` is a PUBLIC attribute injected by CoreAttributes — it stands in for
    # "a newly added storage column": present on the resource, public, but NOT in the
    # allowlist. The gate must refuse it.
    refute JsonApi.show_field?(Demo.Crm.Contact, :org_id)
    refute JsonApi.show_field?(Demo.Identity.User, :org_id)

    # A completely fabricated field name (a hypothetical future column) is also
    # refused — the allowlist is opt-in, so anything not named is out.
    refute JsonApi.show_field?(Demo.Crm.Contact, :ssn_probe_column)
    refute JsonApi.show_field?(Demo.Crm.Contact, :notes)
  end

  test "no allowlisted field name is a physical storage name" do
    storage_patterns = [~r/^cnt_/, ~r/^com_/, ~r/^ido_/, ~r/^usr_/, ~r/^pii_/, ~r/^vt_/]

    for {_resource, allowlisted} <- @exposed_resources, field <- allowlisted do
      s = Atom.to_string(field)

      for pat <- storage_patterns do
        refute Regex.match?(pat, s),
               "allowlisted field #{s} looks like a physical storage name (#{inspect(pat)})"
      end
    end
  end

  test "a %Masked{} value serializes as •••• (the general masking rule)" do
    # The doc: "a masked value serializes as ••••". The Jason encoder proves it at the
    # serialization layer — no plaintext, no token.
    masked = Samen.Masked.new("vt_secret_token", :emails)
    assert Jason.encode!(%{email: masked}) == ~s({"email":"••••"})
    # The vault token never appears in the serialized form.
    refute Jason.encode!(%{email: masked}) =~ "vt_secret_token"
  end
end

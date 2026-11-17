defmodule Samen.PiiResolutionBagPlanesTest do
  @moduledoc """
  ARCH-26 (ADR-049 watch-list): the pii_declared custom-bag key through `Samen.Api.PiiResolution`, per plane, on the
  `Widget` fixture, which now also declares a reveal action (without one the operator-WITH-grant path is
  unprovable).

    * operator WITH a live grant → the bag key is CLEAR; WITHOUT → `••••`
    * an UNKNOWN plane stays `••••` even when the checker would approve everything (fail-safe default)
    * a batch spanning two orgs only masks the keys the record's own org declares; a record whose bag is not a
      map is passed through untouched
    * an indeterminate key set (no repo) masks the WHOLE bag
  """
  use ExUnit.Case, async: false

  alias Samen.CustomFields
  alias Samen.Masked
  alias SamenCore.TestRepo

  defmodule Grant do
    @moduledoc false
    def granted?(_ctx), do: true
  end

  defmodule Deny do
    @moduledoc false
    def granted?(_ctx), do: false
  end

  @table "tcf_widget"
  @key "care_note"
  @secret "alice@example.com"

  setup do
    Samen.TestSandbox.shared!(TestRepo)
    :ok
  end

  defp define!(org_id) do
    {:ok, _} =
      CustomFields.define_field(
        %{
          org_id: org_id,
          table_name: @table,
          field_name: @key,
          type: :string,
          pii_declared: true,
          erasure_specs: [
            %{table_name: @table, bag_column: "tcf_custom", subject_column: "tcf_id", org_column: "tcf_org_id"}
          ]
        },
        TestRepo
      )
  end

  defp widget(org_id, bag \\ %{@key => @secret, "tier" => "gold"}),
    do: struct(SamenCore.Support.CustomFields.Widget, %{id: Ecto.UUID.generate(), name: "w", org_id: org_id, custom: bag})

  defp resolve(records, actor, opts) do
    Samen.Api.PiiResolution.resolve(List.wrap(records), SamenCore.Support.CustomFields.Widget, actor, Keyword.merge([repo: TestRepo], opts))
  end

  defp op(org), do: %{plane: :operator, org_id: org, impersonation: %{session_id: "s"}}

  test "operator WITHOUT a grant masks the key; WITH a live grant the key is clear (per-key either way)" do
    org = Ash.UUID.generate()
    define!(org)

    [denied] = resolve(widget(org), op(org), grant: Deny)
    assert %Masked{token: nil} = denied.custom[@key]
    assert denied.custom["tier"] == "gold"

    [granted] = resolve(widget(org), op(org), grant: Grant)
    assert granted.custom[@key] == @secret
    assert granted.custom["tier"] == "gold"
  end

  test "an UNKNOWN plane never resolves the bag key to plaintext, whatever the checker says" do
    org = Ash.UUID.generate()
    define!(org)

    for plane <- [:weird, nil] do
      [r] = resolve(widget(org), %{plane: plane, org_id: org}, grant: Grant)
      assert %Masked{token: nil} = r.custom[@key]
    end
  end

  test "a record of ANOTHER org (no declared keys) and a non-map bag pass through untouched" do
    org = Ash.UUID.generate()
    other = Ash.UUID.generate()
    define!(org)

    [mine, theirs, bagless] =
      resolve([widget(org), widget(other, %{@key => "kept"}), widget(org, nil)], op(org), grant: Deny)

    assert %Masked{} = mine.custom[@key]
    assert theirs.custom[@key] == "kept"
    assert bagless.custom == nil
  end

  test "an indeterminate key set (no repo) masks the WHOLE bag; a determinate one masks only the key" do
    org = Ash.UUID.generate()
    define!(org)

    [blind] = resolve(widget(org), op(org), repo: nil, grant: Deny)
    assert %Masked{} = blind.custom[@key]
    assert %Masked{} = blind.custom["tier"]

    [sighted] = resolve(widget(org), op(org), grant: Deny)
    assert sighted.custom["tier"] == "gold"
  end

  test "an org-less masking actor with org-less records masks the whole bag" do
    org = Ash.UUID.generate()
    define!(org)

    [r] = resolve(widget(nil), %{plane: :operator}, grant: Deny)
    assert %Masked{} = r.custom["tier"]
  end

  test "egress masks the bag key even for an operator holding a grant" do
    org = Ash.UUID.generate()
    define!(org)

    [r] = resolve(widget(org), op(org), grant: Grant, egress: true, grant_egress?: true)
    assert %Masked{} = r.custom[@key]
  end
end

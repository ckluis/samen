defmodule Demo.ApiKeyScopeMintValidationTest do
  @moduledoc """
  The `ApiKey` resource's own `:create` refuses a key whose scopes are empty or outside the grammar, so no write path
  mints one; and a family name containing a dot is refused when the resource compiles. Each refusal is paired with a
  create that differs only in its scopes.
  """
  use Demo.ApiCase, async: false

  defp create(org_id, mbr_id, scopes) do
    Demo.Identity.ApiKey
    |> Ash.Changeset.for_create(:create, %{
      plane: :tenant,
      scopes: scopes,
      minter_role: :admin,
      org_id: org_id,
      membership_id: mbr_id
    })
    |> Ash.Changeset.force_change_attribute(:token_digest, DemoWeb.Api.KeyAuthPlug.digest("sk_" <> Ash.UUID.generate()))
    |> Ash.create(authorize?: false)
  end

  setup do
    org = mk_org("Mint validation")
    user = mk_user(org.id, "minter")
    mbr = mk_membership(org.id, user.id, :admin)
    {:ok, org: org, mbr: mbr}
  end

  test "RED: the resource's :create refuses an empty scope map; CONTROL: the same create with a scope succeeds", %{org: org, mbr: mbr} do
    assert {:error, %Ash.Error.Invalid{}} = create(org.id, mbr.id, %{})
    assert {:ok, _} = create(org.id, mbr.id, %{"all" => ["read"]})
  end

  test "RED: :create refuses scope keys and values outside the grammar; CONTROL: each fixed one succeeds", %{org: org, mbr: mbr} do
    refused = [%{"CRM" => ["read"]}, %{"crm.contact.x" => ["read"]}, %{"crm" => ["delete"]}, %{"crm" => []}, %{"crm" => "read"}, %{"" => ["read"]}]

    for scopes <- refused, do: assert({:error, %Ash.Error.Invalid{}} = create(org.id, mbr.id, scopes), inspect(scopes))

    for scopes <- [%{"crm" => ["read"]}, %{"crm.contact" => ["read", "write"]}, %{all: [:read]}],
        do: assert({:ok, _} = create(org.id, mbr.id, scopes), inspect(scopes))
  end

  describe "a family name with a dot" do
    defp compile_exposed(family) do
      n = System.unique_integer([:positive])
      domain = Module.concat(__MODULE__, "Dom#{n}")
      resource = Module.concat(__MODULE__, "Res#{n}")

      Code.compile_string("""
      defmodule #{inspect(domain)} do
        use Ash.Domain, validate_config_inclusion?: false, extensions: [AshJsonApi.Domain]
        resources do
          resource #{inspect(resource)}
        end
        def samen_api_family, do: #{inspect(family)}
      end

      defmodule #{inspect(resource)} do
        use Ash.Resource,
          domain: #{inspect(domain)},
          data_layer: Ash.DataLayer.Ets,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [Demo.ScopeFixture.Ext, AshJsonApi.Resource]

        json_api do
          type "thing"
        end

        attributes do
          uuid_primary_key :id
        end

        actions do
          defaults [:read]
        end
      end
      """)

      resource
    end

    test "RED: a JSON:API resource whose domain family contains a dot does not compile; CONTROL: a dotless family does" do
      assert_raise Spark.Error.DslError, ~r/family/, fn -> compile_exposed("crm.contact") end
      assert is_atom(compile_exposed("crm_contact"))
    end
  end
end

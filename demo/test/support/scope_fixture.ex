defmodule Demo.ScopeFixture.Ext do
  @moduledoc """
  Test-support extension: applies `Samen.Transformers.ApiKeyScopePolicy` to a plain Ash resource. A fixture
  resource cannot be a `Samen.Resource` (that needs a row in the committed abbrev registry), so it carries the real
  transformer through this extension instead; the policy it injects is the framework's own.
  """
  use Spark.Dsl.Extension, transformers: [Samen.Transformers.ApiKeyScopePolicy]
end

defmodule Demo.ScopeFixture.Domain do
  @moduledoc """
  Test-support domain behind `Demo.ScopeFixture.Router`: one JSON:API resource with a write route, a role-gated
  create policy and a `bypass`, to prove the key-scope policy composes with the role policy and cannot be
  skipped by a bypass. Its family is declared with `samen_api_family/0` (the grammar's override).
  """
  use Ash.Domain, validate_config_inclusion?: false, extensions: [AshJsonApi.Domain]

  resources do
    resource(Demo.ScopeFixture.Gadget)
    resource(Demo.ScopeFixture.Widget)
    resource(Demo.ScopeFixture.Bare)
  end

  @doc "The scope family of this domain's resources."
  def samen_api_family, do: "fixture"
end

defmodule Demo.ScopeFixture.Gadget do
  @moduledoc """
  A JSON:API resource with: a read open to any actor, a destroy (the write route; the host has no OpenAPI dependency, so
  a body-carrying POST route cannot run) that only an `:admin` role may run, and a `bypass` for the operator plane declared AFTER the
  framework's scope policy that authorizes every operator-plane actor. Without the scope policy coming first, that
  bypass would let a read-only key delete.
  """
  use Ash.Resource,
    domain: Demo.ScopeFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Demo.ScopeFixture.Ext, AshJsonApi.Resource]

  ets do
    private?(false)
  end

  json_api do
    type("gadget")
    show_fields([:id, :name])

    routes do
      base("/gadgets")
      index(:read)
      get(:read)
      delete(:destroy)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:name])
      primary?(true)
    end
  end

  policies do
    bypass actor_attribute_equals(:plane, :operator) do
      authorize_if(always())
    end

    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type([:create, :destroy]) do
      authorize_if(actor_attribute_equals(:role, :admin))
    end
  end
end

defmodule Demo.ScopeFixture.Widget do
  @moduledoc """
  A JSON:API resource that declares policies for ONE read action (`:covered_read`, open to any actor) and for nothing
  else. Its other actions (a read, a create, an update, a destroy and a generic action) have no covering policy, so
  Ash's rule "no policy applies: forbidden" must hold for them whoever asks, a key included.
  """
  use Ash.Resource,
    domain: Demo.ScopeFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Demo.ScopeFixture.Ext, AshJsonApi.Resource]

  ets do
    private?(false)
  end

  json_api do
    type("widget")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy])

    read :covered_read

    update :update do
      accept([:name])
      primary?(true)
    end

    create :create do
      accept([:name])
      primary?(true)
    end

    action :ping, :string do
      run(fn _input, _ctx -> {:ok, "pong"} end)
    end
  end

  policies do
    policy action(:covered_read) do
      authorize_if(always())
    end
  end
end

defmodule Demo.ScopeFixture.Bare do
  @moduledoc """
  A JSON:API resource with the policy authorizer and NO declared policy: deny-all for every actor, a key included.
  """
  use Ash.Resource,
    domain: Demo.ScopeFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Demo.ScopeFixture.Ext, AshJsonApi.Resource]

  ets do
    private?(false)
  end

  json_api do
    type("bare")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:name])
      primary?(true)
    end
  end
end

defmodule Demo.ScopeFixture.Router do
  @moduledoc "The JSON:API router over `Demo.ScopeFixture.Domain`, mounted at `/fx`."
  use AshJsonApi.Router, domains: [Demo.ScopeFixture.Domain], prefix: "/fx"
end

defmodule Demo.ScopeFixture.Endpoint do
  @moduledoc "Key auth, then the fixture router: the same two plugs a host endpoint runs."
  use Plug.Builder

  plug(DemoWeb.Api.KeyAuthPlug)
  plug(Demo.ScopeFixture.Router)
end

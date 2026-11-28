defmodule Demo.HelpFixture.Raises do
  @moduledoc "A policy check that raises: the control for 'a question Ash cannot answer is not listed, and is reported'."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "always raises"

  @impl true
  def match?(_actor, _context, _opts), do: raise("help fixture check raised")
end

defmodule Demo.HelpFixture.Counted do
  @moduledoc "A policy check that is always true and counts how often it is evaluated (`count/0`, `reset/0`)."
  use Ash.Policy.SimpleCheck

  @key {__MODULE__, :counter}

  @impl true
  def describe(_opts), do: "counts its evaluations"

  @impl true
  def match?(_actor, _context, _opts) do
    :counters.add(counter(), 1, 1)
    {:ok, true}
  end

  @doc "How often the check has been evaluated since `reset/0`."
  def count, do: :counters.get(counter(), 1)

  @doc "Start counting from zero."
  def reset, do: :counters.put(counter(), 1, 0)

  defp counter do
    case :persistent_term.get(@key, nil) do
      nil ->
        ref = :counters.new(1, [])
        :persistent_term.put(@key, ref)
        ref

      ref ->
        ref
    end
  end
end

defmodule Demo.HelpFixture.NeedsRow do
  @moduledoc "A policy check Ash cannot decide before it has the record: strict check answers unknown, the record check passes."
  use Ash.Policy.Check

  @impl true
  def describe(_opts), do: "needs the record to decide"

  @impl true
  def strict_check(_actor, _context, _opts), do: {:ok, :unknown}

  @impl true
  def check(_actor, records, _context, _opts), do: records

  @impl true
  def type, do: :manual
end

defmodule Demo.HelpFixture.Ext do
  @moduledoc "Applies the framework's key-scope policy transformer to a plain fixture resource (see `Demo.ScopeFixture.Ext`)."
  use Spark.Dsl.Extension, transformers: [Samen.Transformers.ApiKeyScopePolicy]
end

defmodule Demo.HelpFixture.Domain do
  @moduledoc """
  Test-support domain for `Samen.Api.Help`: one fixture per shape the description must get right (a filter policy,
  a strict policy over a filter, a check that raises, a relationship route to a hidden destination, a check that counts its evaluations).
  """
  use Ash.Domain, validate_config_inclusion?: false, extensions: [AshJsonApi.Domain]

  resources do
    resource(Demo.HelpFixture.Filtered)
    resource(Demo.HelpFixture.RowWrite)
    resource(Demo.HelpFixture.Runtime)
    resource(Demo.HelpFixture.StrictOnly)
    resource(Demo.HelpFixture.Raiser)
    resource(Demo.HelpFixture.Holder)
    resource(Demo.HelpFixture.Sealed)
    resource(Demo.HelpFixture.Tally)
  end

  @doc "The scope family of this domain's resources."
  def samen_api_family, do: "helpfx"
end

defmodule Demo.HelpFixture.Filtered do
  @moduledoc "A read and an update that the policies allow only for records named `visible` (a filter / a row-dependent check)."
  use Ash.Resource,
    domain: Demo.HelpFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Demo.HelpFixture.Ext, AshJsonApi.Resource]

  ets do
    private?(false)
  end

  json_api do
    type("filtered")

    routes do
      base("/filtered")
      index(:read)
      patch(:update)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read])

    update :update do
      accept([:name])
      primary?(true)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(expr(name == "visible"))
    end

    policy action_type(:update) do
      authorize_if(always())
    end
  end
end

defmodule Demo.HelpFixture.RowWrite do
  @moduledoc "A read open to all and an update that only a record named `visible` allows (a row-dependent check Ash cannot answer without the row)."
  use Ash.Resource,
    domain: Demo.HelpFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Demo.HelpFixture.Ext, AshJsonApi.Resource]

  ets do
    private?(false)
  end

  json_api do
    type("row_write")

    routes do
      base("/row_write")
      index(:read)
      patch(:update)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read])

    update :update do
      accept([:name])
      primary?(true)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type(:update) do
      authorize_if(expr(name == "visible"))
    end
  end
end

defmodule Demo.HelpFixture.Runtime do
  @moduledoc "A read open to all and an update whose policy needs the record (`NeedsRow`): allowed for some records, decided at the request."
  use Ash.Resource,
    domain: Demo.HelpFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Demo.HelpFixture.Ext, AshJsonApi.Resource]

  ets do
    private?(false)
  end

  json_api do
    type("runtime")

    routes do
      base("/runtime")
      index(:read)
      patch(:update)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read])

    update :update do
      accept([:name])
      primary?(true)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type(:update) do
      authorize_if(Demo.HelpFixture.NeedsRow)
    end
  end
end

defmodule Demo.HelpFixture.StrictOnly do
  @moduledoc "A read whose only policy is a filter check declared `access_type :strict`, which Ash refuses to answer without data."
  use Ash.Resource,
    domain: Demo.HelpFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Demo.HelpFixture.Ext, AshJsonApi.Resource]

  ets do
    private?(false)
  end

  json_api do
    type("strict_only")

    routes do
      base("/strict_only")
      index(:read)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  policies do
    policy action_type(:read) do
      access_type(:strict)
      authorize_if(expr(name == "visible"))
    end
  end
end

defmodule Demo.HelpFixture.Raiser do
  @moduledoc "A read guarded by a check that raises."
  use Ash.Resource,
    domain: Demo.HelpFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Demo.HelpFixture.Ext, AshJsonApi.Resource]

  ets do
    private?(false)
  end

  json_api do
    type("raiser")

    routes do
      base("/raisers")
      index(:read)
      get(:read)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Demo.HelpFixture.Raises)
    end
  end
end

defmodule Demo.HelpFixture.Sealed do
  @moduledoc "A resource only an `:owner` role may read: the hidden destination of `Holder`'s related route."
  use Ash.Resource,
    domain: Demo.HelpFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Demo.HelpFixture.Ext, AshJsonApi.Resource]

  ets do
    private?(false)
  end

  json_api do
    type("sealed")

    routes do
      base("/sealed")
      index(:read)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  policies do
    policy action_type(:read) do
      authorize_if(actor_attribute_equals(:role, :owner))
    end
  end
end

defmodule Demo.HelpFixture.Holder do
  @moduledoc "A readable resource with a `related` route to `Sealed`."
  use Ash.Resource,
    domain: Demo.HelpFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Demo.HelpFixture.Ext, AshJsonApi.Resource]

  ets do
    private?(false)
  end

  json_api do
    type("holder")

    routes do
      base("/holders")
      index(:read)
      get(:read)
      related(:sealed, :read)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  relationships do
    belongs_to :sealed, Demo.HelpFixture.Sealed do
      public?(true)
      attribute_type(:uuid)
    end
  end

  actions do
    defaults([:read])
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end
  end
end

defmodule Demo.HelpFixture.Tally do
  @moduledoc "A readable resource whose policy counts its evaluations (`Demo.HelpFixture.Counted`)."
  use Ash.Resource,
    domain: Demo.HelpFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Demo.HelpFixture.Ext, AshJsonApi.Resource]

  ets do
    private?(false)
  end

  json_api do
    type("tally")

    routes do
      base("/tallies")
      index(:read)
      get(:read)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Demo.HelpFixture.Counted)
    end
  end
end

defmodule Demo.HelpFixture.Router do
  @moduledoc "The JSON:API router over `Demo.HelpFixture.Domain`, mounted at `/hx`."
  use AshJsonApi.Router, domains: [Demo.HelpFixture.Domain], prefix: "/hx"
end

defmodule Demo.HelpFixture.Endpoint do
  @moduledoc "The error hints, key auth, then the fixture router: the plugs a host endpoint runs."
  use Plug.Builder

  plug(Samen.Api.Help.ErrorHints, router: Demo.HelpFixture.Router)
  plug(DemoWeb.Api.KeyAuthPlug)
  plug(Demo.HelpFixture.Router)
end

defmodule Samen.Observability.ParamFilterTest do
  @moduledoc """
  ADR-052 §2.1.2 item 2 — the framework keep-list keeps a kept key's value only when it is a
  SCALAR. Phoenix's own `{:keep, _}` filter keeps the whole subtree under a kept key; the
  real-Phoenix proof (Phoenix's handlers wrapped, `Phoenix.Logger.filter_values/2` composed) is
  `samen_web/test/samen/web/param_filter_logging_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Samen.Observability
  alias Samen.Observability.ParamFilter

  @keep {:keep, ~w(id org org_id page per_page limit cursor after before sort sort_by order dir)}

  test "POSITIVE CONTROL: scalar values of kept keys are kept, everything else filtered" do
    params = %{"id" => "42", "page" => 2, "sort" => nil, "email" => "alice@example.com"}

    assert ParamFilter.filter_values(params, @keep) == %{
             "id" => "42",
             "page" => 2,
             "sort" => nil,
             "email" => "[FILTERED]"
           }
  end

  test "a nested value under a kept key is filtered (id[x]=alice@…)" do
    filtered =
      ParamFilter.filter_values(
        %{
          "id" => %{"x" => "alice@example.com"},
          "org" => %{"name" => "Alice Anders", "id" => "7"},
          "sort" => ["alice@example.com"],
          "order" => %{__struct__: SomeUpload, filename: "alice.pdf"}
        },
        @keep
      )

    refute inspect(filtered) =~ "lice"
    assert filtered["id"] == %{"x" => "[FILTERED]"}
    # A kept key nested under a kept root is still a kept scalar.
    assert filtered["org"] == %{"name" => "[FILTERED]", "id" => "7"}
    assert filtered["sort"] == ["[FILTERED]"]
    assert filtered["order"] == "[FILTERED]"
  end

  test "an unfetched body and a deny-list filter pass through untouched" do
    unfetched = %{__struct__: Plug.Conn.Unfetched, aspect: :params}
    assert ParamFilter.filter_values(unfetched, @keep) == unfetched

    deny = %{"password" => "x", "id" => %{"x" => "y"}}
    assert ParamFilter.filter_values(deny, ["password"]) == deny
  end

  test "wired by child_specs/2 ON by default; param_filter: false opts out" do
    ids = fn specs -> for %{id: id} <- specs, do: id end
    assert {Observability, :param_filter, :pf_app} in ids.(Observability.child_specs(:pf_app))

    refute {Observability, :param_filter, :pf_app} in ids.(
             Observability.child_specs(:pf_app, param_filter: false)
           )
  end
end

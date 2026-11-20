defmodule Samen.ApiKeyDigestUniqueTemplateTest do
  @moduledoc """
  The generated app's FIRST migration (`--api`: the operator Identity mount) puts a UNIQUE index on the API-key token
  digest, as it does for the session, auth-token and invitation digests. The auth lookup assumes one row per digest;
  a duplicate made it error (503). The hosts' retrofit migrations are proven live in each host's own suite.
  """
  use ExUnit.Case, async: true

  alias Samen.Gen.App, as: Gen

  defp mount_migration do
    b = Gen.bindings(Gen.build_spec(module: "Acme", prefix: "ac", abbrev: "acm", target: Gen.default_target(), web: true, api: true))

    Enum.find_value(Samen.Gen.Templates.files(true, true, false), fn {path, template} ->
      if Gen.render(path, b) =~ ~r{migrations/\d+_mount_operator_scopes\.exs$}, do: Gen.render(template, b)
    end)
  end

  test "the generated mount migration builds a unique index on the api key's token digest" do
    src = mount_migration()
    assert is_binary(src)

    assert [[_, table, col]] =
             Regex.scan(~r/create\(unique_index\(:(\w+_api_key), \[:(\w+_token_digest)\]\)\)/, src)

    # the index is on the very table and column the api_key table creates (not a neighbour's)
    assert src =~ "create table(:#{table}, primary_key: false) do"
    assert src =~ "add(:#{col}, :text, null: false)"
  end

  test "POSITIVE CONTROL: the other credential digests of the same migration are unique too" do
    src = mount_migration()
    assert src =~ ~r/create\(unique_index\(:\w+_auth_token, \[:\w+_token_digest\]\)\)/
    assert src =~ ~r/create\(unique_index\(:\w+_session, \[:\w+_token_digest\]\)\)/
  end
end

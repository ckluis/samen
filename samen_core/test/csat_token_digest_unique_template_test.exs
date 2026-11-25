defmodule Samen.CsatTokenDigestUniqueTemplateTest do
  @moduledoc """
  The generated app's FIRST migration (`--web`: the operator scopes mount) puts a UNIQUE index on the CSAT survey-token
  digest. `preview` reads the row by digest with `limit(1)` and `respond` consumes by digest, so one row per digest is an
  invariant. Apps generated earlier get `mix samen.gen.csat_token_digest_unique`; the hosts' retrofit migrations are proven
  live in each host's own suite.
  """
  use ExUnit.Case, async: true

  alias Samen.Gen.App, as: Gen

  defp mount_migration do
    b = Gen.bindings(Gen.build_spec(module: "Acme", prefix: "ac", abbrev: "acm", target: Gen.default_target(), web: true, api: true))

    Enum.find_value(Samen.Gen.Templates.files(true, true, false), fn {path, template} ->
      if Gen.render(path, b) =~ ~r{migrations/\d+_mount_operator_scopes\.exs$}, do: Gen.render(template, b)
    end)
  end

  test "the generated mount migration builds a UNIQUE index on the survey token's digest, on its own table and column" do
    src = mount_migration()
    assert is_binary(src)

    assert [[_, table, col]] =
             Regex.scan(~r/create\(unique_index\(:(\w+_csat_survey_token), \[:(\w+_token_digest)\]/, src)

    assert src =~ "create table(:#{table}, primary_key: false) do"
    assert src =~ "add(:#{col}, :text, null: false)"
    # and no plain index is left to shadow it
    refute src =~ ~r/create\(index\(:\w+_csat_survey_token, \[:\w+_token_digest\]/
  end

  test "POSITIVE CONTROL: the same migration's api-key digest index is unique too (the matcher is not vacuous)" do
    assert mount_migration() =~ ~r/create\(unique_index\(:\w+_api_key, \[:\w+_token_digest\]\)\)/
  end

  test "the generator's skip rule recognises the template's own unique index, so a freshly generated app needs no retrofit" do
    src = mount_migration()
    [[_, table, col]] = Regex.scan(~r/create\(unique_index\(:(\w+_csat_survey_token), \[:(\w+_token_digest)\]/, src)
    dir = Path.join(System.tmp_dir!(), "samen_csat_tpl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "20260101000000_mount_operator_scopes.exs"), src)

    out =
      ExUnit.CaptureIO.capture_io(fn ->
        send(self(), {:r, Mix.Tasks.Samen.Gen.ApiKeyDigestUnique.generate(Samen.CsatTokenDigestUniqueTemplateTest, [{table, col}], dir, "20261120100000", :csat)})
      end)

    assert_received {:r, nil}
    assert out =~ "already has a unique index"
  end
end

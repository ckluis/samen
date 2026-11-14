defmodule PawChart.AnalyticsNonPiiSetupTest do
  @moduledoc """
  A non-PII registration that fails leaves a plaintext column out of the erasure redaction carve-out, so
  `register_all/1` returns the error (it used to answer `:ok`). Positive control: the real repo registers.
  """
  use PawChart.DataCase, async: false

  defmodule DownRepo do
    @moduledoc false
    def insert(_changeset, _opts), do: {:error, :db_down}
  end

  test "RED: a failing registration is an {:error, _}, not :ok" do
    assert {:error, :db_down} = PawChart.Analytics.NonPiiSetup.register_all(repo: DownRepo)
  end

  test "POSITIVE CONTROL: with the real repo it registers" do
    assert :ok = PawChart.Analytics.NonPiiSetup.register_all()
  end
end

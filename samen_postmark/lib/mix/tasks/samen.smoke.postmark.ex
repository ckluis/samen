defmodule Mix.Tasks.Samen.Smoke.Postmark do
  @moduledoc """
  ADR-038 §7.4 — the operator-added, NO-CREDENTIAL Postmark real-HTTP smoke
  lane (T27 owns this task). Postmark's real API accepts the public literal
  server token `POSTMARK_API_TEST`: requests validate and return success, and
  NOTHING is delivered.

  Gated by `SAMEN_POSTMARK_SMOKE=1` (never runs in `ci.sh`/`ci-fast.sh` — an
  offline machine must not flake the default suites). Prints and exit-codes
  exactly one of three terminal states:

    * `POSTMARK-SMOKE: PASSED` — real HTTP round-trip to `api.postmarkapp.com`
      succeeded (exit 0).
    * `POSTMARK-SMOKE: SKIPPED (offline: <reason>)` — a connect/DNS failure was
      detected (exit 0 — an HONEST skip, never reported as passed).
    * `POSTMARK-SMOKE: FAILED (<reason>)` — the API was reachable but the
      adapter's request/response handling is wrong (exit 1).

  Usage: `SAMEN_POSTMARK_SMOKE=1 mix samen.smoke.postmark`
  """
  use Mix.Task

  @shortdoc "Postmark POSTMARK_API_TEST no-credential smoke (SAMEN_POSTMARK_SMOKE=1)"

  @impl Mix.Task
  def run(_args) do
    if System.get_env("SAMEN_POSTMARK_SMOKE") == "1" do
      Mix.Task.run("app.start")
      do_smoke()
    else
      Mix.shell().info(
        "POSTMARK-SMOKE: SKIPPED (gate not set — set SAMEN_POSTMARK_SMOKE=1 to run this lane)"
      )
    end
  end

  defp do_smoke do
    body = %{
      "From" => "smoke-test@example.com",
      "To" => "smoke-test@example.com",
      "Subject" => "samen_postmark smoke (SAMEN_POSTMARK_SMOKE)",
      "TextBody" => "POSTMARK_API_TEST probe — validates, nothing delivered.",
      "MessageStream" => "outbound"
    }

    "POSTMARK_API_TEST"
    |> then(&%{server_token: &1, body: body})
    |> SamenPostmark.Transport.live()
    |> report()
  end

  defp report({:ok, %{status: 200, body: %{"ErrorCode" => 0}}}) do
    Mix.shell().info("POSTMARK-SMOKE: PASSED")
  end

  defp report({:ok, %{status: status, body: resp_body}}) do
    Mix.shell().info("POSTMARK-SMOKE: FAILED (unexpected status=#{status} body=#{inspect(resp_body)})")
    exit({:shutdown, 1})
  end

  defp report({:error, reason}) do
    if offline_reason?(reason) do
      Mix.shell().info("POSTMARK-SMOKE: SKIPPED (offline: #{inspect(reason)})")
    else
      Mix.shell().info("POSTMARK-SMOKE: FAILED (#{inspect(reason)})")
      exit({:shutdown, 1})
    end
  end

  # Robust to the exact transport-error shape (Mint/Finch wrap differently
  # across versions) — pattern-match the common atoms, fall back to a string
  # scan of the inspected reason for the network-failure vocabulary.
  defp offline_reason?(reason) do
    text = inspect(reason) |> String.downcase()

    Enum.any?(
      ~w(nxdomain timeout econnrefused closed non_existing_domain enetunreach ehostunreach),
      &String.contains?(text, &1)
    )
  end
end

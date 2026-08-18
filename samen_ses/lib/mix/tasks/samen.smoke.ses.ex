defmodule Mix.Tasks.Samen.Smoke.Ses do
  @moduledoc """
  ADR-038 §7.1 lane 2 — the operator-gated, REAL-CREDENTIAL SES live-smoke
  lane (T94 documents + wires it; per-adapter live smoke is not a T94-owned
  no-credential lane the way Postmark's `POSTMARK_API_TEST` is, §7.4 — SES has
  no public test-mode token, so this lane genuinely needs real AWS creds).

  Gated by `SAMEN_ESP_LIVE=1` (never runs in `ci.sh`/`ci-fast.sh` — an offline
  or credential-less machine must not flake the default suites). Sends ONE
  real email via `SamenSes.Transport.live/1` to a sink address you control.

  Required env when the gate is set:

    * `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`
    * `SAMEN_SES_SMOKE_FROM` — a SES-verified sending address
    * `SAMEN_SES_SMOKE_TO` — a SES-verified (sandbox) or allowed recipient

  Prints and exit-codes exactly one of three terminal states:

    * `SES-SMOKE: PASSED` (exit 0) — a real `SendEmail` round-trip to
      `email.<region>.amazonaws.com` succeeded (a `MessageId` came back).
    * `SES-SMOKE: SKIPPED (<reason>)` (exit 0) — the gate is off, required env
      is missing, or a connect/DNS failure was detected — an HONEST skip,
      never reported as passed.
    * `SES-SMOKE: FAILED (<reason>)` (exit 1) — reachable but the adapter's
      request/response handling is wrong, or SES rejected the send.

  Usage: `SAMEN_ESP_LIVE=1 mix samen.smoke.ses`
  """
  use Mix.Task

  @shortdoc "AWS SES real-credential live smoke (SAMEN_ESP_LIVE=1)"

  @impl Mix.Task
  def run(_args) do
    if System.get_env("SAMEN_ESP_LIVE") == "1" do
      Mix.Task.run("app.start")
      do_smoke()
    else
      Mix.shell().info("SES-SMOKE: SKIPPED (gate not set — set SAMEN_ESP_LIVE=1 to run this lane)")
    end
  end

  defp do_smoke do
    with {:ok, creds} <- required_env() do
      request = %{
        access_key_id: creds.access_key_id,
        secret_access_key: creds.secret_access_key,
        region: creds.region,
        from: creds.from,
        to_email: creds.to,
        subject: "samen_ses smoke (SAMEN_ESP_LIVE)",
        text_body: "SAMEN_ESP_LIVE probe from mix samen.smoke.ses — real SES send."
      }

      request |> SamenSes.Transport.live() |> report()
    else
      {:error, reason} ->
        Mix.shell().info("SES-SMOKE: SKIPPED (#{reason})")
    end
  end

  defp required_env do
    with {:ok, access_key_id} <- fetch_env("AWS_ACCESS_KEY_ID"),
         {:ok, secret_access_key} <- fetch_env("AWS_SECRET_ACCESS_KEY"),
         {:ok, region} <- fetch_env("AWS_REGION"),
         {:ok, from} <- fetch_env("SAMEN_SES_SMOKE_FROM"),
         {:ok, to} <- fetch_env("SAMEN_SES_SMOKE_TO") do
      {:ok, %{access_key_id: access_key_id, secret_access_key: secret_access_key, region: region, from: from, to: to}}
    end
  end

  defp fetch_env(name) do
    case System.get_env(name) do
      nil -> {:error, "missing required env #{name}"}
      "" -> {:error, "missing required env #{name}"}
      value -> {:ok, value}
    end
  end

  defp report({:ok, %{status: status, body: %{"MessageId" => id}}}) when status in 200..201 and is_binary(id) do
    Mix.shell().info("SES-SMOKE: PASSED (MessageId=#{id})")
  end

  defp report({:ok, %{status: status, body: resp_body}}) do
    Mix.shell().info("SES-SMOKE: FAILED (unexpected status=#{status} body=#{inspect(resp_body)})")
    exit({:shutdown, 1})
  end

  defp report({:error, reason}) do
    if offline_reason?(reason) do
      Mix.shell().info("SES-SMOKE: SKIPPED (offline: #{inspect(reason)})")
    else
      Mix.shell().info("SES-SMOKE: FAILED (#{inspect(reason)})")
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

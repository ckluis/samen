defmodule Mix.Tasks.Samen.Smoke.Resend do
  @moduledoc """
  ADR-038 §7.1 lane 2 — the operator-gated, REAL-CREDENTIAL Resend live-smoke
  lane (T95 documents + wires it; per-adapter live smoke is not a
  no-credential lane the way Postmark's `POSTMARK_API_TEST` is, §7.4 — Resend
  has no public test-mode token, so this lane genuinely needs a real Resend
  API key).

  Gated by `SAMEN_ESP_LIVE=1` (never runs in `ci.sh`/`ci-fast.sh` — an offline
  or credential-less machine must not flake the default suites). Sends ONE
  real email via `SamenResend.Transport.live/1` to a sink address you control.

  Required env when the gate is set:

    * `RESEND_API_KEY` — a real Resend API key
    * `SAMEN_RESEND_SMOKE_FROM` — a Resend-verified sending address
    * `SAMEN_RESEND_SMOKE_TO` — an allowed recipient address

  Prints and exit-codes exactly one of three terminal states:

    * `RESEND-SMOKE: PASSED` (exit 0) — a real `POST /emails` round-trip to
      api.resend.com succeeded (an `id` came back).
    * `RESEND-SMOKE: SKIPPED (<reason>)` (exit 0) — the gate is off, required
      env is missing, or a connect/DNS failure was detected — an HONEST skip,
      never reported as passed.
    * `RESEND-SMOKE: FAILED (<reason>)` (exit 1) — reachable but the
      adapter's request/response handling is wrong, or Resend rejected the
      send.

  Usage: `SAMEN_ESP_LIVE=1 mix samen.smoke.resend`
  """
  use Mix.Task

  @shortdoc "Resend real-credential live smoke (SAMEN_ESP_LIVE=1)"

  @impl Mix.Task
  def run(_args) do
    if System.get_env("SAMEN_ESP_LIVE") == "1" do
      Mix.Task.run("app.start")
      do_smoke()
    else
      Mix.shell().info("RESEND-SMOKE: SKIPPED (gate not set — set SAMEN_ESP_LIVE=1 to run this lane)")
    end
  end

  defp do_smoke do
    with {:ok, creds} <- required_env() do
      request = %{
        api_key: creds.api_key,
        from: creds.from,
        to_email: creds.to,
        subject: "samen_resend smoke (SAMEN_ESP_LIVE)",
        text_body: "SAMEN_ESP_LIVE probe from mix samen.smoke.resend — real Resend send."
      }

      request |> SamenResend.Transport.live() |> report()
    else
      {:error, reason} ->
        Mix.shell().info("RESEND-SMOKE: SKIPPED (#{reason})")
    end
  end

  defp required_env do
    with {:ok, api_key} <- fetch_env("RESEND_API_KEY"),
         {:ok, from} <- fetch_env("SAMEN_RESEND_SMOKE_FROM"),
         {:ok, to} <- fetch_env("SAMEN_RESEND_SMOKE_TO") do
      {:ok, %{api_key: api_key, from: from, to: to}}
    end
  end

  defp fetch_env(name) do
    case System.get_env(name) do
      nil -> {:error, "missing required env #{name}"}
      "" -> {:error, "missing required env #{name}"}
      value -> {:ok, value}
    end
  end

  defp report({:ok, %{status: status, body: %{"id" => id}}}) when status in 200..201 and is_binary(id) do
    Mix.shell().info("RESEND-SMOKE: PASSED (id=#{id})")
  end

  defp report({:ok, %{status: status, body: resp_body}}) do
    Mix.shell().info("RESEND-SMOKE: FAILED (unexpected status=#{status} body=#{inspect(resp_body)})")
    exit({:shutdown, 1})
  end

  defp report({:error, reason}) do
    if offline_reason?(reason) do
      Mix.shell().info("RESEND-SMOKE: SKIPPED (offline: #{inspect(reason)})")
    else
      Mix.shell().info("RESEND-SMOKE: FAILED (#{inspect(reason)})")
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

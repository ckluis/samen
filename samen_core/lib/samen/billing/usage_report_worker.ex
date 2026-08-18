defmodule Samen.Billing.UsageReportWorker do
  @moduledoc """
  Oban wrapper for `Samen.Billing.UsageReporter.report_pending/1` (B8; T25).

  Resolves the provider + usage-mirror port from HOST config — the SAME
  `Application.get_env(:samen_core, ...)` resolution shape
  `Samen.Billing.WebhookDispatch` uses for its own config slots (vendor-free,
  INV-4; this module names no vendor):

      config :samen_core, :billing_provider, {MyApp.BillingAdapter.Provider, %{secret_key: "sk_...", ...}}
      config :samen_core, :billing_usage_mirror, {MyApp.UsageMirror, mirror_ref}

  Either slot unwired ⇒ an honest `:ok` no-op — the same "host not running this
  yet" posture every other billing config slot has
  (`Samen.Billing.WebhookDispatch` moduledoc). `Samen.Billing.UsageReporter`'s own
  `{:error, :not_configured}` (a WIRED-but-unconfigured provider — e.g. no
  `secret_key` set) also resolves to `:ok` here for the SAME reason: Oban would
  otherwise retry-then-DLQ a job that can never succeed until an operator adds
  credentials, which is noise, not a transient failure to page on. A genuine
  transient provider error (`{:error, other_reason}`) DOES propagate as
  `{:error, reason}` so Oban's retry/backoff/DLQ policy applies — the pending
  usage records are untouched either way (`Samen.Billing.UsageReporter`'s own
  no-data-loss contract), so a retry is always safe.

  ## Scheduling (host-owned; NOT wired into `Samen.Jobs.default_crontab/0`)

  This worker is deliberately NOT added to the shared cron taxonomy — doing so
  would change every existing host's (demo/driftwood/pawchart) job schedule
  whether or not they run samen billing usage metering. A host that wants
  periodic reporting adds its own crontab entry:

      config :my_app, Oban,
        plugins: [
          {Oban.Plugins.Cron,
           crontab: Samen.Jobs.default_crontab() ++ [{"*/15 * * * *", Samen.Billing.UsageReportWorker}]}
        ]

  or enqueues manually: `Samen.Billing.UsageReportWorker.new(%{}) |> Oban.insert()`.
  """

  use Oban.Worker, queue: :default, max_attempts: 20, unique: [period: 60]

  alias Samen.Billing.UsageReporter

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    with {:ok, provider, provider_config} <- billing_provider(),
         {:ok, usage_mirror, usage_mirror_ref} <- billing_usage_mirror() do
      case UsageReporter.report_pending(
             provider: provider,
             provider_config: provider_config,
             usage_mirror: usage_mirror,
             usage_mirror_ref: usage_mirror_ref
           ) do
        {:ok, _result} -> :ok
        {:error, :not_configured} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :not_configured -> :ok
    end
  end

  defp billing_provider do
    case Application.get_env(:samen_core, :billing_provider) do
      {module, config} when is_atom(module) and is_map(config) -> {:ok, module, config}
      module when is_atom(module) and not is_nil(module) -> {:ok, module, %{}}
      _ -> :not_configured
    end
  end

  defp billing_usage_mirror do
    case Application.get_env(:samen_core, :billing_usage_mirror) do
      {module, ref} when is_atom(module) -> {:ok, module, ref}
      _ -> :not_configured
    end
  end
end

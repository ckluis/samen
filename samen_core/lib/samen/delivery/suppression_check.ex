defmodule Samen.Delivery.SuppressionCheck do
  @moduledoc """
  The PRODUCTION `Samen.Delivery.Chokepoint` `suppression_module` implementation
  (ADR-038 §4.3/§4.4; C4, T30) — closes the GAP T28 named: "no production host
  wires a real backing store for non-marketing families yet — mechanism proven
  via a test-injected fake only."

  Backed by `Samen.Delivery.Suppression` (the `dlv_suppression` kernel table).
  Wire it as:

      config :samen_core, Samen.Delivery.Chokepoint, suppression_module: Samen.Delivery.SuppressionCheck
      config :samen_core, Samen.Delivery.SuppressionCheck, repo: MyApp.Repo

  ## Fail-honest repo resolution

  `suppressed?/2` is called by the Chokepoint with EXACTLY `(org_id,
  subscriber_id)` — no `opts`, so the repo can only come from config (mirrors
  `Samen.Webhook.IngestWorker`'s config-driven repo resolution). An UNCONFIGURED
  repo RAISES — which the Chokepoint's `suppressed?/2` catches and treats as
  fail-CLOSED (refusing the send): a suppression module that is wired but
  cannot actually check is exactly the "broken check must never silently let a
  send through" case the Chokepoint moduledoc documents, not a silent open.
  """

  alias Samen.Delivery.Suppression

  @doc "The Chokepoint `suppression_module` contract: `suppressed?(org_id, subscriber_id)`."
  @spec suppressed?(String.t() | nil, String.t() | nil) :: boolean()
  def suppressed?(org_id, subscriber_id) when is_binary(org_id) and is_binary(subscriber_id) do
    Suppression.suppressed?(repo!(), org_id, subscriber_id)
  end

  def suppressed?(_org_id, _subscriber_id), do: false

  defp repo!, do: Application.get_env(:samen_core, __MODULE__, [])[:repo] || raise_unconfigured!()

  defp raise_unconfigured! do
    raise "Samen.Delivery.SuppressionCheck is wired as the Chokepoint suppression_module but " <>
            "has no :repo configured (config :samen_core, Samen.Delivery.SuppressionCheck, repo: MyApp.Repo)"
  end
end

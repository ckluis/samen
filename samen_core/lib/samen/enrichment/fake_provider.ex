defmodule Samen.Enrichment.FakeProvider do
  @moduledoc """
  The core, call-recording **enrichment test double** (spec §I8, T80). Mirrors
  `Samen.Delivery.FakeProvider` and `Samen.Mailbox.FakeProvider`'s honesty
  discipline exactly: unconfigured refuses every callback except `configured?/1`,
  `capabilities/0` and `redact_payload/1`; a configured fake genuinely records
  and returns fake-tagged enrichment data.

  This is the provider CI uses. It makes enrichment loop provable without a single
  vendor credential: a test seeds the fake enrichment, `Samen.Enrichment` reads it,
  and the data lands on the Person/Company record — exactly as a real external
  adapter would.

  ## Configuring the fake

      FakeProvider.reset()
      FakeProvider.configured?(%{})                  # => false (honest default refuse)
      FakeProvider.configured?(%{configured: true})  # => true
      FakeProvider.set_capabilities([:person_enrich, :company_enrich])
      FakeProvider.seed_enrichment(:person, 42, %{title: "VP", company: "Acme"})

  All state is process-local (the same idiom `Samen.Delivery.FakeProvider` uses),
  so `capabilities/0` can stay argument-free and match the real callback shape.
  """

  use Samen.Enrichment.Provider

  @calls_key :enrichment_fake_provider_calls
  @caps_key :enrichment_fake_provider_capabilities
  @data_key :enrichment_fake_provider_data

  # ---------------------------------------------------------------------------
  # Provider callbacks

  @impl true
  def configured?(config) when is_map(config), do: Map.get(config, :configured) == true
  def configured?(_), do: false

  @impl true
  def capabilities, do: Process.get(@caps_key, [])

  @impl true
  def enrich(subject_type, subject_id, config) when subject_type in [:person, :company] do
    required_capability = case subject_type do
      :person -> :person_enrich
      :company -> :company_enrich
    end

    if required_capability in capabilities() do
      guarded(:enrich, %{subject_type: subject_type, subject_id: subject_id}, config, fn ->
        data = Process.get(@data_key, %{})
        key = {subject_type, subject_id}
        enriched = Map.get(data, key, %{})

        {:ok, enriched}
      end)
    else
      {:error, :not_implemented}
    end
  end

  @impl true
  def redact_payload(payload) when is_map(payload) do
    Map.drop(payload, [:api_key, "api_key", :token, "token", :secret, "secret"])
  end

  # ---------------------------------------------------------------------------
  # Test-facing controls

  @doc "All recorded `{callback, args}` calls for the current process."
  def calls, do: Process.get(@calls_key, [])

  @doc "Seed fake enrichment data for a subject (person or company)."
  def seed_enrichment(subject_type, subject_id, enriched_map) when subject_type in [:person, :company] do
    data = Process.get(@data_key, %{})
    key = {subject_type, subject_id}
    Process.put(@data_key, Map.put(data, key, enriched_map))
    :ok
  end

  @doc "Set the capability list `capabilities/0` reports for the current process."
  def set_capabilities(caps) when is_list(caps), do: Process.put(@caps_key, caps)

  @doc "Clear every piece of process-local fake state."
  def reset do
    Enum.each([@calls_key, @caps_key, @data_key], &Process.delete/1)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private

  defp guarded(callback, args, config, ok_fun) do
    if configured?(config) do
      record_call(callback, args)
      ok_fun.()
    else
      {:error, :not_configured}
    end
  end

  defp record_call(callback, args),
    do: Process.put(@calls_key, [{callback, args} | Process.get(@calls_key, [])])
end

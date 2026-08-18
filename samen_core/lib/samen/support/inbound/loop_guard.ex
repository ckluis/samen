defmodule Samen.Support.Inbound.LoopGuard do
  @moduledoc """
  Mail-loop / autoresponder suppression for inbound email (T59, must-have). Inbound
  email loops are a real outage & cost hazard: two autoresponders bouncing "out of
  office" at each other create infinite tickets and infinite auto-replies. RFC 3834
  (auto-response) and long-standing operational practice define the header signals
  that mark a message as machine-generated; we refuse to CREATE a ticket or send an
  auto-reply for any of them.

  `classify/2` returns `:deliver` for genuine human mail, or `{:suppress, reason}` for
  a loop/auto signal. A suppressed message is NEVER silently dropped — the caller
  (`Samen.Support.Inbound.Ingest`) records the disposition — it is simply not turned
  into a ticket and never triggers an auto-reply (which is the loop-breaker).

  ## Signals (each independently tested)

    * `Auto-Submitted:` present and not `no` (RFC 3834 — `auto-generated`/`auto-replied`).
    * `Precedence:` in `bulk | list | junk | auto_reply` (classic bulk/list mail marker).
    * `X-Auto-Response-Suppress:` present (Microsoft; the sender itself asks for no auto-reply).
    * `From:` local-part is a system mailbox (`mailer-daemon`, `postmaster`, `noreply`,
      `no-reply`, `donotreply`, `bounce…`) — bounce/DSN traffic.
    * `From:` is OUR OWN sending domain or address (`config.our_domains`/`our_addresses`)
      — the reflexive case: we must never auto-respond to our own outbound/auto-reply.

  All header lookups are case-insensitive on the header NAME (headers arrive as a map
  from the adapter) and tolerant of missing/`nil`/non-binary values (no crash).
  """

  alias Samen.Support.Inbound.Config

  @precedence_loop ~w(bulk list junk auto_reply auto-reply)
  @system_localparts ~w(mailer-daemon postmaster noreply no-reply donotreply do-not-reply)

  @type reason ::
          :auto_submitted | :precedence_bulk | :auto_response_suppress | :system_sender | :own_identity

  @spec classify(map(), Config.t()) :: :deliver | {:suppress, reason()}
  def classify(parsed, %Config{} = config) when is_map(parsed) do
    headers = Map.get(parsed, :headers) || %{}
    # `Parse.normalize/2` already extracts a bare, downcased sender address.
    from = normalize_addr(Map.get(parsed, :from_address) || Map.get(parsed, :from))

    cond do
      auto_submitted?(headers) -> {:suppress, :auto_submitted}
      precedence_loop?(headers) -> {:suppress, :precedence_bulk}
      auto_response_suppress?(headers) -> {:suppress, :auto_response_suppress}
      system_sender?(from) -> {:suppress, :system_sender}
      own_identity?(from, config) -> {:suppress, :own_identity}
      true -> :deliver
    end
  end

  # --- signal predicates -----------------------------------------------------

  defp auto_submitted?(headers) do
    case header(headers, "auto-submitted") do
      nil -> false
      v -> String.trim(String.downcase(v)) != "no"
    end
  end

  defp precedence_loop?(headers) do
    case header(headers, "precedence") do
      nil -> false
      v -> String.trim(String.downcase(v)) in @precedence_loop
    end
  end

  defp auto_response_suppress?(headers), do: header(headers, "x-auto-response-suppress") != nil

  defp system_sender?(nil), do: false

  defp system_sender?(addr) do
    local = addr |> String.split("@") |> List.first() |> to_string()
    local in @system_localparts or String.starts_with?(local, "bounce")
  end

  defp own_identity?(nil, _config), do: false

  defp own_identity?(addr, %Config{our_addresses: addrs, our_domains: domains}) do
    domain = addr |> String.split("@") |> List.last() |> to_string()
    addr in addrs or (domain != "" and domain in domains)
  end

  # --- helpers ---------------------------------------------------------------

  # Case-insensitive header lookup over a %{name => value} map; nil-safe.
  defp header(headers, name) when is_map(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if is_binary(k) and String.downcase(k) == name and is_binary(v), do: v, else: nil
    end)
  end

  defp header(_headers, _name), do: nil

  defp normalize_addr(nil), do: nil

  defp normalize_addr(addr) when is_binary(addr) do
    # A `From` can be `Display Name <a@b.com>` — extract the angle-addr if present.
    case Regex.run(~r/<([^>]+)>/, addr) do
      [_, inner] -> String.downcase(String.trim(inner))
      _ -> addr |> String.trim() |> String.downcase()
    end
  end

  defp normalize_addr(_), do: nil
end

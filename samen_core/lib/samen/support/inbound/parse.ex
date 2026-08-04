defmodule Samen.Support.Inbound.Parse do
  @moduledoc """
  Harden an adapter-normalized `Samen.Delivery.InboundMessage` into a bounded, safe
  internal shape (T59). **Every field of an inbound email is hostile** — this module
  treats a malformed / missing / oversized / wrong-typed field as expected input and
  NEVER crashes and NEVER retains unbounded memory:

    * oversized `subject` / bodies / header values are TRUNCATED to the caps in
      `Samen.Support.Inbound.Config` (no unbounded copy into a ticket);
    * a `from` that is `Display Name <addr@host>` is split into a normalized bare
      address + a raw display name (neither is trusted — the display name is
      sanitized downstream, the address is only ever compared, never rendered raw);
    * `In-Reply-To` / `References` are parsed into a bounded list of angle-addr
      message-ids for threading (see `Samen.Support.Inbound.Threading`);
    * non-binary / nil / non-list fields coerce to safe defaults.

  The output is a plain map (not persisted here) consumed by `LoopGuard`, `Threading`,
  and `Ingest`.
  """

  alias Samen.Delivery.InboundMessage
  alias Samen.Support.Inbound.Config

  # Never parse more than this many message-ids out of a References chain (a hostile
  # References header could list thousands — bound the work).
  @max_reference_ids 50

  @type t :: %{
          message_id: String.t() | nil,
          from_address: String.t() | nil,
          from_display: String.t() | nil,
          to: [String.t()],
          subject: String.t() | nil,
          text_body: String.t() | nil,
          html_body: String.t() | nil,
          headers: map(),
          in_reply_to: String.t() | nil,
          references: [String.t()],
          attachments: list()
        }

  @spec normalize(InboundMessage.t(), Config.t()) :: t()
  def normalize(%InboundMessage{} = msg, %Config{} = config) do
    headers = safe_headers(msg.headers, config.max_header_value_bytes)

    %{
      message_id: msg.message_id |> safe_binary() |> angle_addr(),
      from_address: extract_address(msg.from),
      from_display: extract_display(msg.from, msg.from_name),
      to: safe_list(msg.to),
      subject: msg.subject |> safe_binary() |> truncate(config.max_subject_bytes),
      text_body: msg.text_body |> safe_binary() |> truncate(config.max_body_bytes),
      html_body: msg.html_body |> safe_binary() |> truncate(config.max_body_bytes),
      headers: headers,
      in_reply_to: headers |> header("in-reply-to") |> first_message_id(),
      references: headers |> header("references") |> message_ids(),
      attachments: safe_attachments(msg.attachments)
    }
  end

  # --- address / display extraction ------------------------------------------

  @doc "Extract a bare, downcased email address from a `From`-style value (nil-safe)."
  @spec extract_address(term()) :: String.t() | nil
  def extract_address(from) when is_binary(from) do
    # Prefer an angle-addr that actually contains `@` — a hostile display name can carry
    # its own `<…>` (e.g. embedded `<script>`), so never blindly trust the FIRST `<…>`.
    angle_addr =
      Regex.scan(~r/<([^>]+)>/, from)
      |> Enum.map(fn [_, inner] -> inner end)
      |> Enum.find(&String.contains?(&1, "@"))

    cond do
      is_binary(angle_addr) -> normalize_email(angle_addr)
      true -> from |> String.trim() |> first_at_token() |> normalize_email()
    end
  end

  def extract_address(_), do: nil

  defp normalize_email(""), do: nil

  defp normalize_email(s) when is_binary(s) do
    s = s |> String.trim() |> String.downcase() |> truncate(320)
    if String.contains?(s, "@") and s != "", do: s, else: nil
  end

  defp normalize_email(_), do: nil

  # A `From` without angle brackets may still carry trailing junk — take the first
  # whitespace-delimited token that looks like an address (has `@`), else the first token.
  defp first_at_token(s) do
    tokens = String.split(s, ~r/\s+/, trim: true)
    Enum.find(tokens, List.first(tokens), &String.contains?(&1, "@")) |> to_string()
  end

  # Prefer the explicit adapter `from_name`; else the display part before `<addr>`.
  defp extract_display(from, from_name) do
    cond do
      is_binary(from_name) and String.trim(from_name) != "" ->
        from_name |> String.trim() |> truncate(998)

      is_binary(from) ->
        case Regex.run(~r/^(.*?)<[^>]+>/, from) do
          [_, name] -> name |> String.trim() |> unquote_name() |> nil_if_empty() |> maybe_truncate()
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp unquote_name(s), do: s |> String.trim() |> String.trim("\"")
  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s
  defp maybe_truncate(nil), do: nil
  defp maybe_truncate(s), do: truncate(s, 998)

  # --- headers ---------------------------------------------------------------

  defp safe_headers(headers, cap) when is_map(headers) do
    headers
    |> Enum.reduce(%{}, fn
      {k, v}, acc when is_binary(k) and is_binary(v) -> Map.put(acc, k, truncate(v, cap))
      _, acc -> acc
    end)
  end

  defp safe_headers(_, _cap), do: %{}

  # Case-insensitive header read.
  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} ->
      if is_binary(k) and String.downcase(k) == name, do: v, else: nil
    end)
  end

  # --- message-id parsing ----------------------------------------------------

  # A References/In-Reply-To header is a whitespace-separated list of `<id@host>`.
  defp message_ids(nil), do: []

  defp message_ids(value) when is_binary(value) do
    Regex.scan(~r/<([^>]+)>/, value)
    |> Enum.map(fn [_, id] -> normalize_msgid(id) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@max_reference_ids)
  end

  defp message_ids(_), do: []

  defp first_message_id(nil), do: nil
  defp first_message_id(value), do: value |> message_ids() |> List.first()

  # An adapter may hand us a Message-ID with or without the angle brackets; store the
  # inner id, downcased+bounded, as the join key.
  defp angle_addr(nil), do: nil

  defp angle_addr(v) when is_binary(v) do
    case Regex.run(~r/<([^>]+)>/, v) do
      [_, inner] -> normalize_msgid(inner)
      _ -> normalize_msgid(v)
    end
  end

  defp normalize_msgid(s) when is_binary(s) do
    s = s |> String.trim() |> String.downcase() |> truncate(998)
    if s == "", do: nil, else: s
  end

  defp normalize_msgid(_), do: nil

  # --- misc safety -----------------------------------------------------------

  defp safe_list(list) when is_list(list),
    do: list |> Enum.filter(&is_binary/1) |> Enum.map(&(&1 |> String.trim() |> truncate(320)))

  defp safe_list(str) when is_binary(str),
    do: str |> String.split(",") |> Enum.map(&String.trim/1) |> safe_list()

  defp safe_list(_), do: []

  defp safe_attachments(list) when is_list(list), do: list
  defp safe_attachments(_), do: []

  defp safe_binary(v) when is_binary(v), do: v
  defp safe_binary(_), do: nil

  # Byte-bounded truncation (valid-UTF8-preserving via graphemes fallback).
  defp truncate(nil, _cap), do: nil

  defp truncate(s, cap) when is_binary(s) do
    if byte_size(s) <= cap do
      s
    else
      s |> binary_part(0, cap) |> valid_prefix()
    end
  end

  # binary_part may cut mid-codepoint; trim back to the last valid UTF-8 boundary.
  defp valid_prefix(bin) do
    if String.valid?(bin) do
      bin
    else
      # drop trailing bytes until valid (at most 3 iterations for UTF-8)
      size = byte_size(bin)
      Enum.reduce_while(1..3, bin, fn n, _acc ->
        candidate = binary_part(bin, 0, max(size - n, 0))
        if String.valid?(candidate), do: {:halt, candidate}, else: {:cont, candidate}
      end)
    end
  end
end

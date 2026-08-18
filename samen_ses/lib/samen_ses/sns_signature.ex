defmodule SamenSes.SnsSignature do
  @moduledoc """
  Real AWS SNS message-signature verification (ADR-038 §4.5/§4.1 "SNS notes"),
  the crypto half of `SamenSes.Provider.verify_and_parse_event/3`.

  SES bounce/complaint/delivery notifications arrive wrapped in an SNS
  envelope; SNS's security model is NOT a header HMAC/Basic-Auth scheme (the
  Postmark shape) — it is a per-message RSA signature (base64, PKCS#1 v1.5,
  SHA-1 for `SignatureVersion "1"` or SHA-256 for `"2"`) computed over a
  CANONICAL STRING built from specific envelope fields, verifiable against the
  X.509 certificate published at the envelope's own `SigningCertURL`.

  Real AWS docs, "Verifying the signatures of Amazon SNS messages":
  https://docs.aws.amazon.com/sns/latest/dg/sns-verify-signature-of-message.html

  ## Canonical string (binding field order — DO NOT reorder)

  For `Type == "Notification"`: `Message`, `MessageId`, `Subject` (ONLY if the
  envelope actually carries one), `Timestamp`, `TopicArn`, `Type` — each
  contributing two lines (`"<Field>\\n<Value>\\n"`).

  For `Type in ["SubscriptionConfirmation", "UnsubscribeConfirmation"]`:
  `Message`, `MessageId`, `SubscribeURL`, `Timestamp`, `Token`, `TopicArn`,
  `Type`.

  ## Hermeticity (ADR-038 §7.2, mirrors samen_postmark's `:transport` DI)

  Real signature verification needs the signing certificate, fetched over
  HTTPS from `SigningCertURL` — the adapter's `config[:cert_fetcher]` is an
  injectable `(url :: String.t() -> {:ok, pem :: binary()} | {:error, term()})`
  hook: production defaults to a REAL fetch (`fetch_cert/1`, domain-validated,
  §"SSRF guard" below); the fixture/conformance suite supplies a hermetic fake
  that hands back a PEM generated in-memory (an ephemeral self-signed test
  cert, `:public_key.pkix_test_data/1`) — proving the REAL RSA verify/canonical-
  string code path end to end without any network access in `mix test`.

  ## SSRF guard (`valid_sns_host?/1`)

  `SigningCertURL`/`SubscribeURL` are attacker-controlled fields inside an
  UNVERIFIED envelope at the point they'd otherwise be fetched — the real
  fetcher refuses any host that is not a genuine `sns.<region>.amazonaws.com`
  (or `.amazonaws.com.cn`) hostname BEFORE issuing the HTTP request, per AWS's
  own guidance. Red+control tested independently of network access.
  """

  @sns_host_rx ~r/^sns\.[a-z0-9\-]+\.amazonaws\.com(\.cn)?$/

  @doc """
  Verifies `envelope` (the JSON-decoded SNS body) against its own `Signature`
  using the public key extracted from the PEM the `cert_fetcher` returns for
  `envelope["SigningCertURL"]`. Returns `:ok` or `{:error, :invalid_signature}`
  — NEVER raises on attacker-controlled input (malformed fields fail closed).
  """
  @spec verify(map(), (String.t() -> {:ok, binary()} | {:error, term()})) ::
          :ok | {:error, :invalid_signature}
  def verify(%{} = envelope, cert_fetcher) when is_function(cert_fetcher, 1) do
    with {:ok, digest} <- digest_for_version(envelope["SignatureVersion"]),
         {:ok, signature} <- decode_signature(envelope["Signature"]),
         {:ok, cert_url} <- fetch_target(envelope["SigningCertURL"]),
         {:ok, pem} <- cert_fetcher.(cert_url),
         {:ok, public_key} <- public_key_from_pem(pem),
         string_to_sign when is_binary(string_to_sign) <- canonical_string(envelope) do
      if :public_key.verify(string_to_sign, digest, signature, public_key) do
        :ok
      else
        {:error, :invalid_signature}
      end
    else
      _ -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  end

  def verify(_envelope, _cert_fetcher), do: {:error, :invalid_signature}

  @doc "The AWS canonical string-to-sign for `envelope[\"Type\"]`. `nil` if the type is unrecognized."
  @spec canonical_string(map()) :: String.t() | nil
  def canonical_string(%{"Type" => "Notification"} = envelope) do
    [{"Message", envelope["Message"]}, {"MessageId", envelope["MessageId"]}]
    |> maybe_add("Subject", envelope["Subject"])
    |> Kernel.++([
      {"Timestamp", envelope["Timestamp"]},
      {"TopicArn", envelope["TopicArn"]},
      {"Type", envelope["Type"]}
    ])
    |> build_string()
  end

  def canonical_string(%{"Type" => type} = envelope)
      when type in ["SubscriptionConfirmation", "UnsubscribeConfirmation"] do
    [
      {"Message", envelope["Message"]},
      {"MessageId", envelope["MessageId"]},
      {"SubscribeURL", envelope["SubscribeURL"]},
      {"Timestamp", envelope["Timestamp"]},
      {"Token", envelope["Token"]},
      {"TopicArn", envelope["TopicArn"]},
      {"Type", envelope["Type"]}
    ]
    |> build_string()
  end

  def canonical_string(_envelope), do: nil

  defp maybe_add(fields, _key, nil), do: fields
  defp maybe_add(fields, key, value), do: fields ++ [{key, value}]

  defp build_string(fields) do
    if Enum.any?(fields, fn {_k, v} -> is_nil(v) end) do
      nil
    else
      Enum.map_join(fields, fn {k, v} -> "#{k}\n#{v}\n" end)
    end
  end

  defp digest_for_version("1"), do: {:ok, :sha}
  defp digest_for_version("2"), do: {:ok, :sha256}
  defp digest_for_version(_), do: :error

  defp decode_signature(sig) when is_binary(sig) do
    case Base.decode64(sig) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> :error
    end
  end

  defp decode_signature(_), do: :error

  defp fetch_target(url) when is_binary(url) do
    if valid_sns_host?(url), do: {:ok, url}, else: :error
  end

  defp fetch_target(_), do: :error

  @doc """
  `true` only for a genuine `sns.<region>.amazonaws.com`(.cn)? host — the SSRF
  guard applied to `SigningCertURL` BEFORE any fetch (real or injected).
  """
  @spec valid_sns_host?(String.t()) :: boolean()
  def valid_sns_host?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) -> Regex.match?(@sns_host_rx, host)
      _ -> false
    end
  end

  def valid_sns_host?(_), do: false

  @doc """
  Extracts the RSA public key from a PEM-encoded X.509 certificate (the real
  shape `SigningCertURL` serves). `{:error, :malformed_cert}` on anything else
  — never raises.
  """
  @spec public_key_from_pem(binary()) :: {:ok, tuple()} | {:error, :malformed_cert}
  def public_key_from_pem(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, _}] ->
        otp_cert = :public_key.pkix_decode_cert(der, :otp)
        tbs = elem(otp_cert, 1)
        spki = elem(tbs, 7)
        {:ok, elem(spki, 2)}

      _ ->
        {:error, :malformed_cert}
    end
  rescue
    _ -> {:error, :malformed_cert}
  end

  def public_key_from_pem(_), do: {:error, :malformed_cert}

  @doc """
  REAL (production) cert fetcher — an HTTPS GET of a pre-validated
  `sns.*.amazonaws.com` URL. Used as `Transport`'s default `:cert_fetcher`;
  tests always inject a hermetic fake (ADR-038 §7.2).
  """
  @spec fetch_live(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch_live(url) when is_binary(url) do
    if valid_sns_host?(url) do
      case Req.get(url) do
        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
        {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :untrusted_host}
    end
  end

  def fetch_live(_), do: {:error, :untrusted_host}
end

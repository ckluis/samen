defmodule Samen.AI.Agent.SecretsTest do
  @moduledoc """
  T184 — the secrets-redaction lane's own contract (unit floor), distinct from `pii_*`
  (ADR-047 §4.3b, PROPOSED). Mirrors `Samen.AI.Agent.IngressTest`'s discipline: every red
  pairs with a positive control, and non-reversibility is proven by exhibiting a collision,
  never asserted.
  """
  use ExUnit.Case, async: true

  alias Samen.AI.Agent.Secrets

  describe "known vendor-shaped prefixes redact" do
    test "AWS access key id" do
      assert redacted?("aws_access_key_id=AKIAIOSFODNN7EXAMPLE")
    end

    test "AWS STS temporary session key id" do
      assert redacted?("temp key ASIAABCDEFGHIJKLMNOP in the log line")
    end

    test "GitHub classic personal access token" do
      assert redacted?("token: ghp_" <> String.duplicate("a", 36))
    end

    test "GitHub fine-grained personal access token" do
      assert redacted?("github_pat_" <> String.duplicate("a", 30))
    end

    test "Slack bot token" do
      assert redacted?("xoxb-111111111111-222222222222-abcdefghijklmnopqrstuvwx")
    end

    test "Stripe live secret key" do
      assert redacted?("sk_live_" <> String.duplicate("a", 24))
    end

    test "generic sk- bearer-style secret key" do
      assert redacted?("sk-" <> String.duplicate("a", 30))
    end

    test "npm publish token" do
      assert redacted?("npm_" <> String.duplicate("a", 36))
    end

    test "Google API key" do
      assert redacted?("AIza" <> String.duplicate("a", 35))
    end

    test "PEM private-key header" do
      assert redacted?("-----BEGIN RSA PRIVATE KEY-----\nMIIEow...\n-----END RSA PRIVATE KEY-----")
    end

    test "a JWT" do
      jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
      assert redacted?(jwt)
    end

    test "an Authorization Bearer header value" do
      assert redacted?("Authorization: Bearer " <> String.duplicate("a", 30))
    end

    test "a Postgres connection string carrying embedded credentials" do
      assert redacted?("postgres://appuser:s3cr3t-pw@db.internal:5432/prod")
    end

    test "a MongoDB SRV connection string carrying embedded credentials" do
      assert redacted?("mongodb+srv://svc:hunter2@cluster0.example.mongodb.net/app")
    end

    test "POSITIVE CONTROL: a bare connection string with NO embedded credential passes through" do
      value = "postgres://db.internal:5432/prod"
      assert Secrets.redact(value) == value
    end
  end

  describe "the fail-closed generic labeled fallback: unrecognized-but-secret-shaped still redacts" do
    test "a labeled api_key with NO known vendor prefix redacts" do
      assert redacted?("internal_service api_key=zzqq11837462meliorplatformvalue")
    end

    test "a labeled secret_key with NO known vendor prefix redacts" do
      assert redacted?(~s(secret_key: "n0tAKnownVendorFormatButStillASecret123"))
    end

    test "a labeled password redacts" do
      assert redacted?("password=Tr0ub4dor&3xtraLongEnough")
    end

    test "a labeled client_secret redacts" do
      assert redacted?("client_secret=abcXYZ0129384756LongEnoughValue")
    end
  end

  describe "T14/UXD-14 CLOSED: non-language noise between label, separator and value" do
    # The six shapes that REFUTED attempt 1 of this item (V14's composed inputs). Each is named
    # individually so a future widening that reopens one of them fails a test that says which.
    test "REFUTATION 1: a non-breaking space (U+00A0) between separator and value redacts" do
      assert redacted?("auth_token=" <> <<0x00A0::utf8>> <> "averylongsecretvalue1234567890")
    end

    test "REFUTATION 2: an ideographic space (U+3000) between separator and value redacts" do
      assert redacted?("password:" <> <<0x3000::utf8>> <> "Tr0ub4dor&3xtraLongEnough")
    end

    test "REFUTATION 3: an UNTERMINATED C-style comment before the value redacts" do
      assert redacted?("auth_token = /* never closes averylongsecretvalue1234567890")
    end

    test "REFUTATION 4: an UNTERMINATED HTML comment before the value redacts" do
      assert redacted?("password: <!-- never closes Tr0ub4dor&3xtraLongEnough")
    end

    test "REFUTATION 5: a backslash-newline line continuation before the value redacts" do
      assert redacted?("auth_token=\\\n" <> "averylongsecretvalue1234567890")
    end

    test "REFUTATION 6: a comment body spanning a literal newline redacts (no DOTALL dependency)" do
      assert redacted?("auth_token = /* leaked\nacross lines */ averylongsecretvalue1234567890")
    end

    test "the exact V24 shape: an interleaved C-style comment between separator and value" do
      assert redacted?("auth_token = /* leaked */ averylongsecretvalue1234567890")
    end

    test "an interleaved HTML comment between separator and value still redacts" do
      assert redacted?("password: <!-- x --> Tr0ub4dor&3xtraLongEnough")
    end

    # The complement rule is a CLASS, not a list: every one of these code points is outside the
    # twelve attempt 1 enumerated, and none of them is named anywhere in the implementation.
    test "every non-language code point tried, not just the enumerated ones, is bridged" do
      for codepoint <- [
            0x200B,
            0x200F,
            0x202E,
            0x2060,
            0xFEFF,
            0x2003,
            0x2009,
            0x202F,
            0x205F,
            0x1680,
            0x00AD,
            0x180E,
            0xFE00,
            0xE0020,
            0x0301,
            0x1F600
          ] do
        input = "auth_token=" <> <<codepoint::utf8>> <> "averylongsecretvalue1234567890"

        assert redacted?(input),
               "U+#{Integer.to_string(codepoint, 16)} was not treated as non-language noise"
      end
    end

    test "a punctuation run, a stray comment closer and mixed invisible+punctuation all bridge" do
      assert redacted?("auth_token=...---___averylongsecretvalue1234567890")
      assert redacted?("auth_token = */ averylongsecretvalue1234567890")

      assert redacted?(
               "auth_token=" <>
                 <<0x00A0::utf8>> <> "!!!" <> <<0x3000::utf8>> <> "averylongsecretvalue1234567890"
             )
    end

    test "line-comment openers (//, #, --) bridge to a value on the next line" do
      assert redacted?("auth_token = // leaked\naverylongsecretvalue1234567890")
      assert redacted?("auth_token = # leaked\naverylongsecretvalue1234567890")
      assert redacted?("auth_token = -- leaked\naverylongsecretvalue1234567890")
    end

    test "unterminated block comments spanning newlines, nesting, and CDATA all bridge" do
      assert redacted?("auth_token = /* never closes\nstill open averylongsecretvalue1234567890")
      assert redacted?("auth_token = <!-- open\nstill averylongsecretvalue1234567890")
      assert redacted?("auth_token = /* /* nested */ */ averylongsecretvalue1234567890")
      assert redacted?("auth_token = <![CDATA[noise]]> averylongsecretvalue1234567890")
    end

    test "noise between the LABEL and the separator is bridged too — the JSON object-key shape" do
      assert redacted?(~s({"api_key": "averylongsecretvalue1234567890"}))
      assert redacted?(~s(<config api_key="averylongsecretvalue1234567890" />))
      assert redacted?("auth_token" <> <<0x200B::utf8>> <> "=averylongsecretvalue1234567890")
      assert redacted?("auth_token...=averylongsecretvalue1234567890")
    end

    test "an invalid-UTF-8 binary takes the byte-mode spelling and still redacts, never raises" do
      input = <<0xFF, 0xFE>> <> "auth_token=averylongsecretvalue1234567890"
      assert redacted?(input)
    end

    # REGRESSION GUARD. Attempt 2 of this item capped both gaps at 4096 characters, and the cap
    # SUBTRACTED coverage: the pre-T14 pattern spelled both gaps `\s*`, unbounded, so every shape
    # below redacted at the parent commit a3660e5 and stopped redacting under the cap — a labeled
    # non-vendor secret leaking in cleartext for the price of pressing the space bar. The gaps are
    # unbounded again (backtracking is bounded structurally instead); this test fails if any future
    # change re-introduces a length cap on the label-to-separator or separator-to-value gap.
    test "REGRESSION GUARD: the adjacent gaps are UNBOUNDED, as they were before T14" do
      secret = "n0tAKnownVendorFormatButStillASecret123"

      for {label, input} <- [
            {"separator-to-value, 4097 spaces",
             "password=" <> String.duplicate(" ", 4097) <> "thisislongenoughtomatch1234"},
            {"separator-to-value, 20000 spaces",
             "password=" <> String.duplicate(" ", 20_000) <> secret},
            {"label-to-separator, 4097 spaces",
             "password" <> String.duplicate(" ", 4097) <> "=thisislongenoughtomatch1234"},
            {"label-to-separator, 20000 tabs",
             "api_key" <> String.duplicate("\t", 20_000) <> ":" <> secret},
            {"both gaps, 5000 each",
             "api_key" <>
               String.duplicate("\t", 5000) <>
               ":" <> String.duplicate("\n", 5000) <> secret}
          ] do
        assert redacted?(input),
               "a gap cap was re-introduced and lost coverage the lane had before T14: #{label}"
      end
    end

    # The structural bound that replaced the length cap: the label-to-separator gap is possessive,
    # so the two gaps no longer multiply. A colon flood is the bait that drove the old quadratic
    # (235ms at 4KB, 270ms at 64KB under attempt 2's caps; 0.3ms and 1.7ms here). The threshold is
    # deliberately loose — it is a catastrophic-backtracking guard, not a benchmark.
    test "REGRESSION GUARD: a 64KB colon flood does not blow up the backtracker" do
      bait = "api_key" <> String.duplicate(":", 64_000)
      {micros, result} = :timer.tc(fn -> Secrets.redact(bait) end)

      assert result == bait
      assert micros < 2_000_000, "punctuation-flood redaction took #{div(micros, 1000)}ms"
    end

    test "known vendor-shaped formats are unaffected by the noise-tolerance change" do
      assert redacted?("aws_access_key_id=AKIAIOSFODNN7EXAMPLE")
      assert redacted?("token: ghp_" <> String.duplicate("a", 36))
      assert redacted?("postgres://appuser:s3cr3t-pw@db.internal:5432/prod")
    end
  end

  describe "T14/UXD-14 false-positive guard: the noise tolerance cannot bridge ordinary prose" do
    test "a recognized label followed by unrelated commentary containing a long word is NOT flagged" do
      value = "auth_token: this is some unrelated commentary with importantcontext1234 embedded"
      assert Secrets.redact(value) == value
    end

    test "ordinary business strings measured against the widened rule are untouched" do
      for value <- [
            "The record_id token: 123e4567-e89b-12d3-a456-426614174000 was updated",
            "commit auth_token abcdef1234567890abcdef1234567890abcdef12 landed",
            "auth_token here refers to the shared secret handshake documented in the runbook",
            "password palette: #1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d ok",
            "password: contact the platform administrator for a reset",
            "the password (see: runbook) is documented-elsewhere entirely",
            ~s({"password":null,"user_id":"u-0001","note":"nothing here at all"}),
            "auth_token documentation lives at https://example.com/docs/auth-token-guide",
            "2026-08-27 12:00:00 [info] request_id=F1-abcdefghij12 completed in 12ms",
            # V14's independently composed ordinary strings — added here so the false-positive
            # measurement this item reports is a fixture, not a claim about a private sample.
            "The api_key: documented at https://example.com/docs/api-key-setup",
            "<input type=\"password\" name=\"password\" autocomplete=\"current-password\">",
            "https://example.com/search?q=password&sort=relevance-desc&page=2",
            "export API_KEY=$(cat /run/secrets/api-key)",
            "%User{id: 1, password: nil, email: \"a@b.com\", inserted_at: ~U[2026-01-01 00:00:00Z]}",
            "2026-08-27T15:38:21Z level=warn msg=\"invalid password\" user=alice@example.com",
            "id,name,password,created_at,updated_at",
            "components:\n  securitySchemes:\n    api_key:\n      type: apiKey\n      in: header",
            "| `api_key` | string | Yes | Your API key from the dashboard |",
            "{\"password\": {\"type\": \"string\", \"minLength\": 12, \"description\": \"user password\"}}",
            "Set the api_key: value shown in your dashboard settings page",
            "- fixed a bug where password: was rendered before the label was localized",
            "{\"errors.password.too_short\": \"must be at least 12 characters long\"}",
            "ALTER TABLE users ADD COLUMN password_hash VARCHAR(255) NOT NULL;",
            "mutation { login(password: $password) { token } }",
            "parser.add_argument(\"--api-key\", help=\"your api key\", required=True)"
          ] do
        assert Secrets.redact(value) == value, "false positive on: #{inspect(value)}"
      end
    end

    test "non-Latin prose after a recognized label is prose, not noise" do
      for value <- [
            "password: " <> <<0x30D1::utf8, 0x30B9::utf8, 0x30EF::utf8>> <> " docs-portal-link",
            "password: " <> <<0x043F::utf8, 0x0430::utf8, 0x0440::utf8>> <> " admin-console-x"
          ] do
        assert Secrets.redact(value) == value, "false positive on: #{inspect(value)}"
      end
    end
  end

  describe "T14/UXD-14 STATED LIMIT: what the complement rule still does not close" do
    test "FRAGMENT 1 — ANY letter or number between separator and value blocks the bridge" do
      for value <- [
            "auth_token = leaked averylongsecretvalue1234567890",
            "auth_token = the value is averylongsecretvalue1234567890",
            "auth_token = ; leaked\naverylongsecretvalue1234567890",
            "auth_token = % leaked\naverylongsecretvalue1234567890",
            "auth_token = REM leaked\naverylongsecretvalue1234567890",
            "auth_token = <b>x</b> averylongsecretvalue1234567890",
            # A SINGLE character is enough, in any script, and it need not be prose — the
            # moduledoc heading says "letter or number" rather than "words" for exactly this
            # reason. U+03A9 GREEK CAPITAL OMEGA (\p{Lu}), U+2160 ROMAN NUMERAL ONE (\p{Nl}),
            # U+0660 ARABIC-INDIC DIGIT ZERO (\p{Nd}).
            "auth_token=" <> <<0x03A9::utf8>> <> "averylongsecretvalue1234567890",
            "auth_token=" <> <<0x2160::utf8>> <> "averylongsecretvalue1234567890",
            "auth_token=" <> <<0x0660::utf8>> <> "averylongsecretvalue1234567890"
          ] do
        assert Secrets.redact(value) == value,
               "fragment 1 of the moduledoc's STATED LIMITS changed: #{inspect(value)}"
      end
    end

    test "FRAGMENT 2 — noise INSIDE the value, splitting it below the 12-character floor, evades" do
      zwsp = <<0x200B::utf8>>
      value = "api_key=abcdefgh" <> zwsp <> "ijklmnop" <> zwsp <> "qrstuvwx"
      assert Secrets.redact(value) == value
    end

    test "FRAGMENT 3 — more than 4096 non-language characters BEFORE a comment opener is not bridged" do
      # The bound lives on the BRIDGED pattern only, because that is the one pattern whose gap
      # multiplies by a second quantifier (the 200-character budget). It removes nothing: no
      # version of this lane before T14 bridged a comment opener at all. The ADJACENT pattern's
      # gaps are unbounded — see "REGRESSION GUARD" above, which is the pin that says so.
      value =
        "auth_token =" <> String.duplicate(" ", 4097) <> "/* c averylongsecretvalue1234567890"

      assert Secrets.redact(value) == value

      within =
        "auth_token =" <> String.duplicate(" ", 4000) <> "/* c averylongsecretvalue1234567890"

      assert redacted?(within)
    end

    test "FRAGMENT 4 — more than 200 characters between a comment opener and the value is not bridged" do
      value =
        "auth_token = /* " <> String.duplicate("x ", 125) <> "averylongsecretvalue1234567890"

      assert Secrets.redact(value) == value

      within =
        "auth_token = /* " <> String.duplicate("x ", 75) <> "averylongsecretvalue1234567890"

      assert redacted?(within)
    end

    test "STATED COST 1 — prose FOLLOWING a recognized comment opener is over-redacted, deliberately" do
      assert redacted?("auth_token = /* set by the administrator later")

      # A real-world instance V14 found that this item's own first measurement missed: an ordinary
      # config comment carrying a documentation URL and no secret at all. Pinned so the measured
      # false-positive rate stays a fact rather than an estimate.
      assert redacted?("api_key: # see https://docs.example.com/getting-started")
    end

    test "STATED COST 2 — an empty-valued label followed only by punctuation redacts the next token" do
      assert redacted?("password:\n  - first-item-name\n  - second-item-name")

      # The second real-world instance V14 found: a comment divider under an empty key.
      assert redacted?("password:\n# ----------------------------------------\nother_key: value")
    end
  end

  describe "T14/UXD-14 DOCUMENTED LIMIT: unlisted-label high-entropy blobs are not caught" do
    test "an unlisted label ('backup_blob') with a high-entropy base64 value passes through untouched — a stated, pinned limit, not a bug; see the module's \"Known residual\" section" do
      value = "backup_blob=" <> Base.encode64(:crypto.strong_rand_bytes(48))
      assert Secrets.redact(value) == value
    end
  end

  describe "false-positive guard: ordinary business data is NOT secret-shaped" do
    test "a UUID passes through untouched" do
      value = "record_id: 123e4567-e89b-12d3-a456-426614174000"
      assert Secrets.redact(value) == value
    end

    test "plain business text passes through untouched" do
      value = "Pallet 12 arrived at Acme Freight; the driver signed for record 44."
      assert Secrets.redact(value) == value
    end

    test "a bare word 'password' with no assigned value passes through untouched" do
      value = "please reset your password before Friday"
      assert Secrets.redact(value) == value
    end

    test "a short/trivial value after a secret-shaped label is NOT flagged (below the length floor)" do
      value = "api_key=abc"
      assert Secrets.redact(value) == value
    end
  end

  describe "NOT REVERSIBLE, proven by collision" do
    test "two DIFFERENT vendor secrets redact to the SAME marker" do
      aws = Secrets.redact("AKIAIOSFODNN7EXAMPLE")
      gh = Secrets.redact("ghp_" <> String.duplicate("b", 36))
      assert aws == gh
      assert aws == Secrets.marker()
    end

    test "a vendor secret and a generic labeled secret redact to the SAME marker" do
      vendor = Secrets.redact("sk_live_" <> String.duplicate("c", 24))
      generic = Secrets.redact("api_key=unrecognizedButLongEnoughValue123")
      assert vendor == generic
    end

    test "idempotent: a second pass changes nothing" do
      for value <- [
            "AKIAIOSFODNN7EXAMPLE",
            "api_key=unrecognizedButLongEnoughValue123",
            "Pallet 12 arrived at Acme Freight."
          ] do
        once = Secrets.redact(value)
        assert Secrets.redact(once) == once
      end
    end
  end

  describe "total on binaries, never raises" do
    test "empty string" do
      assert Secrets.redact("") == ""
    end

    test "invalid-UTF-8-adjacent-but-still-a-binary content does not raise" do
      # Secrets.redact/1 is a plain regex pass over a binary; it must not raise even on a
      # binary that is not valid UTF-8 (Ingress.sanitize/1, run AFTER this in the call sites,
      # is the module responsible for refusing invalid UTF-8 wholesale).
      assert is_binary(Secrets.redact(<<0xFF, 0xFE, "ok">>))
    end
  end

  defp redacted?(value) do
    result = Secrets.redact(value)
    result != value and result =~ Secrets.marker()
  end
end

defmodule Samen.Web.RateLimit.Backend do
  @moduledoc """
  The Hammer ETS counter backend behind `Samen.Web.RateLimit` (ADR-037 §5.14 ADOPT;
  ADR-038 §6.1). `use Hammer, backend: :ets` generates `hit/3`, `inc/3`, `get/2` over a
  named ETS table owned by this GenServer — so the fixed-window counters have a STABLE
  owner (supervised by `Samen.Web.Application`), unlike a bare request-process ETS table
  whose counters would vanish when the request ends.

  This is the ADR-038 §6.1 "thin private detail": callers only ever touch the
  `Samen.Web.RateLimit` seam (`check/3`, `over_limit?/3`, `record_failure/3`); swapping
  this module for a Redis/multi-node Hammer backend later changes NO caller. The dep and
  this module live in `samen_web` ONLY — `samen_core` gains zero rate-limiter deps (INV-4).

  Non-PII by construction: the seam passes Hammer a key of the form
  `"{surface}:{kind}:{value}"` where `value` is a provider name, `email_bidx`
  (non-reversible keyed-HMAC, ADR-035 §4.1), a credential id, or a remote IP — NEVER a
  plaintext email or any vault-routed value (ADR-038 §6.2).
  """
  use Hammer, backend: :ets
end

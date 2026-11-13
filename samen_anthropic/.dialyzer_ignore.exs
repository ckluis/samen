# Dialyzer warnings that are NOT defects (issue #73). Every entry says why. A warning not
# listed here fails ./ci.sh.
[
  # ── The in-repo framework (samen_core, samen_web) is kept OUT of this project's PLT (see
  #    the `dialyzer:` comment in mix.exs), so dialyzer cannot resolve calls into it. Those
  #    calls are checked where they live: by samen_core's and samen_web's own runs. Scoped
  #    to `Samen.` modules only, so an unknown call to anything else still fails.
  ~r/:callback_info_missing Callback info about the Samen\./,
  # ── Same reason, for the two kernel references the 2026-11-13 adapter makes (ADR-043
  #    §5.1a): `Samen.AI.MaskedPayload.t/0` in `request_body/2`'s spec, and the shared
  #    `Samen.AI.Agent.Tools.input_schema/1` (one JSON-Schema derivation for every tool
  #    channel, not a second copy here). Both are checked by samen_core's own run; scoped to
  #    `Samen.AI.` so an unknown type or function anywhere else still fails.
  ~r/:unknown_type Unknown type: Samen\.AI\./,
  ~r/:unknown_function Function Samen\.AI\./
]

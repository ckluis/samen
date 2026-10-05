# Dialyzer warnings that are NOT defects (issue #73). Every entry says why. A warning not
# listed here fails ./ci.sh.
[
  # ── The in-repo framework (samen_core, samen_web) is kept OUT of this project's PLT (see
  #    the `dialyzer:` comment in mix.exs), so dialyzer cannot resolve calls into it. Those
  #    calls are checked where they live: by samen_core's and samen_web's own runs. Scoped
  #    to `Samen.` modules only, so an unknown call to anything else still fails.
  ~r/:unknown_function Function Samen\./,
  ~r/:callback_info_missing Callback info about the Samen\./
]

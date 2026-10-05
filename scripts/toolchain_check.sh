#!/usr/bin/env bash
# scripts/toolchain_check.sh — the running Elixir / Erlang-OTP must be at least the versions
# pinned in .tool-versions.
#
# WHY. Nothing in the repo recorded which toolchain it runs on (every mix.exs says only
# `elixir: "~> 1.18"`), so the machine's Homebrew Elixir 1.20.2 / OTP 29.0.3 sat behind
# ten published CVEs — OTP's zip path traversal and SSH/SSL fixes (29.0.4, 29.1.1) and
# Elixir's List.to_string/1 recursion (1.20.4) — without anything noticing. The pin makes
# the floor explicit; this check makes running below it a red, not a silent pass.
#
# FLOOR, NOT EXACT. Older than the pin FAILS (exit 1, naming the tool). Newer PASSES with a
# note, so a routine patch upgrade never breaks the gate; raise the pin when you adopt one.
#
# asdf/mise read the same file. SAMEN_TOOLCHAIN_ELIXIR / SAMEN_TOOLCHAIN_OTP override the
# detected versions (the self-test drives every case through them).
#
# Usage: scripts/toolchain_check.sh [--file <tool-versions>]     Exit: 0 ok · 1 too old · 2 env
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="$REPO_ROOT/.tool-versions"
[[ "${1:-}" == "--file" && -n "${2:-}" ]] && FILE="$2"
[[ -f "$FILE" ]] || { echo "TOOLCHAIN CHECK: no .tool-versions at $FILE" >&2; exit 2; }

pin_erlang="$(awk '$1=="erlang"{print $2}' "$FILE")"
pin_elixir="$(awk '$1=="elixir"{print $2}' "$FILE" | sed 's/-otp-.*//')"
[[ -n "$pin_erlang" && -n "$pin_elixir" ]] || { echo "TOOLCHAIN CHECK: .tool-versions must pin both erlang and elixir" >&2; exit 2; }

run_elixir="${SAMEN_TOOLCHAIN_ELIXIR:-$(elixir -e 'IO.write(System.version())' 2>/dev/null)}"
run_otp="${SAMEN_TOOLCHAIN_OTP:-$(erl -noshell -eval '{ok,V}=file:read_file(filename:join([code:root_dir(),"releases",erlang:system_info(otp_release),"OTP_VERSION"])), io:format("~s",[string:trim(V)]), halt().' 2>/dev/null)}"
[[ -n "$run_elixir" && -n "$run_otp" ]] || { echo "TOOLCHAIN CHECK: could not detect the running elixir/erl" >&2; exit 2; }

# older <a> <b>: true when version a sorts strictly before b.
older() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }

bad=0
for tool in Elixir OTP; do
  if [[ $tool == Elixir ]]; then run="$run_elixir"; pin="$pin_elixir"; else run="$run_otp"; pin="$pin_erlang"; fi
  if older "$run" "$pin"; then
    echo "TOOLCHAIN CHECK: $tool $run is OLDER than the pinned floor $pin (.tool-versions) — upgrade it."
    bad=1
  elif [[ "$run" != "$pin" ]]; then
    echo "TOOLCHAIN CHECK: note — $tool $run is newer than the pin $pin (fine; raise the pin when adopted)."
  fi
done
[[ $bad -eq 0 ]] || { echo "TOOLCHAIN CHECK: FAILED"; exit 1; }
echo "TOOLCHAIN CHECK: OK (Elixir $run_elixir >= $pin_elixir, OTP $run_otp >= $pin_erlang)"

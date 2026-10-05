#!/usr/bin/env bash
# scripts/toolchain_check_test.sh — red cases for scripts/toolchain_check.sh. No real
# toolchain switching: every case drives the check through its version overrides against a
# temp .tool-versions.
set -uo pipefail
CHK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolchain_check.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/samen_tc_test.XXXXXX")"; trap 'rm -rf "$T"' EXIT INT TERM
printf 'erlang 29.1.1\nelixir 1.20.4-otp-29\n' > "$T/tv"
pass=0; fail=0
check() { # check <want-rc> <grep> <what> <elixir> <otp> [file]
  out="$(SAMEN_TOOLCHAIN_ELIXIR="$4" SAMEN_TOOLCHAIN_OTP="$5" bash "$CHK" --file "${6:-$T/tv}" 2>&1)"; rc=$?
  if [[ $rc -eq $1 ]] && grep -qF -- "$2" <<<"$out"; then echo "PASS: $3"; pass=$((pass+1)); else echo "$out"; echo "FAIL: $3 (rc=$rc)"; fail=$((fail+1)); fi
}
check 0 "TOOLCHAIN CHECK: OK"         "exactly the pin passes"                       1.20.4 29.1.1
check 0 "newer than the pin"           "a newer patch passes, with a note"            1.20.5 29.1.2
check 1 "Elixir 1.20.2 is OLDER"       "an older Elixir fails and is named"           1.20.2 29.1.1
check 1 "OTP 29.0.3 is OLDER"          "an older OTP fails and is named"              1.20.4 29.0.3
check 1 "OTP 29.0.10 is OLDER"         "versions compare numerically, not as strings" 1.20.4 29.0.10
check 0 "TOOLCHAIN CHECK: OK"          "29.1.10 >= 29.1.1 (numeric, not lexical)"     1.20.4 29.1.10
printf 'erlang 29.1.1\n' > "$T/half"
check 2 "must pin both"                "a pin file missing elixir is an env error"    1.20.4 29.1.1 "$T/half"
check 2 "no .tool-versions"            "a missing pin file is an env error"           1.20.4 29.1.1 "$T/absent"
echo "TOOLCHAIN CHECK SELF-TEST: $pass passed, $fail failed"
[[ $fail -eq 0 ]] && echo "TOOLCHAIN CHECK SELF-TEST: ALL PASSED" || { echo "TOOLCHAIN CHECK SELF-TEST: FAILED"; exit 1; }

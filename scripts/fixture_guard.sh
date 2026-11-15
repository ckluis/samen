#!/usr/bin/env bash
# scripts/fixture_guard.sh — SOURCED by the self-tests that build throwaway git repos
# (ci_test.sh, sabotage_lanes_test.sh, sabotage_tooling_test.sh, sabotage_apply_check_test.sh, double_sweep_test.sh).
#
# A test harness must never be able to write to the repository it is testing. Once a fixture builder ran
# `cd "$R" && git init … ; … ; git add -A && git commit …` with only the first line chained: `cd` failed, the rest ran
# in the caller's directory — the real repo — and committed onto a developer's branch and moved its
# refs/remotes/origin/main (every diff-aware gate then selects nothing). This file makes that impossible:
#
#   fixture_mktemp <prefix>   a usable, PHYSICAL (symlinks resolved) temp root, or a loud failure. Use
#                             `T="$(fixture_mktemp samen_x_test)" || exit 1`.
#   fixture_arm <T> <ROOT> <tag>
#                             shadows `git` with a guard: a git command runs only when its repository (the physical
#                             toplevel it would act on, after any -C) lies INSIDE <T>; `git init` only when its target
#                             directory does. Read-only subcommands on <ROOT> stay allowed (cat-file, show, ...).
#                             Anything else is refused (rc 97), reported, and recorded so fixture_finish fails the run.
#                             It also records <ROOT>'s HEAD, branch, origin/main and `status --porcelain`.
#   fixture_finish            call FIRST in the EXIT trap: fails the run if the guard refused anything, or if <ROOT>'s
#                             recorded state changed (it reports, never repairs).
#   fixture_cd <dir>          `cd` that is fatal: a fixture directory that cannot be entered aborts the subshell.
#
# Paths are compared PHYSICALLY (`pwd -P`): on macOS /tmp -> /private/tmp and TMPDIR may itself be a symlink.

FG_T=""; FG_ROOT=""; FG_TAG="fixture"; FG_TRIP=""; FG_SNAP=""

fixture_mktemp() {
  local d p
  d="$(mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX" 2>/dev/null)" || { echo "$1: no usable temp root: mktemp -d under '${TMPDIR:-/tmp}' failed — refusing to run" >&2; return 1; }
  if [[ -z "$d" || ! -d "$d" || ! -w "$d" ]]; then echo "$1: no usable temp root: '$d' is not a writable directory — refusing to run" >&2; return 1; fi
  p="$(cd "$d" && pwd -P)" || { echo "$1: no usable temp root: cannot enter '$d' — refusing to run" >&2; return 1; }
  [[ -n "$p" && "$p" != "/" ]] || { echo "$1: no usable temp root: resolved to '$p' — refusing to run" >&2; return 1; }
  printf '%s\n' "$p"
}

fixture_cd() { cd "$1" || { echo "$FG_TAG: cannot enter fixture directory '$1'" >&2; exit 97; }; }

_fg_real() { command git "$@"; }

_fg_state() { # _fg_state <repo> -> HEAD | branch | origin/main | sha of status --porcelain
  local r="$1" h b o s
  h="$(_fg_real -C "$r" rev-parse -q --verify HEAD 2>/dev/null || echo none)"
  b="$(_fg_real -C "$r" symbolic-ref -q HEAD 2>/dev/null || echo detached)"
  o="$(_fg_real -C "$r" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null || echo none)"
  s="$(_fg_real -C "$r" status --porcelain 2>/dev/null | cksum)"
  printf 'HEAD=%s\nbranch=%s\norigin/main=%s\nstatus=%s\n' "$h" "$b" "$o" "$s"
}

fixture_arm() {
  if [[ -z "${1:-}" || ! -d "$1" || -z "${2:-}" ]]; then echo "fixture_arm: empty or non-directory fixture root ('${1:-}') — the guard cannot be armed" >&2; return 1; fi
  FG_T="$(cd "$1" && pwd -P)"; FG_ROOT="$(cd "$2" && pwd -P)"; FG_TAG="${3:-fixture}"; FG_TRIP="$FG_T/.fixture_guard_tripped"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_NAMESPACE GIT_CEILING_DIRECTORIES
  FG_SNAP="$(_fg_state "$FG_ROOT")"
  FG_STATUS_BEFORE="$(_fg_real -C "$FG_ROOT" status --porcelain 2>/dev/null)"
}

_fg_deny() { # _fg_deny <why>
  echo "$FG_TAG: FIXTURE GUARD refused 'git $*' — $_FG_WHY" >&2
  : > "$FG_TRIP" 2>/dev/null
  return 97
}

git() {
  [[ -n "$FG_T" ]] || { command git "$@"; return; }   # not armed (sourced only for fixture_mktemp)
  local dir a=("$@") i=0 n=${#a[@]} sub="" subi=-1 top p
  dir="$(pwd -P)"
  while ((i < n)); do
    case "${a[i]}" in
      -C) dir="$(cd "$dir" 2>/dev/null && cd "${a[i+1]-}" 2>/dev/null && [[ -n "${a[i+1]-}" ]] && pwd -P)" \
            || { _FG_WHY="-C '${a[i+1]-}' is not an enterable directory"; _fg_deny "$@"; return 97; }
          i=$((i + 2)) ;;
      -c) i=$((i + 2)) ;;
      --git-dir|--git-dir=*|--work-tree|--work-tree=*)
          _FG_WHY="--git-dir/--work-tree redirects git away from the checked directory"; _fg_deny "$@"; return 97 ;;
      -*) i=$((i + 1)) ;;
      *) sub="${a[i]}"; subi=$i; break ;;
    esac
  done
  [[ -n "$sub" ]] || { command git "$@"; return; }
  if [[ "$sub" == init ]]; then
    case "$dir/" in "$FG_T"/*) ;; *) _FG_WHY="init target '$dir' is outside the fixture root $FG_T"; _fg_deny "$@"; return 97 ;; esac
    p="${a[n-1]}"
    if ((n - 1 > subi)) && [[ "$p" != -* ]] && p="$(cd "$dir" 2>/dev/null && cd "$p" 2>/dev/null && pwd -P)"; then
      case "$p/" in "$FG_T"/*) ;; *) _FG_WHY="init path '$p' is outside the fixture root $FG_T"; _fg_deny "$@"; return 97 ;; esac
    fi
    command git "$@"; return
  fi
  top="$(command git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" && top="$(cd "$top" && pwd -P)" || top=""
  case "$top/" in
    "$FG_T"/*) command git "$@"; return ;;
  esac
  if [[ -n "$top" && "$top" == "$FG_ROOT" ]]; then
    case "$sub" in cat-file|show|rev-parse|rev-list|log|ls-files|ls-tree|diff|status|merge-base|describe|symbolic-ref|show-ref)
        command git "$@"; return ;; esac
  fi
  _FG_WHY="its repository is '${top:-none}' (directory '$dir'), not inside the fixture root $FG_T"
  _fg_deny "$@"; return 97
}

fixture_finish() { # -> rc 0 clean, 1 if the guard tripped or the real repo moved. Prints; never repairs.
  local rc=0 now
  [[ -n "$FG_T" ]] || return 0
  if [[ -e "$FG_TRIP" ]]; then
    echo "$FG_TAG: a fixture git command was REFUSED by the guard (it would have run outside $FG_T) — the self-test is broken" >&2; rc=1
  fi
  now="$(_fg_state "$FG_ROOT")"
  if [[ "$now" != "$FG_SNAP" ]]; then
    echo "$FG_TAG: SELF-TEST ESCAPED INTO THE REAL REPO ($FG_ROOT) — it changed while the self-test ran:" >&2
    diff <(printf '%s\n' "$FG_SNAP") <(printf '%s\n' "$now") | sed -n 's/^< /  was: /p;s/^> /  now: /p' >&2
    diff <(printf '%s\n' "$FG_STATUS_BEFORE") <(_fg_real -C "$FG_ROOT" status --porcelain 2>/dev/null) | sed -n 's/^< /  status gone: /p;s/^> /  status new:  /p' >&2
    echo "$FG_TAG: nothing was repaired — inspect 'git -C $FG_ROOT log -3', 'git -C $FG_ROOT reflog -5' and refs/remotes/origin/main" >&2
    rc=1
  fi
  return $rc
}

#!/usr/bin/env python3
"""scripts/docs_check — ADR-053 P4. CLAUDE.md and docs/ci.md name commands, step ids and files; every one of
them rots silently the day a subcommand is renamed, a step is split or a script moves. This resolves them
mechanically (it is the `docs_check` step of quick, pr and full):

    scripts/docs_check [FILE…]       default: CLAUDE.md docs/ci.md (repo-relative)
    SAMEN_DOCS_REPO=<dir>            check another tree (the self-test's fixtures)

Per line, outside ```ini fences (config examples may name things that do not exist):
  * `scripts/ci <word>`              <word> must be a subcommand in `scripts/ci --help` (`actions <word>` too);
                                     a word starting with - < [ $ ( is a flag or placeholder and is skipped
  * `--flags` on a scripts/ci call   must appear in `scripts/ci --help`
  * `explain X` / `--only-steps X`   X must be a [step] in ci/steps.conf; `--only X` / `--also X`: a step or group
                                     (comma lists; a [i/n] shard suffix is stripped; <placeholders> are skipped)
  * a backticked snake_case token whose first word starts some step id (dialyzer_*, double_*, apply_*, …) must be
    a step, group, app or Actions job in the manifest (samen_* is skipped: app names, databases, roles)
  * every scripts/…, ci/…, docs/…, .github/… path (also as ./scripts/…) must exist (a glob must match something;
    a path followed by < or { or containing NNN is a template and is skipped)
And: docs/ci.md must exist, CLAUDE.md must point at it, and a file with no resolvable command or path at all
FAILS (a check that finds nothing to check is a check that cannot go red).
"""
import glob
import os
import re
import subprocess
import sys

REPO = os.path.abspath(os.environ.get("SAMEN_DOCS_REPO") or os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
DEFAULT_FILES = ["CLAUDE.md", "docs/ci.md"]
CMD = re.compile(r"(?<![\w/.-])scripts/ci[ \t]+(\S+)")
PATH = re.compile(r"(?<![\w./~-])(?:\./)?((?:scripts|ci|docs|\.github)/[A-Za-z0-9_./*-]+)")  # `./scripts/x` too
SPAN = re.compile(r"`([^`\n]+)`")
STEPLIKE = re.compile(r"[a-z][a-z0-9]*(?:_[a-z0-9]+)+(?:\[\d+/\d+\])?")
ARGREF = re.compile(r"(?:(?<![\w-])(explain)|(--only-steps)|(--only)(?![-\w])|(--also))[ \t]+(\S+)")


def load_manifest():
    path = os.path.join(REPO, "ci", "steps.conf")
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        raise SystemExit("docs_check: cannot read %s" % path)
    steps = set(re.findall(r"^\[step ([^\]\s]+)\]", text, re.M))
    groups = set(re.findall(r"^\[group ([^\]\s]+)\]", text, re.M))
    groups |= set(re.findall(r"^group\s*=\s*(\S+)", text, re.M))
    groups |= set(re.findall(r"^actions_job\s*=\s*(\S+)", text, re.M))
    apps = set(re.findall(r"^\[app ([^\]\s]+)\]", text, re.M))
    if not steps:
        raise SystemExit("docs_check: no [step …] stanzas in %s" % path)
    return steps, groups, apps


def load_help():
    p = subprocess.run(["bash", os.path.join(REPO, "scripts", "ci"), "--help"], cwd=REPO,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    text = p.stdout
    subs = set()
    for m in re.finditer(r"scripts/ci ([a-z][a-z|]*)", text):
        subs.update(m.group(1).split("|"))
    actions = set(re.findall(r"scripts/ci actions ([a-z]+)", text))
    flags = set(re.findall(r"--[a-z][a-z-]*", text)) | {"--help"}
    if "quick" not in subs or not flags:
        raise SystemExit("docs_check: could not read the subcommands out of `scripts/ci --help`:\n" + text[-800:])
    return subs, actions, flags


def lines_of(path):
    """(lineno, text) outside ```ini fences."""
    skip = False
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        s = line.strip()
        if s.startswith("```"):
            if skip:
                skip = False
                continue
            if s[3:].strip() == "ini":
                skip = True
                continue
        if not skip:
            yield n, line.rstrip("\n")


def strip_word(w):
    return w.strip("`.,;:)'\"…")


def check_commands(rel, n, line, subs, actions, flags, steps, groups, found, problems):
    for m in CMD.finditer(line):
        # from the first word on: `explain X` and `--only X` are matched in the tail, so it must include the word
        tail = line[m.start(1):].split("`")[0].split(" #")[0]
        for word in strip_word(m.group(1)).split("|"):
            if not word or not word[0].isalpha():
                continue
            found["sub"] += 1
            if word not in subs:
                problems.append("%s:%d: `scripts/ci %s` — no such subcommand (scripts/ci --help: %s)" % (rel, n, word, " ".join(sorted(subs))))
            elif word == "actions":
                nxt = re.match(r"\s*([a-z]+)", tail[len("actions"):])
                if nxt:
                    found["sub"] += 1
                    if nxt.group(1) not in actions:
                        problems.append("%s:%d: `scripts/ci actions %s` — no such action (scripts/ci --help: %s)" % (rel, n, nxt.group(1), " ".join(sorted(actions))))
        for flag in re.findall(r"(?<![\w-])--[a-z][a-z-]*", tail):
            found["flag"] += 1
            if flag not in flags:
                problems.append("%s:%d: `scripts/ci … %s` — not a flag in `scripts/ci --help`" % (rel, n, flag))
        for am in ARGREF.finditer(tail):
            kind = am.group(1) or am.group(2) or am.group(3) or am.group(4)
            for item in strip_word(am.group(5)).split(","):
                item = re.sub(r"\[\d+/\d+\]$", "", strip_word(item))
                if not item or item[0] in "<[$(-" or "<" in item:
                    continue
                found["step"] += 1
                ok = item in steps if kind in ("explain", "--only-steps") else (item in steps or item in groups)
                if not ok:
                    problems.append("%s:%d: `%s %s` — not %s in ci/steps.conf" % (rel, n, kind, item, "a step" if kind in ("explain", "--only-steps") else "a step or group"))


def check_step_tokens(rel, n, line, families, known, found, problems):
    for sm in SPAN.finditer(line):
        tok = sm.group(1)
        if STEPLIKE.fullmatch(tok) and tok.split("_")[0] in families:
            found["step"] += 1
            if re.sub(r"\[\d+/\d+\]$", "", tok) not in known:
                problems.append("%s:%d: `%s` looks like a CI step id but ci/steps.conf has no such step, group, app or job" % (rel, n, tok))


def check_paths(rel, n, line, found, problems):
    for m in PATH.finditer(line):
        tok = m.group(1).rstrip(".,;:)")
        if line[m.end():m.end() + 1] in ("<", "{") or ".." in tok or "NNN" in tok:
            continue
        found["path"] += 1
        full = os.path.join(REPO, tok)
        ok = bool(glob.glob(full)) if "*" in tok else os.path.exists(full)
        if not ok:
            problems.append("%s:%d: path `%s` does not exist" % (rel, n, tok))


def main(argv):
    files = argv or DEFAULT_FILES
    steps, groups, apps = load_manifest()
    subs, actions, flags = load_help()
    firsts = {}
    for s in steps:
        firsts[s.split("_")[0]] = firsts.get(s.split("_")[0], 0) + 1
    # every step id's first word (double_*, apply_*, ci_*, …), not only the big families: a misspelled
    # `double_swep` in prose is the same lie as a misspelled `dialyzer_*`. samen_* is also app names, DBs, roles.
    families = {k for k in firsts if k != "samen"}
    known = steps | groups | apps
    problems, totals = [], {"sub": 0, "flag": 0, "step": 0, "path": 0}
    for rel in files:
        path = os.path.join(REPO, rel)
        if not os.path.isfile(path):
            problems.append("%s: missing — the CI docs must exist" % rel)
            continue
        found = {"sub": 0, "flag": 0, "step": 0, "path": 0}
        for n, line in lines_of(path):
            check_commands(rel, n, line, subs, actions, flags, steps, groups, found, problems)
            check_step_tokens(rel, n, line, families, known, found, problems)
            check_paths(rel, n, line, found, problems)
        if found["sub"] == 0 or found["path"] == 0 or (rel.endswith("ci.md") and found["step"] == 0):
            problems.append("%s: vacuous — resolved %d subcommand(s), %d step id(s), %d path(s); a check that finds nothing to check cannot go red" % (
                rel, found["sub"], found["step"], found["path"]))
        for k in totals:
            totals[k] += found[k]
    claude = os.path.join(REPO, "CLAUDE.md")
    if "CLAUDE.md" in files and os.path.isfile(claude) and "docs/ci.md" not in open(claude, encoding="utf-8").read():
        problems.append("CLAUDE.md: does not point at docs/ci.md (the pointer is how an agent finds the reference)")
    if problems:
        for p in problems:
            print("DOCS_CHECK: DRIFT  " + p)
        print("DOCS_CHECK: FAILED — %d problem(s). Fix the document (or the tooling it names); the check is not the thing to edit." % len(problems))
        return 1
    print("DOCS_CHECK: OK (%s: %d subcommand(s), %d flag(s), %d step id(s), %d path(s) resolve)" % (
        ", ".join(files), totals["sub"], totals["flag"], totals["step"], totals["path"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

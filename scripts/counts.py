#!/usr/bin/env python3
"""scripts/counts — ADR-053 P3 (C10). CLAUDE.md states counts (how many sabotages, how many mutants
the watch-list holds ...) that every PR used to hand-edit and that drifted anyway. They now live
between inline markers and are DERIVED:

    <!--count:NAME-->VALUE<!--/count-->

    scripts/counts --check    exit 1 on drift (a stale value, a missing required marker, an unknown
                              name); prints each line with what the file says and what the sources say
    scripts/counts --write    rewrite the stale values in place (never adds or removes a marker)
    scripts/counts --list     print every derived value
    --file PATH               the document (default: CLAUDE.md at the repo root)
    --only a,b                restrict to those names (the cheap path: `sabotage new` uses --only
                              sabotages,driver_sabotages)

Sources of truth (nothing is typed here):
    sabotages          ls scripts/sabotages/*.patch | wc -l
    driver_sabotages   lowest-highest patch number whose TEST_FILES names ci_driver_guard_test.exs
    watchlist_modules  scripts/mutate.sh --list-targets            (the tier-1 watch-list rows)
    watchlist_mutants  scripts/mutation/mutate.exs list <file>, summed over those rows
    corpus_targets     scripts/mutate.sh --corpus --list-targets   (derived from the sabotage headers)
    corpus_mutants     the same engine call, summed over the corpus rows

Per-file mutant counts are cached in _ci/counts/ keyed by sha256(engine + file), so a warm check is
a handful of hashes; only an edited target file is re-enumerated.
"""
import glob
import hashlib
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

REPO = os.environ.get("SAMEN_COUNTS_REPO") or os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CACHE = os.environ.get("SAMEN_COUNTS_CACHE") or os.path.join(os.environ.get("SAMEN_CI_HOME") or os.path.join(REPO, "_ci"), "counts")
MARK = re.compile(r"<!--count:([a-z_]+)-->(.*?)<!--/count-->")
NAMES = ["sabotages", "driver_sabotages", "watchlist_modules", "watchlist_mutants", "corpus_targets", "corpus_mutants"]
GUARD_TEST = "ci_driver_guard_test.exs"


def sh(args):
    p = subprocess.run(args, cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if p.returncode != 0:
        raise SystemExit("counts: `%s` failed (exit %d):\n%s" % (" ".join(args), p.returncode, (p.stdout + p.stderr)[-2000:]))
    return p.stdout


def patches():
    return sorted(glob.glob(os.path.join(REPO, "scripts", "sabotages", "*.patch")))


def hdr(path, key):
    with open(path, errors="replace") as f:
        for line in f:
            if line.startswith("diff --git"):
                break
            if line.startswith("# %s: " % key):
                yield line.rstrip("\n")[len("# %s: " % key):]


def n_sabotages():
    return str(len(patches()))


def n_driver_range():
    nums = []
    for p in patches():
        if any(GUARD_TEST in v for v in hdr(p, "TEST_FILES")):
            m = re.match(r"(\d+)-", os.path.basename(p))
            if m:
                nums.append(int(m.group(1)))
    if not nums:
        raise SystemExit("counts: no patch names %s — cannot derive driver_sabotages" % GUARD_TEST)
    return "%d–%d" % (min(nums), max(nums))


def target_rows(corpus):
    out = sh(["bash", "scripts/mutate.sh"] + (["--corpus"] if corpus else []) + ["--list-targets"])
    rows = [l.split("\t") for l in out.splitlines() if "\t" in l]
    m = re.search(r"^MUTATION TARGETS: (\d+) ", out, re.M)
    if not m or int(m.group(1)) != len(rows):
        raise SystemExit("counts: mutate.sh --list-targets accounting: says %s, listed %d rows" % (m and m.group(1), len(rows)))
    return [r[0] for r in rows]


def engine_count(rel):
    engine = os.path.join(REPO, "scripts", "mutation", "mutate.exs")
    h = hashlib.sha256()
    for path in (engine, os.path.join(REPO, rel)):
        with open(path, "rb") as f:
            h.update(f.read())
        h.update(b"\0")
    cp = os.path.join(CACHE, h.hexdigest())
    try:
        with open(cp) as f:
            return int(f.read())
    except (OSError, ValueError):
        pass
    out = sh(["elixir", engine, "list", rel])
    n = len([l for l in out.splitlines() if l.strip()])
    os.makedirs(CACHE, exist_ok=True)
    tmp = "%s.%d" % (cp, os.getpid())
    with open(tmp, "w") as f:
        f.write(str(n))
    os.replace(tmp, cp)
    return n


def mutants(files):
    with ThreadPoolExecutor(max_workers=4) as ex:
        return sum(ex.map(engine_count, files))


_memo = {}


def derive(name):
    if name in _memo:
        return _memo[name]
    if name == "sabotages":
        v = n_sabotages()
    elif name == "driver_sabotages":
        v = n_driver_range()
    elif name == "watchlist_modules":
        v = str(len(target_rows(False)))
    elif name == "watchlist_mutants":
        v = str(mutants(target_rows(False)))
    elif name == "corpus_targets":
        v = str(len(target_rows(True)))
    elif name == "corpus_mutants":
        v = "{:,}".format(mutants(target_rows(True)))
    else:
        raise SystemExit("counts: unknown count name %r (known: %s)" % (name, ", ".join(NAMES)))
    _memo[name] = v
    return v


def main(argv):
    mode, path, only = None, os.path.join(REPO, "CLAUDE.md"), None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--check", "--write", "--list"):
            if mode:
                print("counts: give one of --check / --write / --list", file=sys.stderr)
                return 2
            mode = a[2:]
        elif a in ("--file", "--only") and i + 1 < len(argv):
            i += 1
            if a == "--file":
                path = argv[i]
            else:
                only = [x for x in argv[i].split(",") if x]
        else:
            print(__doc__.split("\n\n")[0] + "\n\nusage: scripts/counts --check|--write|--list [--file PATH] [--only a,b]", file=sys.stderr)
            return 2
        i += 1
    if not mode:
        print("usage: scripts/counts --check|--write|--list [--file PATH] [--only a,b]", file=sys.stderr)
        return 2
    wanted = only if only is not None else NAMES
    for n in wanted:
        if n not in NAMES:
            print("counts: unknown count name %r (known: %s)" % (n, ", ".join(NAMES)), file=sys.stderr)
            return 2
    if mode == "list":
        for n in wanted:
            print("%-18s %s" % (n, derive(n)))
        return 0
    with open(path, encoding="utf-8") as f:
        text = f.read()
    problems, seen = [], set()
    lines = text.split("\n")
    for ln, line in enumerate(lines, 1):
        for m in MARK.finditer(line):
            name = m.group(1)
            if name not in NAMES:
                problems.append("%s:%d: unknown count marker %r" % (path, ln, name))
                continue
            seen.add(name)
    # required markers: a count that lost its marker is a count nobody checks any more
    for n in wanted:
        if n not in seen:
            problems.append("%s: no <!--count:%s-->…<!--/count--> marker (a count without a marker is not checked)" % (path, n))
    drift = []

    def sub(m):
        name = m.group(1)
        if name not in wanted:
            return m.group(0)
        want = derive(name)
        if m.group(2) != want:
            drift.append((name, m.group(2), want))
        return "<!--count:%s-->%s<!--/count-->" % (name, want)

    new_lines = [MARK.sub(sub, l) if "<!--count:" in l else l for l in lines]
    if mode == "check":
        for name, have, want in drift:
            problems.append("%s: count %s says %s, the sources say %s" % (path, name, have, want))
        if problems:
            for p in problems:
                print("COUNTS: DRIFT  " + p)
            print("COUNTS: FAILED — %d problem(s). Fix: scripts/counts --write" % len(problems))
            return 1
        print("COUNTS: OK (%d count(s) in %s match their sources)" % (len(wanted), os.path.basename(path)))
        return 0
    # write
    hard = [p for p in problems if "unknown count marker" in p or "no <!--count" in p]
    if hard:
        for p in hard:
            print("COUNTS: " + p)
        print("COUNTS: FAILED — --write never adds or removes a marker; fix the document by hand")
        return 1
    if drift:
        tmp = path + ".counts.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("\n".join(new_lines))
        os.replace(tmp, path)
    for name, have, want in drift:
        print("COUNTS: %s %s -> %s" % (name, have, want))
    print("COUNTS: %s (%d updated)" % ("written" if drift else "already current", len(drift)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""scripts/ci_driver.py — the ADR-053 CI driver. Run it through `scripts/ci`; `scripts/ci --help`.

ONE driver, three modes, over ONE manifest (ci/steps.conf):

  quick   inside a round — diff-aware vs the merge-base with --base (tracked + untracked-not-
          ignored), affected steps only. Never claims PR-ready.
  pr      before a PR — everything ./ci.sh ran + the sabotages and tier-1 mutants touching the diff.
  full    nightly / milestone — pr + the whole sabotage corpus + the whole mutation watch-list +
          the multinode tier.
  fast    the ./ci-fast.sh subset (spikes · samen_core · samen_web). Never claims PR-ready.

THE CONTRACTS (each has a red-path test in scripts/ci_test.sh; do not weaken any of them):
  C1  a run is PASS only when EVERY planned step is PASS or CACHED — a step the budget deferred,
      an interrupted step and a step never reached all leave the run INCOMPLETE, never PASS.
  C2  the cache key is the content of every declared input (tracked + untracked-not-ignored) +
      the toolchain + the step's own definition; a step with no declared inputs is never cached.
  C3  only a PASS is ever cached — never a FAIL, never a FLAKY.
  C4  quick (and fast, and any --only run) never prints a PR-ready verdict.
  C5  a failing ExUnit test is re-run ONCE in isolation and labelled FLAKY if it then passes —
      and a FLAKY step still fails the run.
  C6  a step's exit code is collected explicitly for every concurrently running process; a
      failure is never lost, so the wrappers can never print ALL PASSED over one.
  C9  quick selects every step whose inputs match a changed path, with apps expanded through the
      explicit dependency graph (a samen_core change selects every dependant).

Python 3.9 stdlib only (macOS system python). No third-party imports.
"""
import configparser
import fcntl
import fnmatch
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

KEY_VERSION = "adr053-2"  # bump to invalidate every cached PASS after a semantic driver change

SELF_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.environ.get("SAMEN_CI_REPO") or os.path.join(SELF_DIR, ".."))
MANIFEST = os.path.abspath(os.environ.get("SAMEN_CI_MANIFEST") or os.path.join(REPO, "ci", "steps.conf"))
HOME = os.path.abspath(os.environ.get("SAMEN_CI_HOME") or os.path.join(REPO, "_ci"))

MODES = ("quick", "fast", "pr", "full")
NOT_PR_READY = "NOT PR-READY — run: scripts/ci pr"
DONE = ("PASS", "CACHED")

USAGE = """\
usage: scripts/ci quick|fast|pr|full [--budget S] [-j N] [--only STEP|GROUP[,…] | --only-steps STEP[,…]] [--also STEP|GROUP]
                                     [--no-cache] [--base REF] [--keep-going] [--markers] [--plan]
                                     [--slice i/n] [--require-base]
       scripts/ci resume [--budget S] [-j N] [--markers]
       scripts/ci status
       scripts/ci list [MODE] [--markers] [--apps] [--also STEP]
       scripts/ci explain STEP [--base REF]
       scripts/ci actions plan MODE [--json]          (GitHub Actions: job matrix + exclusions; fails on a
                                                       step in no job, in two, or excluded without a reason)
       scripts/ci actions verify MODE --results DIR [--expect-base SHA]   (every planned step ran, once, PASS)
       scripts/ci actions summary [--last FILE]       (markdown verdict + failure digest for $GITHUB_STEP_SUMMARY)

  --budget S    stop STARTING steps once the next one's est_s would overrun S seconds of this
                invocation (default 540; 0 = no budget). The first step of an invocation always
                runs. Ends `INCOMPLETE n/m — continue: scripts/ci resume`.
  -j N          concurrent non-serial steps (default: cores/2).
  --only X      run only these steps/groups (comma-separated). A filtered run is never PR-ready.
  --only-steps X  like --only, but X are step IDS only (a step named like a group does not select the group).
  --also X      add an opt-in step/group outside the mode (./ci.sh maps SAMEN_SABOTAGE=1 etc.).
  --no-cache    ignore cached PASSes (this run's own progress still resumes).
  --base REF    diff base for quick / --changed steps / the double sweep (default origin/main).
  --keep-going  keep starting steps after a failure (default: stop at the first failure).
  --markers     also print the legacy `==> … PASSED` marker lines (the ./ci.sh wrappers).
  --slice i/n   run only the i-th of n balanced slices of every sharded step (nightly Actions matrix); each
                slice's PROCESSED count must equal its chunk, and `actions verify` sums them to the total.
  --require-base  FAIL (exit 2, last.json ERROR) when --base does not resolve, in any mode (Actions: a
                missing base must never read as a pass).
  --plan        print what would run (and what is CACHED) and exit; runs nothing, writes no state.

Exit: 0 PASS · 1 FAIL · 2 usage/environment · 3 INCOMPLETE · 130 interrupted.
State: _ci/state.json (resume), _ci/last.json (verdict, machine-readable), _ci/logs/, _ci/cache/.
"""


class UsageError(Exception):
    pass


# ── small utilities ─────────────────────────────────────────────────────────────────────────────
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def out(line=""):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def git(*args, check=True, env=None, binary=False):
    p = subprocess.run(["git", "-C", REPO] + list(args), stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, env=env)
    if check and p.returncode != 0:
        raise UsageError("git %s failed: %s" % (" ".join(args), p.stderr.decode(errors="replace").strip()))
    return p.stdout if binary else p.stdout.decode(errors="replace")


def atomic_write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, sort_keys=False)
        f.write("\n")
    os.replace(tmp, path)


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def safe_name(step_id):
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", step_id)


def fmt_s(x):
    return "%.1fs" % x


# ── manifest ────────────────────────────────────────────────────────────────────────────────────
STEP_KEYS = {"cmd", "cwd", "modes", "inputs", "reads", "always", "serial", "locks", "est_s", "group",
             "marker", "marker_if", "skip_marker", "echo_log", "exunit_dir", "superseded_by",
             "shard_list", "shard_kind", "shard_item", "shard_total", "shard_each_s", "shard_target_s",
             "shard_check", "unsharded_cmd", "desc", "actions_job", "actions_skip", "actions_dirs", "actions_slices"}


class Step(object):
    def __init__(self, sid, d):
        unknown = set(d) - STEP_KEYS
        if unknown:
            raise UsageError("manifest: step %s has unknown key(s): %s" % (sid, ", ".join(sorted(unknown))))
        if "cmd" not in d:
            raise UsageError("manifest: step %s has no cmd" % sid)
        self.id = sid
        self.cmd = d["cmd"]
        self.cwd = (d.get("cwd") or ".").strip().rstrip("/") or "."
        self.modes = set(d.get("modes", "").split())
        bad = self.modes - set(MODES)
        if bad:
            raise UsageError("manifest: step %s: unknown mode(s) %s" % (sid, " ".join(sorted(bad))))
        self.inputs = d.get("inputs", "").split()
        self.reads = d.get("reads", "").split()
        self.always = d.get("always", "0").strip() == "1"
        self.serial = d.get("serial", "0").strip() == "1"
        self.locks = set(d.get("locks", "").split())
        if self.cwd != ".":
            self.locks.add("dir:" + self.cwd)  # one mix process per project dir: no _build/deps race
        self.est = float(d.get("est_s", "30"))
        self.group = (d.get("group") or "").strip()
        self.markers = [l.strip() for l in d.get("marker", "").split("\n") if l.strip()]
        self.marker_if = d.get("marker_if", "").strip() or None
        self.skip_marker = d.get("skip_marker", "").strip() or None
        self.echo_log = d.get("echo_log", "").strip() or None
        self.exunit_dir = (d.get("exunit_dir") or "").strip() or None
        self.superseded_by = d.get("superseded_by", "").split()
        self.shard_list = d.get("shard_list", "").strip() or None
        self.shard_kind = d.get("shard_kind", "").strip() or None
        self.shard_item = d.get("shard_item", "").strip() or None
        self.shard_total = d.get("shard_total", "").strip() or None
        self.shard_each = float(d.get("shard_each_s", "30"))
        self.shard_target = float(d.get("shard_target_s", "300"))
        self.shard_check = d.get("shard_check", "").strip() or None
        self.unsharded_cmd = d.get("unsharded_cmd") or None
        # GitHub Actions placement (ADR-053 §2.8): the job this step runs in (default: its group), or
        # an explicit exclusion with its reason. None = key absent (an EMPTY actions_skip is "").
        self.actions_job = d["actions_job"].strip() if "actions_job" in d else None
        self.actions_skip = d["actions_skip"].strip() if "actions_skip" in d else None
        # mix projects whose deps/_build (and PLTs) the Actions job caches; default: cwd + app: inputs
        self.actions_dirs = d.get("actions_dirs", "").split() if "actions_dirs" in d else None
        # nightly: split this sharded step across N parallel jobs (scripts/ci full --slice i/N)
        self.actions_slices = int(d["actions_slices"]) if d.get("actions_slices", "").strip() else None
        if self.actions_slices is not None and (not d.get("shard_list") or self.actions_slices < 2):
            raise UsageError("manifest: step %s: actions_slices needs a sharded step (shard_list) and N >= 2" % sid)
        if self.shard_list and self.shard_kind not in ("ranges", "modulo"):
            raise UsageError("manifest: step %s: shard_kind must be ranges|modulo" % sid)
        # the lister's OWN count is required: an item regex that stops matching (the lister's
        # output format drifted) must FAIL the step, never shrink the selection to "0 — PASS"
        if self.shard_list and not self.shard_total:
            raise UsageError("manifest: step %s: a sharded step needs shard_total (the lister's own count)" % sid)
        if self.shard_kind == "ranges" and not self.shard_item:
            raise UsageError("manifest: step %s: ranges sharding needs shard_item" % sid)
        # runtime (filled by the planner)
        self.parent = None
        self.shard_args = ""
        self.shard_items = None
        self.expected = None       # shard_check expectation
        self.processed = None      # what the sub-step reported (shard_check)
        self.selected_total = None # the lister's own count of the whole selection
        self.preset = None         # ("PASS"|"FAIL", note) decided at plan time (empty shard / list error)
        self.key = None

    def definition(self, apps):
        """What the cache key hashes about the step itself (not est/locks/markers/modes)."""
        return {
            "v": KEY_VERSION, "id": self.parent or self.id, "cmd": self.cmd, "cwd": self.cwd,
            "inputs": expand_tokens(self.inputs, apps), "reads": expand_tokens(self.reads, apps),
            "exunit_dir": self.exunit_dir, "shard_args": self.shard_args,
            "shard_items": self.shard_items, "shard_check": self.shard_check,
        }


class Manifest(object):
    def __init__(self, path):
        if not os.path.isfile(path):
            raise UsageError("manifest not found: %s" % path)
        cp = configparser.ConfigParser(interpolation=None, delimiters=("=",), comment_prefixes=("#",),
                                       inline_comment_prefixes=None, empty_lines_in_values=False,
                                       strict=True, default_section="__none__")
        cp.optionxform = str
        try:
            with open(path) as f:
                cp.read_file(f)
        except configparser.Error as e:
            raise UsageError("manifest %s: %s" % (path, e))
        self.apps, self.groups, self.steps = {}, {}, []
        for sec in cp.sections():
            kind, _, name = sec.partition(" ")
            d = dict(cp[sec])
            if kind == "app":
                p = d.get("path", name + "/").strip()
                self.apps[name] = {"path": p if p.endswith("/") else p + "/", "deps": d.get("deps", "").split()}
            elif kind == "group":
                self.groups[name] = {"markers": [l.strip() for l in d.get("marker", "").split("\n") if l.strip()]}
            elif kind == "step":
                self.steps.append(Step(name, d))
            else:
                raise UsageError("manifest: unknown section [%s]" % sec)
        ids = [s.id for s in self.steps]
        for a, v in self.apps.items():
            for dep in v["deps"]:
                if dep not in self.apps:
                    raise UsageError("manifest: app %s depends on unknown app %s" % (a, dep))
        for s in self.steps:
            for tok in s.inputs + s.reads:
                if tok.startswith("app:") and tok[4:] not in self.apps:
                    raise UsageError("manifest: step %s names unknown app %s" % (s.id, tok))
            for x in s.superseded_by:
                if x not in ids:
                    raise UsageError("manifest: step %s superseded_by unknown step %s" % (s.id, x))
        transitive_deps(self.apps)  # raises on a cycle

    def by_id(self, sid):
        for s in self.steps:
            if s.id == sid:
                return s
        return None


def transitive_deps(apps, name=None):
    def walk(n, seen, stack):
        if n in stack:
            raise UsageError("manifest: dependency cycle through app %s" % n)
        for d in apps[n]["deps"]:
            if d not in seen:
                seen.append(d)
                walk(d, seen, stack + [n])
        return seen
    if name is None:
        for n in apps:
            walk(n, [], [])
        return None
    return walk(name, [], [])


def expand_tokens(tokens, apps):
    """-> sorted list of normalized rules: 'inc:<pat>', 'inc:<pat>|-<exc>', 'exc:<pat>', '@base'."""
    rules = set()
    for t in tokens:
        if t == "@base":
            rules.add("@base")
        elif t.startswith("!"):
            rules.add("exc:" + t[1:])
        elif t.startswith("app:"):
            name = t[4:]
            rules.add("inc:" + apps[name]["path"])
            for dep in transitive_deps(apps, name):
                p = apps[dep]["path"]
                rules.add("inc:%s|-%stest/" % (p, p))
        else:
            rules.add("inc:" + t)
    # an unconditional include of a path makes its excluded-variant redundant
    plain = {r[4:] for r in rules if r.startswith("inc:") and "|-" not in r}
    rules = {r for r in rules if not (r.startswith("inc:") and "|-" in r and r[4:].split("|-")[0] in plain)}
    return sorted(rules)


def pat_match(path, pat):
    if pat == "**":
        return True
    if pat.endswith("/"):
        return path.startswith(pat)
    if any(c in pat for c in "*?["):
        return fnmatch.fnmatchcase(path, pat)
    return path == pat or path.startswith(pat + "/")


def make_matcher(rules):
    incs, excs = [], []
    for r in rules:
        if r.startswith("inc:"):
            body = r[4:]
            if "|-" in body:
                p, e = body.split("|-", 1)
                incs.append((p, e))
            else:
                incs.append((body, None))
        elif r.startswith("exc:"):
            excs.append(r[4:])

    def m(path):
        if any(pat_match(path, e) for e in excs):
            return False
        for p, e in incs:
            if pat_match(path, p) and not (e and pat_match(path, e)):
                return True
        return False
    return m


# ── repository snapshot: tracked + untracked-not-ignored CONTENT, via a throwaway index ──────────
class Snapshot(object):
    def __init__(self):
        idx_rel = git("rev-parse", "--git-path", "index").strip()
        idx = idx_rel if os.path.isabs(idx_rel) else os.path.join(REPO, idx_rel)
        # the throwaway index lives OUTSIDE the work tree, so `add -A` can never pick it up
        tmpdir = tempfile.mkdtemp(prefix="samen_ci_snap.")
        tmp = os.path.join(tmpdir, "index")
        if os.path.exists(idx):
            shutil.copy2(idx, tmp)  # keep its mtime: git's racy-clean check compares against it
        env = dict(os.environ, GIT_INDEX_FILE=tmp)
        p = subprocess.run(["git", "-C", REPO, "add", "-A", "--", "."], stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, env=env)
        if p.returncode != 0:
            shutil.rmtree(tmpdir, ignore_errors=True)
            raise UsageError("snapshot: git add -A failed: %s" % p.stderr.decode(errors="replace").strip())
        self.tree = git("write-tree", env=env).strip()
        raw = git("ls-tree", "-r", "-z", "--full-tree", self.tree, env=env, binary=True)
        shutil.rmtree(tmpdir, ignore_errors=True)
        rel_home = os.path.relpath(HOME, REPO)
        home_prefix = None if rel_home.startswith("..") else rel_home + "/"
        self.files = []
        for ent in raw.split(b"\0"):
            if not ent:
                continue
            meta, path = ent.split(b"\t", 1)
            mode, _typ, sha = meta.split(b" ")
            path = path.decode(errors="surrogateescape")
            if home_prefix and path.startswith(home_prefix):
                continue  # the driver's own state never keys a step
            self.files.append((path, (mode + b" " + sha).decode()))
        self.files.sort()
        self._memo = {}

    def digest(self, rules):
        k = tuple(rules)
        if k not in self._memo:
            m = make_matcher([r for r in rules if r != "@base"])
            h = hashlib.sha256()
            n = 0
            for path, blob in self.files:
                if m(path):
                    h.update(path.encode(errors="surrogateescape") + b"\0" + blob.encode() + b"\n")
                    n += 1
            self._memo[k] = (h.hexdigest(), n)
        return self._memo[k]


# The ./ci.sh opt-in switches select steps (--also); they are never a step's business. Stripped from
# every step's environment so `SAMEN_MULTINODE=1 ./ci.sh` runs the SAME samen_core suite as
# `./ci.sh` (the multinode step sets the variable itself) and the cache keys below do not split.
WRAPPER_FLAGS = ("SAMEN_SABOTAGE", "SAMEN_MUTATION", "SAMEN_MULTINODE")
# C2: environment that changes what a step does is part of every cache key — a PASS earned under
# SAMEN_UPDATE_GOLDEN=1, SAMEN_EMPTY_ASH_DOMAINS=1, a stub SAMEN_MUTATION_RUNNER, another
# PGHOST/DATABASE_URL or MIX_ENV, GEN_PROBE_GUARD_DISABLE_TRAP=1 … never vouches for a run without
# it. SAMEN_CI_* are the driver's own seams (SAMEN_CI_TOOLCHAIN feeds the toolchain part).
ENV_KEYED = re.compile(r"^(SAMEN_|MIX_|ELIXIR_|ERL_|HEX_|REBAR|PG|DATABASE_URL$|DRILL_|DRIFTWOOD_|GEN_PROBE_|LOG_LEVEL$)")


def step_base_env():
    return {k: v for k, v in os.environ.items() if k not in WRAPPER_FLAGS}


def env_fingerprint():
    return "\n".join("%s=%s" % (k, v) for k, v in sorted(step_base_env().items())
                     if ENV_KEYED.match(k) and not k.startswith("SAMEN_CI_"))


def toolchain_fingerprint():
    fp = os.environ.get("SAMEN_CI_TOOLCHAIN")
    if fp is not None:
        return fp
    parts = []
    probes = [
        ["elixir", "-e", "IO.write(System.version())"],
        ["erl", "-noshell", "-eval",
         '{ok,V}=file:read_file(filename:join([code:root_dir(),"releases",erlang:system_info(otp_release),"OTP_VERSION"])), io:format("~s",[string:trim(V)]), halt().'],
        ["psql", "-V"],
        ["uname", "-sm"],
    ]
    for argv in probes:
        try:
            p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60)
            parts.append(p.stdout.decode(errors="replace").strip() or "?")
        except (OSError, subprocess.TimeoutExpired):
            parts.append("missing:" + argv[0])
    return " | ".join(parts)


# ── context: base, diff, snapshot ───────────────────────────────────────────────────────────────
class Context(object):
    def __init__(self, base, need_base):
        self.base = base
        self.base_sha = git("rev-parse", "--verify", "-q", base + "^{commit}", check=False).strip()
        if not self.base_sha and need_base:
            raise UsageError("--base %s does not resolve in this clone (git fetch origin main, or pass --base <ref>)" % base)
        self.merge_base = ""
        if self.base_sha:
            self.merge_base = git("merge-base", "HEAD", self.base_sha, check=False).strip() or self.base_sha
        self.head = git("rev-parse", "HEAD", check=False).strip()
        self.snap = Snapshot()
        self.tree = self.snap.tree
        self.toolchain = toolchain_fingerprint()
        self.env_fp = env_fingerprint()
        self._changed = None

    def changed(self):
        """Paths changed vs the merge-base: tracked diff (both sides of renames, deletions too) ∪
        untracked-not-ignored. The untracked half is load-bearing (`git diff` never lists new files)."""
        if self._changed is None:
            if not self.merge_base:
                raise UsageError("quick needs a base: --base %s does not resolve" % self.base)
            a = git("diff", "--name-only", "--no-renames", "-z", self.merge_base, binary=True)
            b = git("ls-files", "--others", "--exclude-standard", "-z", binary=True)
            paths = {p.decode(errors="surrogateescape") for p in (a + b).split(b"\0") if p}
            rel_home = os.path.relpath(HOME, REPO)
            self._changed = sorted(p for p in paths if rel_home.startswith("..") or not p.startswith(rel_home + "/"))
        return self._changed

    def env(self, mode, step):
        e = step_base_env()
        e.update({"REPO_ROOT": REPO, "CI_MODE": mode, "CI_STEP": step.id,
                  "CI_BASE": self.base, "CI_BASE_SHA": self.base_sha, "CI_MERGE_BASE": self.merge_base,
                  "CI_SHARD_ARGS": step.shard_args})
        return e

    def key(self, step, apps, snap=None):
        rules = expand_tokens(step.inputs + step.reads, apps)
        if not [r for r in rules if r != "@base"]:
            return None  # C2: a step with no declared inputs is NEVER cached
        if "@base" in rules and not self.base_sha:
            return None  # keyed on a base this clone does not have: never cached (nor its banner lost)
        snap = snap or self.snap
        dig, _n = snap.digest(rules)
        h = hashlib.sha256()
        h.update(json.dumps(step.definition(apps), sort_keys=True).encode())
        h.update(b"\0toolchain\0" + self.toolchain.encode())
        h.update(b"\0env\0" + self.env_fp.encode())
        h.update(b"\0files\0" + dig.encode())
        if "@base" in rules:
            h.update(("\0base\0%s\0%s" % (self.base_sha, self.merge_base)).encode())
        return h.hexdigest()


def affected(step, apps, changed):
    rules = expand_tokens(step.inputs, apps)
    m = make_matcher([r for r in rules if r != "@base"])
    return [p for p in changed if m(p)]


# ── planning ────────────────────────────────────────────────────────────────────────────────────
def run_capture(cmd, cwd, env):
    p = subprocess.run(["bash", "-c", "set -euo pipefail\n" + cmd], cwd=os.path.join(REPO, cwd), env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.returncode, p.stdout.decode(errors="replace")


def clone_step(step, sid):
    s = Step.__new__(Step)
    s.__dict__.update(step.__dict__)
    s.locks = set(step.locks)
    s.id = sid
    s.parent = step.id
    return s


def per_item_bucket(old, rate):
    """The learned per-item cost, as a power-of-two bucket with hysteresis. Chunk boundaries are
    part of every sub-step's cache key, so the rate must not wobble with machine noise: it moves UP
    as soon as one run is slower than the bucket, and DOWN only when a run is under a quarter of it."""
    old = float(old or 0)
    fit = 2.0 ** math.ceil(math.log(max(rate, 0.01), 2))
    if rate > old or (old and rate < old / 4):
        return fit
    return old


def balanced_chunks(nums, n):
    """nums = sorted [(number, item)] -> at most n chunks of near-equal size, never splitting a number."""
    per = max(1, int(math.ceil(len(nums) / float(n))))
    chunks, cur = [], []
    for k, it in nums:
        if cur and len(cur) >= per and k != cur[-1][0]:
            chunks.append(cur)
            cur = []
        cur.append((k, it))
    if cur:
        chunks.append(cur)
    if len(chunks) > n:
        raise UsageError("slice accounting: %d chunks for %d slices" % (len(chunks), n))
    return chunks


def expand_shards(step, ctx, mode, budget, apps, no_cache=False, slice_=None):
    """A long internal loop → budget-sized sub-steps. Unbudgeted (budget 0) a step with an
    unsharded_cmd runs it as ONE step, exactly the pre-ADR-053 command."""
    if budget == 0 and step.unsharded_cmd and not slice_:
        s = clone_step(step, step.id)
        s.parent = None
        s.cmd = step.unsharded_cmd
        s.shard_check = None
        s.shard_list = None
        return [s]
    env = ctx.env(mode, step)
    # the LISTING is a pure function of the parent step's content key (inputs + base + definition):
    # reuse it while that key holds (sabotage --list / mutate --list cost 15-20 s each)
    pkey = ctx.key(step, apps)
    lpath = os.path.join(HOME, "cache", "listing", (pkey or "none") + ".json")
    hit = read_json(lpath) if (pkey and not no_cache) else None
    if hit and hit.get("cmd") == step.shard_list:
        rc, text = 0, hit["text"]
    else:
        rc, text = run_capture(step.shard_list, step.cwd, env)
        if rc == 0 and pkey:
            atomic_write_json(lpath, {"cmd": step.shard_list, "text": text})
    def listing_fail(why):
        s = clone_step(step, step.id)
        s.parent = None
        s.preset = ("FAIL", why)
        return [s]
    if rc != 0:
        return listing_fail("could not list the shard items (exit %d):\n%s" % (rc, text[-4000:]))
    # the lister's own count, exactly once — the selection is never inferred from what the item
    # regex happened to match (a drifted output format would otherwise read as "0 selected")
    totals = [m.group(1) for m in re.finditer(step.shard_total, text, re.M)]
    if len(totals) != 1 or not totals[0].isdigit():
        return listing_fail("shard listing unparseable: shard_total /%s/ matched %d time(s) %r — refusing to "
                            "guess the selection:\n%s" % (step.shard_total, len(totals), totals[:3], text[-2000:]))
    total = int(totals[0])
    # per-item cost = max(manifest shard_each_s, the per-item rate this machine last OBSERVED): a
    # chunk sized on an optimistic estimate could outgrow a whole tool call, and a sub-step that can
    # never finish inside one is a sub-step `resume` can never complete
    learned = float((read_json(os.path.join(HOME, "timings.json")) or {}).get(step.id + "#per_item", 0))
    each = max(step.shard_each, learned)
    if step.shard_kind == "ranges":
        items = [m.group(1) for m in re.finditer(step.shard_item, text, re.M)]
        if len(items) != total:
            return listing_fail("shard listing accounting: the lister says %d selected, shard_item /%s/ matched %d "
                                "— refusing to run a different selection than the one listed" % (total, step.shard_item, len(items)))
    else:
        items = [str(total)]
    if step.shard_kind == "ranges":
        nums = []
        for it in items:
            m = re.match(r"^(\d+)-", it)
            if not m:
                s = clone_step(step, step.id)
                s.parent = None
                s.preset = ("FAIL", "shard item without a numeric prefix: %r" % it)
                return [s]
            nums.append((int(m.group(1)), it))
        nums.sort()
        if slice_:
            chunks = balanced_chunks(nums, slice_[1])
        else:
            per = max(1, int(step.shard_target // max(each, 0.001)))
            chunks, cur = [], []
            for n, it in nums:
                # never split one number across chunks (duplicate numbers exist: 25-, 35-)
                if cur and len(cur) >= per and n != cur[-1][0]:
                    chunks.append(cur)
                    cur = []
                cur.append((n, it))
            if cur:
                chunks.append(cur)
        if sum(len(c) for c in chunks) != len(items):  # accounting: the shards ARE the selection
            raise UsageError("shard accounting: %s chunks hold %d of %d items" % (step.id, sum(len(c) for c in chunks), len(items)))
        specs = [("--range %d-%d" % (c[0][0], c[-1][0]), [it for _n, it in c]) for c in chunks]
    else:
        count = total
        n = slice_[1] if slice_ else (max(1, int(math.ceil(count * each / step.shard_target))) if count else 0)
        specs = []
        for i in range(1, n + 1):
            size = len([x for x in range(count) if x % n == i - 1])
            specs.append(("--shard %d/%d" % (i, n), ["%d mutants of %d" % (size, count)], size))
        if sum(sp[2] for sp in specs) != count:
            raise UsageError("shard accounting: %s shards hold %d of %d mutants" % (step.id, sum(sp[2] for sp in specs), count))
        specs = [(a, it, sz) for a, it, sz in specs]
    if slice_:
        i, n = slice_
        if i <= len(specs):
            specs = [specs[i - 1]]
        else:  # fewer chunks than slices (a tiny selection): this slice is genuinely empty
            s = clone_step(step, "%s[%d/%d]" % (step.id, i, n))
            s.parent = step.id
            s.expected, s.processed, s.selected_total = 0, 0, total
            s.preset = ("PASS", "empty slice %d/%d — the selection of %d has fewer chunks than slices" % (i, n, total))
            return [s]
    if not specs:
        s = clone_step(step, step.id)
        s.parent = None
        s.preset = ("PASS", "nothing selected — 0 items for %s" % step.id)
        return [s]
    subs = []
    selected_total = total
    total = len(specs)
    for i, sp in enumerate(specs, 1):
        args, its = sp[0], sp[1]
        sid = "%s[%d/%d]" % (step.id, slice_[0], slice_[1]) if slice_ else "%s[%d/%d]" % (step.id, i, total)
        s = clone_step(step, sid)
        s.selected_total = selected_total
        s.shard_args = args
        s.shard_items = its
        s.expected = sp[2] if len(sp) > 2 else len(its)
        s.est = (s.expected * each) + 10
        s.group = step.id  # the parent's markers print once every shard passed
        subs.append(s)
    return subs


def build_plan(man, mode, ctx, opts, quiet=False):
    """-> (plan, notes) where notes = list of (step, reason) not planned but worth a SKIP line."""
    also = set(opts.get("also") or [])
    only = set(opts.get("only") or [])
    for x in also | only:
        if not man.by_id(x) and x not in {s.group for s in man.steps} and not opts.get("exact"):
            raise UsageError("no step or group named %r (scripts/ci list)" % x)
    cand = [s for s in man.steps if mode in s.modes or s.id in also or s.group in also]
    if only and opts.get("exact"):
        # --only-steps: step IDS only. A step whose id equals a group name (samen_core) must not drag in
        # the rest of that group — the Actions jobs name their steps, and `actions verify` would catch the
        # extra step only after it ran twice.
        unknown = sorted(x for x in only if not man.by_id(x))
        if unknown:
            raise UsageError("--only-steps: no step named %s" % ", ".join(unknown))
        cand = [s for s in cand if s.id in only]
        if not cand:
            raise UsageError("--only-steps %s selects nothing in mode %s" % (",".join(sorted(only)), mode))
    elif only:
        cand = [s for s in cand if s.id in only or s.group in only]
        if not cand:
            raise UsageError("--only %s selects nothing in mode %s" % (",".join(sorted(only)), mode))
    ids = {s.id for s in cand}
    cand = [s for s in cand if not any(x in ids for x in s.superseded_by)]
    skipped = []
    if mode == "quick":
        changed = ctx.changed()
        keep = []
        for s in cand:
            hit = affected(s, man.apps, changed)
            if s.always or hit:
                keep.append(s)
            else:
                skipped.append((s, "not affected"))
        cand = keep
    for s in man.steps:  # opt-in tiers are a pr-mode notion (./ci.sh's SAMEN_* flags)
        if mode == "pr" and s not in cand and s.skip_marker and s.id not in ids and not only:
            skipped.append((s, "opt-in: not in %s" % mode))
    plan = []
    budget = opts.get("budget", 540)
    for s in cand:
        if s.shard_list:
            plan.extend(expand_shards(s, ctx, mode, budget, man.apps, no_cache=bool(opts.get("no_cache")),
                                      slice_=opts.get("slice")))
        else:
            plan.append(s)
    seen = read_json(os.path.join(HOME, "timings.json")) or {}
    for s in plan:
        s.key = ctx.key(s, man.apps)
        # the budget plans with max(manifest est, last observed wall-clock): a step that ran long
        # once is never again scheduled into a slot it cannot finish in
        s.est = max(s.est, float(seen.get(s.id, 0)))
    return plan, skipped


# ── failure digests ─────────────────────────────────────────────────────────────────────────────
EXU_HDR = re.compile(r"^\s+\d+\) (test|property|doctest) .*")
EXU_LOC = re.compile(r"^\s+((?:[\w.@+-]+/)*[\w.@+-]+\.exs?):(\d+)\s*$")
SPECIAL = re.compile(r"(DIALYZER: FAILED|^\s+(lib|test)/\S+:\d+|SABOTAGE HARNESS: (FAILED|PROCESSED)|NOT EXERCISED"
                     r"|named test did not flip|MUTATION GATE: FAILED|SURVIVED \(UNEXEMPT\)|SELF-TEST FAILED"
                     r"|APPLY CHECK: FAILED|DOES NOT APPLY|DOUBLE SWEEP: FAILED|TOOLCHAIN CHECK: FAILED"
                     r"|\*\* \(\w+Error\)|FAILED:|== Compilation error|error: )")


def parse_exunit(text):
    lines = text.splitlines()
    res, i = [], 0
    while i < len(lines):
        if EXU_HDR.match(lines[i]):
            name, loc, detail, j = lines[i].strip(), None, [], i + 1
            while j < len(lines) and j < i + 14:
                l = lines[j]
                if EXU_HDR.match(l) or l.strip().startswith("stacktrace:"):
                    break
                lm = EXU_LOC.match(l)
                if lm and loc is None:
                    loc = "%s:%s" % (lm.group(1), lm.group(2))
                elif l.strip() and loc is not None and len(detail) < 4:
                    detail.append(l.strip())
                j += 1
            res.append({"test": name, "loc": loc, "detail": detail})
            i = j
            continue
        i += 1
    return res


LOG_SEP = "# " + "-" * 70


def make_digest(text):
    text = ANSI.sub("", text)
    if LOG_SEP in text:  # drop the driver's own log header (the cmd echo)
        text = text.split(LOG_SEP + "\n", 1)[-1]
    exu = parse_exunit(text)
    lines = []
    for f in exu[:10]:
        lines.append(f["test"] + ("  @ " + f["loc"] if f["loc"] else ""))
        lines.extend("    " + d for d in f["detail"])
    if len(exu) > 10:
        lines.append("… and %d more failing test(s)" % (len(exu) - 10))
    seen = set()
    for l in text.splitlines():
        if SPECIAL.search(l) and not EXU_HDR.match(l) and l.strip() not in seen:
            seen.add(l.strip())
            lines.append(l.rstrip())
            if len(seen) >= 30:
                break
    if not lines:
        lines = text.splitlines()[-40:]
    return lines


# ── the run ─────────────────────────────────────────────────────────────────────────────────────
class Run(object):
    def __init__(self, man, mode, opts, ctx, state, resumed):
        self.man, self.mode, self.opts, self.ctx = man, mode, opts, ctx
        self.state = state
        self.resumed = resumed
        self.markers = bool(opts.get("markers"))
        self.status = {}     # id -> status
        self.results = {}    # id -> dict
        self.groups_done = set()
        self.interrupted = False
        self.running = {}    # id -> dict(proc, step, start, log)

    # ── printing ──
    def say_markers(self, step):
        if not self.markers:
            return
        if step.markers and not step.parent:
            if step.marker_if:
                log = self.results.get(step.id, {}).get("log")
                text = ""
                if log and os.path.exists(os.path.join(REPO, log)):
                    with open(os.path.join(REPO, log), errors="replace") as f:
                        text = f.read()
                elif self.status.get(step.id) == "CACHED":
                    text = None  # a cached PASS earned its marker when it ran
                if text is not None and not re.search(step.marker_if, text, re.M):
                    return
            for m in step.markers:
                out(m)

    def check_groups(self):
        for g in sorted({s.group for s in self.plan if s.group}):
            if g in self.groups_done:
                continue
            members = [s for s in self.plan if s.group == g]
            if members and all(self.status.get(s.id) in DONE for s in members):
                self.groups_done.add(g)
                if not self.markers:
                    continue
                gm = list(self.man.groups.get(g, {}).get("markers", []))
                parent = self.man.by_id(g)
                if parent and members[0].parent:  # sharded step: its markers are the group's
                    gm += parent.markers
                for m in gm:
                    out(m)

    def echo(self, step, text):
        if not step.echo_log:
            return
        for l in text.splitlines():
            if re.search(step.echo_log, l):
                out(l if self.markers else "  | " + l)

    # ── state ──
    def save_state(self):
        self.state["steps"] = self.state.get("steps", {})
        self.state["running"] = {sid: r["proc"].pid for sid, r in self.running.items()}
        atomic_write_json(os.path.join(HOME, "state.json"), self.state)

    def record(self, step, status, duration, log=None, digest=None, note=None, key=None):
        self.status[step.id] = status
        r = {"id": step.id, "status": status, "duration_s": round(duration, 2), "log": log,
             "digest": digest or [], "note": note, "key": key if key is not None else step.key,
             "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
        for k in ("expected", "processed", "selected_total"):
            if getattr(step, k, None) is not None:
                r[k] = getattr(step, k)
        self.results[step.id] = r
        self.state.setdefault("steps", {})[step.id] = r
        self.save_state()

    # ── cache ──
    def cache_path(self, key):
        return os.path.join(HOME, "cache", key[:2], key + ".json")

    def cache_hit(self, step):
        if self.opts.get("no_cache") or not step.key:
            return None
        return read_json(self.cache_path(step.key))

    def cache_put(self, step, duration):
        if not step.key:
            return
        atomic_write_json(self.cache_path(step.key), {"id": step.id, "key": step.key, "duration_s": round(duration, 2),
                                                      "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                                                      "tree": self.ctx.tree})

    def cache_evict(self, step):
        if not step.key:
            return
        try:
            os.remove(self.cache_path(step.key))
        except OSError:
            pass

    # ── launch / finish ──
    def launch(self, step):
        logrel = os.path.join(os.path.relpath(HOME, REPO), "logs", safe_name(step.id) + ".log")
        logabs = os.path.join(REPO, logrel)
        os.makedirs(os.path.dirname(logabs), exist_ok=True)
        f = open(logabs, "w")
        f.write("# scripts/ci %s · step %s · cwd %s · %s\n# cmd:\n%s\n%s\n" % (
            self.mode, step.id, step.cwd, time.strftime("%Y-%m-%dT%H:%M:%S"),
            "\n".join("#   " + l for l in step.cmd.splitlines()), LOG_SEP))
        f.flush()
        proc = subprocess.Popen(["bash", "-c", "set -euo pipefail\n" + step.cmd],
                                cwd=os.path.join(REPO, step.cwd), env=self.ctx.env(self.mode, step),
                                stdout=f, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                start_new_session=True)
        self.running[step.id] = {"proc": proc, "step": step, "start": time.time(), "log": logrel, "fh": f}
        self.status[step.id] = "RUNNING"
        self.save_state()

    def flaky_rerun(self, step, text, logabs):
        fails = parse_exunit(ANSI.sub("", text))
        locs = []
        for fl in fails:
            if fl["loc"] and fl["loc"] not in locs:
                locs.append(fl["loc"])
        if not step.exunit_dir or not locs or len(locs) > 25 or len(locs) < len(fails):
            return None
        cmd = "mix test " + " ".join(shlex.quote(l) for l in locs)
        with open(logabs + ".rerun", "w") as f:
            f.write("# FLAKE CHECK — the failing tests, once, in isolation: (cd %s && %s)\n" % (step.exunit_dir, cmd))
            f.flush()
            p = subprocess.run(["bash", "-c", cmd], cwd=os.path.join(REPO, step.exunit_dir),
                               env=self.ctx.env(self.mode, step), stdout=f, stderr=subprocess.STDOUT,
                               stdin=subprocess.DEVNULL)
        return p.returncode == 0

    def finish(self, sid, rc):
        r = self.running.pop(sid)
        r["fh"].close()
        step, dur = r["step"], time.time() - r["start"]
        logabs = os.path.join(REPO, r["log"])
        with open(logabs, errors="replace") as f:
            text = f.read()
        self.echo(step, text)
        note = None
        if r.get("signalled") and rc == 0:
            # C1: the driver signalled this step's process group. An exit 0 after that is a TRAP
            # that swallowed the signal (bash continues after a TERM trap returns), not a step
            # that ran to completion — it can never be PASS, never be cached, never be "earlier
            # in this run" on resume.
            rc = 143
        if rc == 0 and step.shard_check and step.expected is not None:
            m = None
            for m in re.finditer(step.shard_check, text, re.M):
                pass
            got = int(m.group(1)) if m else None
            step.processed = got
            if got != step.expected:
                rc = 97
                note = "shard accounting: processed %s, expected %d — a sub-step that does not cover its chunk can never pass" % (got, step.expected)
        if not self.interrupted:
            tp = os.path.join(HOME, "timings.json")
            seen = read_json(tp) or {}
            seen[step.id] = round(dur, 1)
            if rc == 0 and step.parent and step.expected:
                seen[step.parent + "#per_item"] = per_item_bucket(seen.get(step.parent + "#per_item", 0), dur / step.expected)
            atomic_write_json(tp, seen)
        if rc == 0:
            # C2: cache only if the step's inputs did not change while it ran
            post = self.ctx.key(step, self.man.apps, snap=Snapshot()) if step.key else None
            self.record(step, "PASS", dur, log=r["log"])
            out("PASS %s %s" % (step.id, fmt_s(dur)))
            if step.key and post == step.key:
                self.cache_put(step, dur)
            elif step.key:
                out("  (not cached: its inputs changed while it ran)")
            self.say_markers(step)
            self.check_groups()
            return
        status = "FAIL"
        if rc != 97 and not self.interrupted and not r.get("signalled"):
            flaky = self.flaky_rerun(step, text, logabs)
            if flaky:
                status = "FLAKY"
                note = "FLAKY (passed on rerun) — a flaky test still FAILS the run; rerun log: %s.rerun" % r["log"]
            elif flaky is False:
                note = "failed again on an isolated rerun (not a flake); rerun log: %s.rerun" % r["log"]
        if status in ("FAIL", "FLAKY") and not (self.interrupted or r.get("signalled")):
            # C3/C5: this exact content just went red — an older PASS under the same key no longer
            # vouches for it (a flaky red must not turn into "CACHED" on the very next run)
            self.cache_evict(step)
        if self.interrupted or r.get("signalled"):
            status = "INTERRUPTED"
        digest = ([note] if note and status != "INTERRUPTED" else []) + make_digest(text)
        self.record(step, status, dur, log=r["log"], digest=digest, note=note)
        if status == "INTERRUPTED":
            out("INTERRUPTED %s %s" % (step.id, fmt_s(dur)))
            return
        label = "FLAKY %s %s (passed on rerun)" % (step.id, fmt_s(dur)) if status == "FLAKY" else "FAIL %s %s" % (step.id, fmt_s(dur))
        out(label)
        for l in digest[:60]:
            out("  " + l)
        out("  log: %s" % r["log"])
        if self.markers:
            out("==> %s: FAILED (exit %d)" % (step.id, rc))

    # ── the scheduler ──
    def execute(self, t0):
        """t0 = when this invocation STARTED (planning time counts against the budget too)."""
        opts, plan = self.opts, self.plan
        budget = float(opts.get("budget", 540))
        jobs = max(1, int(opts.get("jobs") or 1))
        keep_going = bool(opts.get("keep_going"))
        prior = self.state.get("steps", {}) if self.resumed else {}
        pending = []
        for s in plan:
            pr = prior.get(s.id)
            if s.preset:
                st, note = s.preset
                self.record(s, st, 0.0, note=note, digest=[note] if st != "PASS" else [])
                out(("PASS %s 0.0s (%s)" % (s.id, note)) if st == "PASS" else "FAIL %s 0.0s\n  %s" % (s.id, note))
                if st == "PASS":
                    self.say_markers(s)
                continue
            if pr and pr.get("status") == "PASS" and s.key and pr.get("key") == s.key:
                self.status[s.id] = "PASS"
                self.results[s.id] = pr
                out("PASS %s %s (earlier in this run)" % (s.id, fmt_s(pr.get("duration_s", 0))))
                self.say_markers(s)
                continue
            hit = self.cache_hit(s)
            if hit:
                self.record(s, "CACHED", 0.0, note="cached PASS from %s (%s)" % (hit.get("at"), fmt_s(hit.get("duration_s", 0))))
                out("CACHED %s" % s.id)
                self.say_markers(s)
                continue
            pending.append(s)
        self.check_groups()
        launched = 0
        stop_reason = None
        failed = any(self.status.get(s.id) in ("FAIL", "FLAKY") for s in plan)
        while True:
            if not self.interrupted and not (failed and not keep_going):
                for s in list(pending):
                    serial_running = any(r["step"].serial for r in self.running.values())
                    if serial_running:
                        break
                    if s.serial and self.running:
                        break  # barrier: a serial step waits for everything before it
                    if not s.serial and len(self.running) >= jobs:
                        break
                    busy = set()
                    for r in self.running.values():
                        busy |= r["step"].locks
                    if s.locks & busy:
                        continue
                    elapsed = time.time() - t0
                    if budget > 0 and launched > 0 and elapsed + s.est > budget:
                        stop_reason = "next step %s (est %s) would overrun the budget: %s of %s used" % (
                            s.id, fmt_s(s.est), fmt_s(elapsed), fmt_s(budget))
                        break
                    if budget > 0 and launched == 0 and self.running == {} and s.est > budget:
                        out("  (%s est %s exceeds the whole budget — running it anyway: the first step of an invocation always runs)" % (s.id, fmt_s(s.est)))
                    pending.remove(s)
                    self.launch(s)
                    launched += 1
                    if s.serial:
                        break
            if not self.running:
                break
            time.sleep(0.2)
            for sid in list(self.running):
                rc = self.running[sid]["proc"].poll()
                if rc is not None:
                    self.finish(sid, rc)  # C6: every exit code collected, one by one
                    if self.status.get(sid) in ("FAIL", "FLAKY"):
                        failed = True
            if self.interrupted:
                self.terminate_all()
        return t0, pending, stop_reason

    def terminate_all(self):
        for r in self.running.values():
            r["signalled"] = True
            try:
                os.killpg(r["proc"].pid, signal.SIGTERM)  # SIGTERM first: gen-probe/sabotage traps restore
            except OSError:
                pass
        deadline = time.time() + 20
        while self.running and time.time() < deadline:
            for sid in list(self.running):
                rc = self.running[sid]["proc"].poll()
                if rc is not None:
                    self.finish(sid, rc)
            time.sleep(0.2)
        for sid in list(self.running):
            try:
                os.killpg(self.running[sid]["proc"].pid, signal.SIGKILL)
            except OSError:
                pass
            self.running[sid]["proc"].wait()
            self.finish(sid, -9)


def final_line(mode, opts, plan, status, elapsed, first_fail):
    m = len(plan)
    n = sum(1 for s in plan if status.get(s.id) in DONE)
    tag = mode + (" --only " + ",".join(opts["only"]) if opts.get("only") else "")
    if first_fail:
        line, verdict = "CI(%s): FAIL step=%s (%d/%d) — see %s/last.json" % (
            tag, first_fail, n, m, os.path.relpath(HOME, REPO)), "FAIL"
    elif n < m:
        line, verdict = "CI(%s): INCOMPLETE %d/%d — continue: scripts/ci resume" % (tag, n, m), "INCOMPLETE"
    else:
        # C1: PASS only when every planned step is PASS/CACHED — re-asserted, not inferred
        assert all(status.get(s.id) in DONE for s in plan)
        line, verdict = "CI(%s): PASS %d/%d in %s" % (tag, n, m, fmt_s(elapsed)), "PASS"
        if mode in ("pr", "full") and not opts.get("only"):
            line += " — PR-READY"
    if mode in ("quick", "fast") or (opts.get("only") and verdict == "PASS"):
        line += " — " + NOT_PR_READY  # C4
    return line, verdict, n, m


def cmd_run(mode, opts, resume=False):
    t_start = time.time()
    os.makedirs(HOME, exist_ok=True)
    lockf = open(os.path.join(HOME, "lock"), "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        raise UsageError("another scripts/ci is running against %s" % HOME)
    old = read_json(os.path.join(HOME, "state.json")) or {}
    for sid, pid in (old.get("running") or {}).items():
        try:
            os.killpg(pid, 0)
            raise UsageError("step %s from an earlier invocation is still running (process group %d) — wait for it or kill it" % (sid, pid))
        except ProcessLookupError:
            pass
        except PermissionError:
            raise UsageError("step %s from an earlier invocation may still be running (pgid %d)" % (sid, pid))
    # From here this invocation OWNS _ci/last.json: whatever an earlier run concluded stops being
    # readable as this run's verdict before anything else happens. A crash anywhere below leaves
    # RUNNING (or ERROR), never an earlier PASS for a tree it did not run.
    # (--plan runs nothing and reports nothing: it leaves last.json alone.)
    last_path = os.path.join(HOME, "last.json")
    if not opts.get("plan"):
        atomic_write_json(last_path, {"mode": mode, "verdict": "RUNNING", "resume": bool(resume),
                                      "pid": os.getpid(), "started": time.strftime("%Y-%m-%dT%H:%M:%S")})
    holder = {}
    try:
        return _cmd_run_locked(mode, opts, resume, t_start, old, holder)
    except BaseException as e:
        run = holder.get("run")
        if run is not None and run.running:
            run.interrupted = True
            run.terminate_all()  # never orphan a step (start_new_session: nothing else would stop it)
        if opts.get("plan"):
            raise
        atomic_write_json(last_path, {"mode": mode, "verdict": "ERROR", "error": "%s: %s" % (type(e).__name__, e),
                                      "final_line": "CI(%s): ERROR — the driver stopped before a verdict: %s" % (mode, e)})
        if not isinstance(e, UsageError):
            out("CI(%s): ERROR — the driver crashed (%s: %s); verdict ERROR in %s/last.json" % (
                mode, type(e).__name__, e, os.path.relpath(HOME, REPO)))
        raise


def _cmd_run_locked(mode, opts, resume, t_start, old, holder):
    man = Manifest(MANIFEST)
    ctx = Context(opts["base"], need_base=(mode == "quick" or bool(opts.get("require_base"))))
    if resume:
        state = old
        if old.get("tree") and old.get("tree") != ctx.tree:
            out("CI(%s): the tree changed since the last invocation (%s → %s) — re-evaluating every cache key" % (
                mode, old.get("tree", "")[:10], ctx.tree[:10]))
        state["tree"] = ctx.tree
        state["invocations"] = state.get("invocations", 0) + 1
    else:
        state = {"version": 1, "mode": mode,
                 "options": {k: opts[k] for k in opts if k not in ("markers", "_given", "apps", "plan")},
                 "base": opts["base"], "base_sha": ctx.base_sha, "merge_base": ctx.merge_base,
                 "head": ctx.head, "tree": ctx.tree, "started": time.strftime("%Y-%m-%dT%H:%M:%S"),
                 "invocations": 1, "cumulative_s": 0.0, "steps": {}}
    run = Run(man, mode, opts, ctx, state, resume)
    holder["run"] = run
    plan, skipped = build_plan(man, mode, ctx, opts)
    run.plan = plan
    state["plan"] = [s.id for s in plan]

    def on_signal(signum, _frame):
        run.interrupted = True
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, on_signal)

    budget = float(opts.get("budget", 540))
    hdr = "CI(%s): %d step(s) planned · base %s@%s · tree %s · budget %s · -j %d%s" % (
        mode, len(plan), opts["base"], (ctx.merge_base or "missing")[:10], ctx.tree[:10],
        ("%ds" % budget) if budget > 0 else "none", int(opts.get("jobs") or 1),
        " · resume #%d" % state["invocations"] if resume else "")
    out(hdr)
    if mode == "quick":
        ch = ctx.changed()
        out("CI(quick): %d changed path(s) vs merge-base %s (tracked diff + untracked)%s" % (
            len(ch), ctx.merge_base[:10], (": " + ", ".join(ch[:8]) + (" …" if len(ch) > 8 else "")) if ch else ""))
    for s, why in skipped:
        out("SKIP %s (%s)" % (s.id, why))
        if run.markers and s.skip_marker and why.startswith("opt-in"):
            out(s.skip_marker)
    if opts.get("plan"):
        prior = state.get("steps", {}) if resume else {}
        for s in plan:
            pr = prior.get(s.id) or {}
            how = ("preset " + s.preset[0]) if s.preset else (
                "done earlier" if pr.get("status") == "PASS" and s.key and pr.get("key") == s.key else
                "CACHED" if run.cache_hit(s) else "would run")
            out("PLAN %s est %s — %s%s" % (s.id, fmt_s(s.est), how, " (serial)" if s.serial else ""))
        out("CI(%s): plan only — %d step(s), nothing run" % (mode, len(plan)))
        return 0
    t0, pending, stop_reason = run.execute(t_start)
    elapsed = time.time() - t0
    state["cumulative_s"] = round(state.get("cumulative_s", 0.0) + elapsed, 1)
    first_fail = next((s.id for s in plan if run.status.get(s.id) in ("FAIL", "FLAKY")), None)
    line, verdict, n, m = final_line(mode, opts, plan, run.status, elapsed, first_fail)
    if line.endswith(" — PR-READY"):
        # PR-READY is a claim RELATIVE TO A BASE: without it the double sweep did not run and the
        # --changed replays fell back to the harnesses' own default (HEAD~1) — green, not ready
        if not ctx.base_sha:
            line = line[:-len(" — PR-READY")] + (" — NOT PR-READY: base %s is missing in this clone (no double sweep; "
                                                 "--changed replays had no base) — git fetch origin main" % opts["base"])
        elif opts["base"] != "origin/main":
            line += " (vs %s)" % opts["base"]
    unrun = [s.id for s in plan if run.status.get(s.id) not in DONE + ("FAIL", "FLAKY")]
    if verdict == "INCOMPLETE":
        if run.interrupted:
            out("CI(%s): interrupted — %d step(s) not done" % (mode, len(unrun)))
        elif stop_reason:
            out("CI(%s): budget — %s" % (mode, stop_reason))
    elif verdict == "FAIL" and unrun:
        out("CI(%s): stopped at the first failure — %d planned step(s) not run (--keep-going runs them)" % (mode, len(unrun)))
    state["verdict"] = verdict
    run.save_state()
    last = {"mode": mode, "verdict": verdict, "final_line": line, "passed": n, "planned": m,
            "base": opts["base"], "base_sha": ctx.base_sha, "merge_base": ctx.merge_base, "head": ctx.head,
            "tree": ctx.tree, "budget_s": budget, "jobs": opts.get("jobs"), "only": opts.get("only"),
            "also": opts.get("also"), "no_cache": bool(opts.get("no_cache")), "elapsed_s": round(elapsed, 1),
            "cumulative_s": state["cumulative_s"], "invocations": state["invocations"],
            "interrupted": run.interrupted, "stop_reason": stop_reason,
            "steps": [dict(run.results.get(s.id) or {"id": s.id, "status": "NOT_RUN"}, est_s=s.est) for s in plan],
            "not_run": unrun,
            "skipped": [{"id": s.id, "reason": why} for s, why in skipped]}
    atomic_write_json(os.path.join(HOME, "last.json"), last)
    out(line)
    if run.interrupted:
        return 130
    return {"PASS": 0, "FAIL": 1, "INCOMPLETE": 3}[verdict]


# ── read-only subcommands ───────────────────────────────────────────────────────────────────────
def mode_steps(man, mode, also=()):
    """The steps `mode` runs (plus --also), superseded ones dropped — the ONE definition behind
    `scripts/ci list`, `scripts/ci pr` and the Actions plan, so they cannot disagree."""
    also = set(also or [])
    steps = [s for s in man.steps if mode is None or mode in s.modes or s.id in also or s.group in also]
    if mode:
        ids = {s.id for s in steps}
        steps = [s for s in steps if not any(x in ids for x in s.superseded_by)]
    return steps


def cmd_list(mode, opts):
    man = Manifest(MANIFEST)
    steps = mode_steps(man, mode, opts.get("also"))
    if opts.get("json"):
        out(json.dumps([{"id": s.id, "group": s.group, "modes": sorted(s.modes), "est_s": s.est, "serial": s.serial,
                         "actions_job": s.actions_job, "actions_skip": s.actions_skip} for s in steps], indent=1))
        return 0
    if opts.get("apps"):
        seen = []
        for s in steps:
            if s.cwd != "." and s.cwd not in seen:
                seen.append(s.cwd)
        for c in seen:
            out(c)
        return 0
    if opts.get("markers"):
        last_in_group = {}
        for s in steps:
            if s.group:
                last_in_group[s.group] = s.id
        for s in man.steps:
            if s in steps:
                for m in s.markers:
                    out(m)
                if s.group and last_in_group.get(s.group) == s.id:
                    for m in man.groups.get(s.group, {}).get("markers", []):
                        out(m)
            elif s.skip_marker and mode == "pr":
                out(s.skip_marker)
        return 0
    out("%-28s %-20s %7s %-6s %-12s %s" % ("STEP", "MODES", "EST_S", "SERIAL", "GROUP", "LOCKS"))
    for s in steps:
        out("%-28s %-20s %7.0f %-6s %-12s %s" % (s.id, " ".join(m for m in MODES if m in s.modes), s.est,
                                                  "yes" if s.serial else "", s.group, " ".join(sorted(s.locks))))
    out("%d step(s)%s; est %.0fs if run one at a time" % (len(steps), " in " + mode if mode else "", sum(s.est for s in steps)))
    return 0


def cmd_explain(sid, opts):
    man = Manifest(MANIFEST)
    s = man.by_id(sid)
    if not s:
        raise UsageError("no step %r (scripts/ci list)" % sid)
    ctx = Context(opts["base"], need_base=False)
    out("step %s  (group %s; modes %s)" % (s.id, s.group or "-", " ".join(m for m in MODES if m in s.modes)))
    out("  cwd     %s" % s.cwd)
    out("  cmd     " + s.cmd.replace("\n", "\n          "))
    if s.unsharded_cmd:
        out("  unsharded_cmd (--budget 0)  " + s.unsharded_cmd.replace("\n", "\n          "))
    out("  serial  %s   locks %s   est %s" % ("yes" if s.serial else "no", " ".join(sorted(s.locks)) or "-", fmt_s(s.est)))
    for label, toks in (("inputs", s.inputs), ("reads", s.reads)):
        rules = expand_tokens(toks, man.apps)
        dig, n = ctx.snap.digest(rules) if rules else ("-", 0)
        out("  %-7s %s" % (label, " ".join(toks) or "(none)"))
        if rules:
            out("          → %s  [%d file(s) now]" % (" ".join(rules), n))
    k = ctx.key(s, man.apps)
    if not k:
        out("  cache   NEVER (no declared inputs)")
    else:
        hit = read_json(os.path.join(HOME, "cache", k[:2], k + ".json"))
        out("  key     %s  %s" % (k[:16], ("CACHED PASS from %s" % hit["at"]) if hit else "(no cached PASS)"))
    if ctx.merge_base:
        hits = affected(s, man.apps, ctx.changed())
        out("  quick   %s vs %s%s" % ("SELECTED" if (hits or s.always) else "not affected", ctx.merge_base[:10],
                                      (": " + ", ".join(hits[:6]) + (" …" if len(hits) > 6 else "")) if hits else
                                      (" (always)" if s.always else "")))
    st = (read_json(os.path.join(HOME, "state.json")) or {}).get("steps", {})
    recs = [v for k2, v in st.items() if k2 == s.id or k2.startswith(s.id + "[")]
    for r in recs:
        out("  last    %s %s %s %s" % (r["id"], r["status"], fmt_s(r.get("duration_s", 0)), r.get("log") or ""))
    return 0


def cmd_status():
    st = read_json(os.path.join(HOME, "state.json"))
    if not st:
        out("CI: no run recorded in %s" % HOME)
        return 0
    cur = None
    try:
        cur = Snapshot().tree
    except UsageError:
        pass
    plan = st.get("plan", [])
    steps = st.get("steps", {})
    n = sum(1 for i in plan if steps.get(i, {}).get("status") in DONE)
    out("CI(%s): %s — %d/%d done · %d invocation(s) · %ss cumulative · base %s · started %s" % (
        st.get("mode"), st.get("verdict", "RUNNING?"), n, len(plan), st.get("invocations"),
        st.get("cumulative_s"), st.get("base"), st.get("started")))
    if cur and cur != st.get("tree"):
        out("  the tree has changed since the last invocation — resume re-evaluates every cache key")
    for i in plan:
        r = steps.get(i)
        out("  %-11s %s%s" % (r["status"] if r else "NOT_RUN", i, (" " + fmt_s(r.get("duration_s", 0))) if r else ""))
    if st.get("verdict") in ("INCOMPLETE", None, "FAIL"):
        out("next: scripts/ci resume")
    return 0



# ── GitHub Actions (ADR-053 §2.8): the manifest decides what runs where ─────────────────────────
JOB_NAME = re.compile(r"^[a-z][a-z0-9_]*$")
SHARD_SUFFIX = re.compile(r"\[(\d+)/(\d+)\]$")
MIN_REASON = 12  # an exclusion's reason is a sentence, not a word


def step_dirs(man, s):
    """The mix projects whose deps/_build the job caches: declared (actions_dirs) or cwd + app: inputs."""
    if s.actions_dirs is not None:
        return s.actions_dirs
    dirs = []
    if s.cwd != ".":
        dirs.append(s.cwd)
    for tok in s.inputs:
        if tok.startswith("app:"):
            d = man.apps[tok[4:]]["path"].rstrip("/")
            if d not in dirs:
                dirs.append(d)
    return dirs


def job_entry(man, name, steps, slice_):
    dirs = []
    for x in steps:
        for d in step_dirs(man, x):
            if d not in dirs:
                dirs.append(d)
    paths = []
    for d in dirs:
        paths += [d + "/deps", d + "/_build"]
        if any(x.id.startswith("dialyzer_") for x in steps):
            paths.append(d + "/priv/plts")
    return {"name": name, "steps": [x.id for x in steps], "only": ",".join(x.id for x in steps),
            "slice": "%d/%d" % slice_ if slice_ else "", "est_s": round(sum(x.est for x in steps)),
            "cache_paths": "\n".join(paths)}


def actions_plan(man, mode):
    """-> dict(mode, steps, jobs=[{name, steps, only, est_s}], excluded=[{id, reason}]).
    A1: every step of the mode lands in EXACTLY ONE job or is excluded WITH a reason; anything else is
    an error naming the step — a new manifest step can never silently go unrun in Actions."""
    steps = mode_steps(man, mode)
    jobs, excluded, errors = {}, [], []
    for s in steps:
        has_job = s.actions_job is not None
        if s.actions_skip is not None:
            if has_job:
                errors.append("%s is assigned to a job (%s) AND excluded (actions_skip) — pick one" % (s.id, s.actions_job))
            elif len(s.actions_skip) < MIN_REASON:
                errors.append("%s is excluded from Actions without a reason (actions_skip = %r): say WHY it cannot run there"
                              % (s.id, s.actions_skip))
            else:
                excluded.append({"id": s.id, "reason": s.actions_skip})
            continue
        job = s.actions_job if has_job else s.group
        if not job:
            errors.append("%s is assigned to no Actions job (no group, no actions_job, no actions_skip)" % s.id)
        elif not JOB_NAME.match(job):
            errors.append("%s: Actions job name %r must match %s" % (s.id, job, JOB_NAME.pattern))
        else:
            jobs.setdefault(job, []).append(s)
    if errors:
        raise UsageError("actions plan (%s) is not a partition of `scripts/ci list %s`:\n  - %s" % (mode, mode, "\n  - ".join(errors)))
    out_jobs = []
    for n, v in jobs.items():
        plain = [x for x in v if not x.actions_slices]
        if plain:
            out_jobs.append(job_entry(man, n, plain, None))
        for x in v:
            if x.actions_slices:  # one job per slice: name_NN, `--slice i/N`
                for i in range(1, x.actions_slices + 1):
                    out_jobs.append(job_entry(man, "%s_%02d" % (x.id, i), [x], (i, x.actions_slices)))
    names = [j["name"] for j in out_jobs]
    if len(set(names)) != len(names):
        raise UsageError("actions plan (%s): duplicate job name(s): %s" % (mode, ", ".join(sorted({x for x in names if names.count(x) > 1}))))
    return {"mode": mode, "steps": [s.id for s in steps], "jobs": out_jobs, "excluded": excluded}


def cmd_actions(pos, opts):
    if not pos:
        raise UsageError("actions needs a subcommand: plan|verify|summary")
    sub, rest = pos[0], pos[1:]
    if sub == "summary":
        return actions_summary(opts.get("last") or os.path.join(HOME, "last.json"))
    if len(rest) != 1 or rest[0] not in MODES:
        raise UsageError("actions %s takes one mode (%s)" % (sub, "|".join(MODES)))
    man = Manifest(MANIFEST)
    plan = actions_plan(man, rest[0])
    if sub == "plan":
        if opts.get("json"):
            out(json.dumps(plan, indent=1))
            return 0
        out("Actions plan (%s): %d step(s) -> %d job(s), %d excluded" % (rest[0], len(plan["steps"]), len(plan["jobs"]), len(plan["excluded"])))
        for j in plan["jobs"]:
            out("  job %-14s est %5ds  %s" % (j["name"], j["est_s"], j["only"]))
        for e in plan["excluded"]:
            out("  EXCLUDED %-22s %s" % (e["id"], e["reason"]))
        return 0
    if sub == "verify":
        if not opts.get("results"):
            raise UsageError("actions verify needs --results DIR (one sub-directory per job holding its last.json)")
        totals = {}
        for kv in opts.get("expect_total") or []:
            k, _, v = kv.partition("=")
            if not v.isdigit():
                raise UsageError("--expect-total wants step=N, got %r" % kv)
            totals[k] = int(v)
        return actions_verify(plan, opts["results"], opts.get("expect_base"), totals)
    raise UsageError("unknown actions subcommand %r" % sub)


def actions_verify(plan, results_dir, expect_base, expect_totals=None):
    """The Actions twin of C1/C7: the union of what the jobs ACTUALLY ran must equal `list MODE` minus the
    declared exclusions — each step exactly once, every one PASS/CACHED, every job on the expected base;
    for sliced steps (nightly) the slices must be 1..N, each once, and their PROCESSED counts must sum to
    the lister's total (a slice that processed 0, or dropped a patch, fails). Prints markdown (for
    $GITHUB_STEP_SUMMARY); exit 1 on any discrepancy."""
    errors, lines = [], []
    spec = {j["name"]: j for j in plan["jobs"]}
    want = {}
    for n, j in spec.items():
        if j.get("slice"):
            want[n] = {"%s[%s]" % (j["steps"][0], j["slice"])}
        else:
            want[n] = set(j["steps"])
    found = {}
    if os.path.isdir(results_dir):
        for d in sorted(os.listdir(results_dir)):
            lp = os.path.join(results_dir, d, "last.json")
            if os.path.isfile(lp):
                found[re.sub(r"^ci-result-", "", d)] = read_json(lp)
    ran_by = {}
    for n in sorted(set(found) - set(spec)):
        errors.append("a result for job %r which the plan does not have" % n)
        for st in (found[n] or {}).get("steps") or []:  # still counted: a step run in two places ran twice
            ran_by.setdefault(SHARD_SUFFIX.sub("", st["id"]), []).append(n)
    slices = {}  # parent -> [(i, n, job, processed, expected, selected_total)]
    lines.append("| job | verdict | steps | wall |")
    lines.append("|---|---|---|---|")
    for n in spec:
        last = found.get(n)
        if not last:
            errors.append("job %s produced no result (last.json missing): its %d step(s) were never verified" % (n, len(want[n])))
            lines.append("| %s | MISSING | 0/%d | - |" % (n, len(want[n])))
            continue
        errs0 = len(errors)
        if last.get("verdict") != "PASS":
            errors.append("job %s verdict is %s, not PASS" % (n, last.get("verdict")))
        if last.get("mode") != plan["mode"]:
            errors.append("job %s ran mode %s, expected %s" % (n, last.get("mode"), plan["mode"]))
        if expect_base and last.get("base_sha") != expect_base:
            errors.append("job %s ran against base %s, expected %s (the PR's base)" % (n, (last.get("base_sha") or "none")[:10], expect_base[:10]))
        subs = {}
        for st in last.get("steps") or []:
            m = SHARD_SUFFIX.search(st["id"])
            subs.setdefault(SHARD_SUFFIX.sub("", st["id"]), []).append((m, st))
            if st.get("status") not in DONE:
                errors.append("job %s: step %s is %s" % (n, st["id"], st.get("status")))
        ran_ids = set()
        for parent, items in subs.items():
            if n not in ran_by.setdefault(parent, []):
                ran_by[parent].append(n)
            ms = [(int(m.group(1)), int(m.group(2))) for m, _ in items if m]
            if spec[n].get("slice"):
                for m, st in items:
                    ran_ids.add(st["id"])
                    if m:
                        slices.setdefault(parent, []).append((int(m.group(1)), int(m.group(2)), n, st.get("processed"),
                                                              st.get("expected"), st.get("selected_total")))
            else:
                ran_ids.add(parent)
                if ms and (len(ms) != len(items) or sorted(i for i, _t in ms) != list(range(1, ms[0][1] + 1)) or {t for _i, t in ms} != {ms[0][1]}):
                    errors.append("job %s: shards of %s are not 1..N complete: %s" % (n, parent, sorted(ms)))
        for sid in sorted(want[n] - ran_ids):
            errors.append("step %s is planned in job %s but job %s did not run it" % (sid, n, n))
        for sid in sorted(ran_ids - want[n]):
            errors.append("job %s ran %s which the plan does not assign to it" % (n, sid))
        lines.append("| %s | %s | %d/%d | %ss |" % (n, "PASS" if len(errors) == errs0 else "FAIL", len(ran_ids & want[n]), len(want[n]), last.get("elapsed_s")))
    sliced_steps = {j["steps"][0] for j in spec.values() if j.get("slice")}
    slice_lines = []
    for parent in sorted(sliced_steps):
        rows = slices.get(parent, [])
        ns = {r[1] for r in rows}
        idx = sorted(r[0] for r in rows)
        want_n = {int(j["slice"].split("/")[1]) for j in spec.values() if j.get("slice") and j["steps"][0] == parent}
        if ns != want_n or idx != list(range(1, next(iter(want_n)) + 1)):
            errors.append("slices of %s are not exactly 1..%s, once each: got %s" % (parent, "/".join(map(str, sorted(want_n))), idx))
            continue
        totals = {r[5] for r in rows}
        if len(totals) != 1 or None in totals:
            errors.append("slices of %s disagree on the selected total: %s" % (parent, sorted(str(t) for t in totals)))
            continue
        total = totals.pop()
        proc = sum(r[3] or 0 for r in rows)
        exp = sum(r[4] or 0 for r in rows)
        slice_lines.append("- `%s`: %d slices processed %d of %d selected (slice counts: %s)" % (
            parent, len(rows), proc, total, " ".join("%d" % (r[3] or 0) for r in sorted(rows))))
        if proc != total or exp != total:
            errors.append("%s: the slices processed %d and were assigned %d, but %d were selected — a slice dropped or "
                          "double-counted work" % (parent, proc, exp, total))
        want_total = (expect_totals or {}).get(parent)
        if want_total is not None and want_total != total:
            errors.append("%s: the lister selected %d but the independent count is %d" % (parent, total, want_total))
        if total == 0:
            errors.append("%s: 0 items selected — an empty corpus is not a pass" % parent)
    for sid, who in sorted(ran_by.items()):
        if len(who) > 1 and sid not in sliced_steps:
            errors.append("step %s ran in %d jobs (%s) — each step runs exactly once" % (sid, len(who), ", ".join(who)))
    owner = {sid for j in spec.values() for sid in j["steps"]}
    for sid in plan["steps"]:  # unreachable while actions_plan holds; re-asserted against `list`
        if sid not in owner and sid not in {e["id"] for e in plan["excluded"]}:
            errors.append("step %s of `scripts/ci list %s` is in no job and not excluded" % (sid, plan["mode"]))
    total = len(plan["steps"]) - len(plan["excluded"])
    covered = sum(1 for sid in plan["steps"] if sid in owner and sid in ran_by and (len(ran_by[sid]) == 1 or sid in sliced_steps))
    out("### Actions coverage (%s)" % plan["mode"])
    out("")
    for l in lines:
        out(l)
    out("")
    out("%d step(s) in `scripts/ci list %s` (%d runnable + %d deliberately excluded): %d verified." % (
        len(plan["steps"]), plan["mode"], total, len(plan["excluded"]), covered))
    if slice_lines:
        out("")
        out("**Sharded accounting (sum over slices must equal the selected total):**")
        for l in slice_lines:
            out(l)
    if plan["excluded"]:
        out("")
        out("**Excluded from Actions (declared in `ci/steps.conf`, never silent):**")
        for e in plan["excluded"]:
            out("- `%s` — %s" % (e["id"], e["reason"]))
    if covered != total and not errors:
        errors.append("coverage arithmetic: %d verified != %d runnable steps" % (covered, total))
    if errors:
        out("")
        out("**COVERAGE FAILED:**")
        for e in errors:
            out("- " + e)
        out("")
        out("ACTIONS COVERAGE (%s): FAIL — %d problem(s)" % (plan["mode"], len(errors)))
        return 1
    out("")
    out("ACTIONS COVERAGE (%s): PASS — %d/%d steps verified, %d excluded" % (plan["mode"], covered, total, len(plan["excluded"])))
    return 0


def actions_summary(last_path):
    last = read_json(last_path)
    if not last:
        out("### CI: no verdict (`%s` missing)" % last_path)
        return 0
    out("### %s" % (last.get("final_line") or "CI(%s): %s" % (last.get("mode"), last.get("verdict"))))
    out("")
    out("verdict **%s** · mode %s · only `%s` · base `%s` @ `%s` · %ss" % (
        last.get("verdict"), last.get("mode"), ",".join(last.get("only") or []) or "-", last.get("base"),
        (last.get("base_sha") or "missing")[:10], last.get("elapsed_s")))
    out("")
    out("| step | status | wall |")
    out("|---|---|---|")
    for st in last.get("steps") or []:
        out("| %s | %s | %s |" % (st.get("id"), st.get("status"), fmt_s(st.get("duration_s") or 0)))
    bad = [st for st in last.get("steps") or [] if st.get("status") in ("FAIL", "FLAKY", "INTERRUPTED")]
    if last.get("error"):
        bad_txt = last["error"]
        out("")
        out("**driver error:** " + bad_txt)
    for st in bad:
        out("")
        out("#### %s %s" % (st["status"], st["id"]))
        out("```")
        for l in (st.get("digest") or [])[:60]:
            out(l)
        out("log: %s" % st.get("log"))
        out("```")
    if last.get("not_run"):
        out("")
        out("not run: " + ", ".join(last["not_run"]))
    return 0


# ── argv ────────────────────────────────────────────────────────────────────────────────────────
def parse(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        return "help", None, {}
    cmd, rest = argv[0], argv[1:]
    opts = {"budget": 540.0, "jobs": max(1, (os.cpu_count() or 2) // 2), "only": [], "also": [],
            "no_cache": False, "base": "origin/main", "keep_going": False, "markers": False, "apps": False,
            "plan": False, "exact": False, "require_base": False, "json": False, "results": None, "expect_base": None,
            "last": None, "slice": None, "expect_total": None,
            "_given": set()}
    pos = []
    seen = set()
    i = 0
    while i < len(rest):
        a = rest[i]

        def val():
            if i + 1 >= len(rest):
                raise UsageError("%s needs a value" % a)
            return rest[i + 1]
        if a.startswith("-"):
            opts["_given"].add(a)
        if a in ("--budget", "-j", "--jobs", "--base", "--only", "--only-steps"):
            if a in seen and a != "--only":
                raise UsageError("%s given twice" % a)
            seen.add(a)
            v = val()
            if a == "--budget":
                try:
                    opts["budget"] = float(v)
                except ValueError:
                    raise UsageError("--budget wants seconds, got %r" % v)
            elif a in ("-j", "--jobs"):
                if not v.isdigit() or int(v) < 1:
                    raise UsageError("-j wants a positive integer, got %r" % v)
                opts["jobs"] = int(v)
            elif a == "--base":
                opts["base"] = v
            else:
                opts["only"] += [x for x in v.split(",") if x]
                if a == "--only-steps":
                    opts["exact"] = True
            i += 2
        elif a == "--also":
            opts["also"] += [x for x in val().split(",") if x]
            i += 2
        elif a == "--no-cache":
            opts["no_cache"] = True
            i += 1
        elif a == "--keep-going":
            opts["keep_going"] = True
            i += 1
        elif a == "--markers":
            opts["markers"] = True
            i += 1
        elif a == "--plan":
            opts["plan"] = True
            i += 1
        elif a == "--require-base":
            opts["require_base"] = True
            i += 1
        elif a == "--json":
            opts["json"] = True
            i += 1
        elif a == "--slice":
            v = val()
            m = re.match(r"^(\d+)/(\d+)$", v)
            if not m or not (1 <= int(m.group(1)) <= int(m.group(2))) or int(m.group(2)) < 2:
                raise UsageError("--slice wants i/n with 1 <= i <= n, n >= 2, got %r" % v)
            opts["slice"] = (int(m.group(1)), int(m.group(2)))
            i += 2
        elif a == "--expect-total":
            opts["expect_total"] = (opts.get("expect_total") or []) + [val()]
            i += 2
        elif a in ("--results", "--expect-base", "--last"):
            opts[a[2:].replace("-", "_")] = val()
            i += 2
        elif a == "--apps":
            opts["apps"] = True
            i += 1
        elif a.startswith("-"):
            raise UsageError("unknown flag %s" % a)
        else:
            pos.append(a)
            i += 1
    return cmd, pos, opts


def main(argv):
    try:
        cmd, pos, opts = parse(argv)
        if cmd == "help":
            sys.stdout.write(USAGE)
            return 0
        if cmd in MODES:
            if pos:
                raise UsageError("unexpected argument %r" % pos[0])
            return cmd_run(cmd, opts)
        if cmd == "resume":
            st = read_json(os.path.join(HOME, "state.json"))
            if not st or "mode" not in st:
                raise UsageError("nothing to resume — no run recorded in %s" % HOME)
            if pos:
                raise UsageError("resume takes no positional argument")
            bad = opts["_given"] - {"--budget", "-j", "--jobs", "--markers"}
            if bad:
                raise UsageError("resume keeps the run's own options; only --budget/-j/--markers may change (got %s)" % " ".join(sorted(bad)))
            saved = dict(st.get("options") or {})
            if "--budget" in opts["_given"]:
                saved["budget"] = opts["budget"]
            if opts["_given"] & {"-j", "--jobs"}:
                saved["jobs"] = opts["jobs"]
            saved["markers"] = opts["markers"]
            return cmd_run(st["mode"], saved, resume=True)
        if cmd == "status":
            return cmd_status()
        if cmd == "actions":
            return cmd_actions(pos, opts)
        if cmd == "list":
            mode = pos[0] if pos else None
            if mode and mode not in MODES:
                raise UsageError("unknown mode %r" % mode)
            return cmd_list(mode, opts)
        if cmd == "explain":
            if len(pos) != 1:
                raise UsageError("explain takes one step id")
            return cmd_explain(pos[0], opts)
        raise UsageError("unknown command %r" % cmd)
    except UsageError as e:
        sys.stderr.write("scripts/ci: %s\n" % e)
        if str(e).startswith("unknown"):
            sys.stderr.write(USAGE)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

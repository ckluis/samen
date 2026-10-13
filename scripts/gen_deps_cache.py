#!/usr/bin/env python3
"""scripts/gen_deps_cache.py — a content-keyed cache of the COMPILED HEX DEPENDENCIES of a generated app (ADR-053 P6).

Each gen probe generates a fresh app and compiles ~62 hex dependencies into its own `_build` — about two thirds of its
wall-clock. The dependencies are third-party code pinned by the generated `mix.lock`; only `samen_core`/`samen_web`
(path deps — what the probe TESTS) and the generated app itself are the code under test. This helper seeds a fresh
app's `_build/<env>/lib/<hex dep>` from an earlier identical build and stores a new one after a green compile.

    gen_deps_cache.py seed  <app_dir> [--env test]   after `mix deps.get`, before `mix compile`
    gen_deps_cache.py store <app_dir> [--env test]   after a SUCCESSFUL `mix compile`
    gen_deps_cache.py clear                          remove the whole cache
    gen_deps_cache.py key   <app_dir> [--env test]   print the key (debug)

The cache directory is $SAMEN_GEN_DEPS_CACHE (the value `off` disables it; unset = disabled for a direct call —
scripts/gen_probe_guard.sh sets the default ${XDG_CACHE_HOME:-~/.cache}/samen/gen_deps for the gen probes, and `clear` uses it). Everything is best-effort ACCELERATION: any problem here
degrades to "compile from scratch", never to a wrong build; exit status is 0 unless the arguments are malformed.

WHAT MAKES REUSE SOUND
  key        sha256 of: the generated mix.lock bytes (every hex package, version and checksum) · the mix_exs*.eex
             templates (how deps are declared) · Elixir, OTP and architecture · MIX_ENV · the build-relevant environment
             (MIX_*, ELIXIR_*, ERL_*, REBAR*, CC/CXX/*FLAGS …) and every variable a hex dependency's mix.exs /
             rebar.config(.script) names literally · the compile-time config (config.exs + imports, not runtime.exs)
             of every configured app but the app itself and samen_* (`config :ash, …` — what `Application.compile_env`
             reads; `config :logger, compile_time_purge_matching: …` — what Logger's macros read). A change to any of
             them is a different key; nothing is reused across keys.
  scope      only the hex packages named in mix.lock. `samen_*` is never stored or seeded and the app itself is never in
             the lock, so `samen_core`/`samen_web`/the app ALWAYS compile fresh from source.
  entries    immutable, one directory per key, built beside the cache in a temp dir and published by ONE rename, with a
             MANIFEST (sha-256 of every file and symlink target) and a COMPLETE marker holding the MANIFEST's digest. An
             entry is used only after the whole tree re-hashes to its MANIFEST; a mismatch deletes the entry and
             rebuilds. A failed or partial compile is never stored (`store` runs after a green `mix compile`).
  races      the first probe to miss takes `<key>.lock`; the others wait (bounded) for the entry, then compile their own.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SCHEMA = "v1"
LOCK_WAIT_S = float(os.environ.get("SAMEN_GEN_DEPS_CACHE_WAIT", "420"))
KEEP = int(os.environ.get("SAMEN_GEN_DEPS_CACHE_KEEP", "4"))
HEX_LINE = re.compile(r'^\s*"([^"]+)":\s*\{:hex,', re.M)
ENV_RELEVANT = re.compile(r"^(MIX_|ELIXIR_|ERL_|REBAR|CC$|CXX$|CPP$|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS|MAKEFLAGS|KERL_)")
ENV_IGNORED = {"MIX_QUIET", "MIX_HOME", "MIX_ARCHIVES", "MIX_DEBUG", "MIX_OS_DEPS_COMPILE_PARTITION_COUNT"}
NEVER_CACHED = re.compile(r"^samen_")  # the code under test: compiled fresh from source, always


def say(msg):
    print("gen_deps_cache: " + msg, flush=True)


def cache_dir():
    d = os.environ.get("SAMEN_GEN_DEPS_CACHE", "").strip()
    if not d or d == "off":
        return None
    return os.path.join(os.path.abspath(os.path.expanduser(d)), SCHEMA)


def sha_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def hex_deps(app_dir):
    lock = os.path.join(app_dir, "mix.lock")
    if not os.path.isfile(lock):
        return None, None
    with open(lock, "rb") as f:
        raw = f.read()
    names = sorted(n for n in HEX_LINE.findall(raw.decode("utf-8", "replace")) if not NEVER_CACHED.match(n))
    return raw, names


def toolchain():
    probe = ('IO.puts(System.version()); IO.puts(:erlang.system_info(:otp_release)); '
             'IO.puts(File.read!(Path.join([:code.root_dir(), "releases", to_string(:erlang.system_info(:otp_release)), "OTP_VERSION"]))); '
             'IO.puts(:erlang.system_info(:system_architecture))')
    p = subprocess.run(["elixir", "-e", probe], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=120)
    if p.returncode != 0 or not p.stdout.strip():
        return None
    return p.stdout.decode().strip().replace("\n", "|")


def dep_config(app_dir, names, env):
    """The COMPILE-TIME config the hex dependencies are built under, as the generated app's config files set it — read by
    Elixir itself with Config.Reader (config.exs + its imports, evaluated; NOT runtime.exs, which no compile sees: Gate P6
    found the key reading the runtime-merged Application env, so a config.exs value that runtime.exs overrides was not
    keyed). Every configured application except the app itself and samen_* is included, not only the hex packages: a
    dependency's macros also read other apps' config at compile time (`config :logger, compile_time_purge_matching:`
    removes Logger calls from every dependency's .beam — Gate P6 reproduced a seeded plug that a cold build had purged)."""
    code = ("IO.puts(\"compile-time config\"); p = Mix.Project.config(); own = p[:app]; "
            "cfg = Config.Reader.read!(p[:config_path], env: Mix.env(), target: Mix.target()); "
            "for {a, kv} <- Enum.sort(cfg), a != own, not String.starts_with?(Atom.to_string(a), \"samen_\"), "
            "do: IO.puts(inspect({a, Enum.sort(kv)}, limit: :infinity, printable_limit: :infinity))")
    e = dict(os.environ, MIX_ENV=env, MIX_QUIET="1")
    p = subprocess.run(["mix", "run", "--no-start", "--no-compile", "--no-deps-check", "-e", code], cwd=app_dir, env=e,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=300)
    return p.stdout if p.returncode == 0 and p.stdout.strip() else None


BUILD_FILES = ("mix.exs", "rebar.config", "rebar.config.script")
BUILD_ENV_READ = re.compile(r"""(?:get_env|fetch_env!?|getenv)\(\s*["']([A-Za-z_][A-Za-z0-9_]*)["']""")
BUILD_ENV_PROVENANCE = re.compile(r"^(GITHUB_|COVERALLS_)")  # CI run metadata for coverage plugins, never compile input


def build_env(app_dir, names):
    """Every environment variable a hex dependency's OWN build file names literally (`System.get_env("LOCALIZE_NIF")` in
    localize's mix.exs switches its compilers), with its value — the ENV_RELEVANT prefixes cannot know these (Gate P6).
    Only build files, not lib/: those are read at runtime too, and a per-run variable there would make every key unique."""
    seen = set()
    for n in names:
        for fn in BUILD_FILES:
            try:
                with open(os.path.join(app_dir, "deps", n, fn), encoding="utf-8", errors="replace") as f:
                    seen.update(v for v in BUILD_ENV_READ.findall(f.read()) if not BUILD_ENV_PROVENANCE.match(v))
            except OSError:
                pass
    return "\n".join("%s=%r" % (v, os.environ.get(v)) for v in sorted(seen))


def compute_key(app_dir, env):
    """-> (key, hex dep names) or (None, reason)."""
    raw, names = hex_deps(app_dir)
    if raw is None:
        return None, "no mix.lock"
    if not names:
        return None, "no hex dependencies"
    tc = toolchain()
    if tc is None:
        return None, "cannot identify the Elixir/OTP toolchain"
    cfg = dep_config(app_dir, names, env)
    if cfg is None:
        return None, "cannot evaluate the dependencies' application env"
    h = hashlib.sha256()

    def part(tag, data):
        h.update(("\0%s\0%d\0" % (tag, len(data))).encode())
        h.update(data)

    part("schema", SCHEMA.encode())
    part("lock", raw)
    tdir = os.path.join(REPO, "samen_core", "priv", "templates")
    for fn in sorted(os.listdir(tdir)):
        if fn.startswith("mix_exs"):
            with open(os.path.join(tdir, fn), "rb") as f:
                part("template:" + fn, f.read())
    part("toolchain", tc.encode())
    part("buildenv", build_env(app_dir, names).encode())
    part("mix_env", env.encode())
    envs = "\n".join("%s=%s" % (k, v) for k, v in sorted(os.environ.items()) if ENV_RELEVANT.match(k) and k not in ENV_IGNORED)
    part("env", envs.encode())
    part("depconfig", cfg)
    return h.hexdigest(), names


def walk(root):
    """[(relative path, kind, digest-or-target)] for every file/symlink under root, sorted."""
    out = []
    for base, dirs, files in os.walk(root, followlinks=False):
        dirs.sort()
        for n in sorted(files + [d for d in dirs if os.path.islink(os.path.join(base, d))]):
            p = os.path.join(base, n)
            rel = os.path.relpath(p, root)
            if os.path.islink(p):
                out.append((rel, "l", os.readlink(p)))
            elif os.path.isfile(p):
                out.append((rel, "f", sha_file(p)))
    return sorted(out)


def manifest_text(tree):
    return "".join("%s\t%s\t%s\n" % (k, d, rel) for rel, k, d in tree)


def verify(entry, names):
    """-> (ok, why). Re-hash the whole tree against its MANIFEST; the COMPLETE marker binds the MANIFEST's digest."""
    try:
        with open(os.path.join(entry, "COMPLETE")) as f:
            done = json.load(f)
        with open(os.path.join(entry, "MANIFEST"), "rb") as f:
            mtext = f.read()
        if done.get("manifest_sha256") != hashlib.sha256(mtext).hexdigest():
            return False, "COMPLETE does not match MANIFEST"
        libs = sorted(done.get("deps") or [])
        if not libs or any(NEVER_CACHED.match(n) or n not in names for n in libs):
            return False, "entry names a dependency the lock does not (or a samen_* app)"
        lib = os.path.join(entry, "lib")
        if sorted(os.listdir(lib)) != libs:
            return False, "lib/ holds a different set of dependencies than COMPLETE"
        if manifest_text(walk(lib)).encode() != mtext:
            return False, "files differ from the MANIFEST"
        return True, ""
    except (OSError, ValueError) as e:
        return False, "unreadable (%s)" % e


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


HELD = []  # lock dirs this process holds (released if the helper dies half-way)


def take_lock(lockdir):
    try:
        os.mkdir(lockdir)
    except FileExistsError:
        return False
    except OSError:
        return False
    HELD.append(lockdir)
    try:
        with open(os.path.join(lockdir, "owner"), "w") as f:
            f.write("%d\n" % os.getppid())  # the probe's mix, which outlives this helper
    except OSError:
        pass
    return True


def lock_stale(lockdir):
    try:
        with open(os.path.join(lockdir, "owner")) as f:
            return not pid_alive(int(f.read().strip()))
    except (OSError, ValueError):
        try:  # no readable owner: stale once it is old enough that its creator cannot still be starting
            return time.time() - os.stat(lockdir).st_mtime > 30
        except OSError:
            return True


def release(lockdir):
    shutil.rmtree(lockdir, ignore_errors=True)


def state_file(app_dir):
    return os.path.join(app_dir, ".gen_deps_cache.json")


def cmd_seed(app_dir, env):
    root = cache_dir()
    if root is None:
        say("disabled (SAMEN_GEN_DEPS_CACHE unset/off) — compiling from scratch")
        return 0
    key, names = compute_key(app_dir, env)
    if key is None:
        say("no key (%s) — compiling from scratch" % names)
        return 0
    entry = os.path.join(root, key)
    lockdir = entry + ".lock"
    os.makedirs(root, exist_ok=True)
    deadline = time.time() + LOCK_WAIT_S
    owner = False
    waited = False
    while True:
        if os.path.isdir(entry):
            ok, why = verify(entry, names)
            if ok:
                break
            say("CORRUPT entry %s… (%s) — deleted, rebuilding" % (key[:12], why))
            shutil.rmtree(entry, ignore_errors=True)
            continue
        if take_lock(lockdir):
            owner = True
            break
        if lock_stale(lockdir):
            release(lockdir)
            continue
        if time.time() > deadline:
            say("waited %ds for another probe to publish %s… — compiling my own" % (LOCK_WAIT_S, key[:12]))
            break
        waited = True
        time.sleep(2)
    with open(state_file(app_dir), "w") as f:
        json.dump({"key": key, "lock_sha256": hashlib.sha256(open(os.path.join(app_dir, "mix.lock"), "rb").read()).hexdigest(),
                   "owner": owner, "env": env}, f)
    if os.path.isdir(entry) and verify(entry, names)[0]:
        t0 = time.time()
        with open(os.path.join(entry, "COMPLETE")) as f:
            libs = json.load(f)["deps"]
        dest = os.path.join(app_dir, "_build", env, "lib")
        os.makedirs(dest, exist_ok=True)
        seeded = []
        try:
            for n in libs:
                if os.path.exists(os.path.join(dest, n)):
                    continue
                seeded.append(n)
                shutil.copytree(os.path.join(entry, "lib", n), os.path.join(dest, n), symlinks=True)
        except BaseException:
            # all or nothing (Gate P6): a copy cut short — the entry evicted by another probe's prune mid-copy, a full
            # disk — left a dependency with its .app and some of its .beam files, which mix trusts as compiled. Remove
            # everything this seed wrote so the compile starts from scratch, then let main() report the error.
            for n in seeded:
                shutil.rmtree(os.path.join(dest, n), ignore_errors=True)
            raise
        os.utime(entry, None)
        say("HIT %s… — seeded %d compiled hex dependencies in %.1fs%s" % (key[:12], len(libs), time.time() - t0, " (after waiting)" if waited else ""))
        if owner:
            release(lockdir)
    else:
        if owner:  # the lock stays held until `store` publishes (or this probe's mix exits: then it reads as stale)
            HELD.remove(lockdir)
        say("MISS %s… — compiling %d hex dependencies from scratch%s" % (key[:12], len(names), "" if owner else " (not publishing)"))
    return 0


def cmd_store(app_dir, env):
    root = cache_dir()
    st = None
    try:
        with open(state_file(app_dir)) as f:
            st = json.load(f)
    except (OSError, ValueError):
        pass
    if root is None or not st:
        return 0
    key = st["key"]
    entry = os.path.join(root, key)
    lockdir = entry + ".lock"
    try:
        with open(os.path.join(app_dir, "mix.lock"), "rb") as f:
            if hashlib.sha256(f.read()).hexdigest() != st["lock_sha256"]:
                say("mix.lock changed since seed — not storing")
                return 0
        _raw, names = hex_deps(app_dir)
        if os.path.isdir(entry) and verify(entry, names)[0]:
            return 0
        built = os.path.join(app_dir, "_build", env, "lib")
        libs = [n for n in names if os.path.isfile(os.path.join(built, n, "ebin", n + ".app"))]
        if not libs:
            say("no compiled hex dependency found under %s — not storing" % built)
            return 0
        tmp = "%s.tmp.%d.%d" % (entry, os.getpid(), int(time.time() * 1000))
        shutil.rmtree(tmp, ignore_errors=True)
        os.makedirs(os.path.join(tmp, "lib"))
        for n in libs:
            shutil.copytree(os.path.join(built, n), os.path.join(tmp, "lib", n), symlinks=True)
        mtext = manifest_text(walk(os.path.join(tmp, "lib"))).encode()
        with open(os.path.join(tmp, "MANIFEST"), "wb") as f:
            f.write(mtext)
        with open(os.path.join(tmp, "COMPLETE"), "w") as f:
            json.dump({"key": key, "deps": libs, "manifest_sha256": hashlib.sha256(mtext).hexdigest(), "stored_at": int(time.time())}, f)
        try:
            os.rename(tmp, entry)  # the ONE publishing step: all of the entry or none of it
            say("STORED %s… (%d hex dependencies)" % (key[:12], len(libs)))
        except OSError:
            shutil.rmtree(tmp, ignore_errors=True)  # a concurrent probe published it first
        prune(root, keep=entry)
    finally:
        if st.get("owner"):
            release(lockdir)
    return 0


def prune(root, keep):
    try:
        ents = [os.path.join(root, n) for n in os.listdir(root)
                if os.path.isfile(os.path.join(root, n, "COMPLETE")) and not os.path.exists(os.path.join(root, n) + ".lock")]
        ents.sort(key=lambda p: os.stat(p).st_mtime, reverse=True)
        for p in ents[KEEP:]:
            if p != keep:
                shutil.rmtree(p, ignore_errors=True)
        for n in os.listdir(root):  # crashed publishers' temp dirs, once old
            p = os.path.join(root, n)
            if ".tmp." in n and time.time() - os.stat(p).st_mtime > 3600:
                shutil.rmtree(p, ignore_errors=True)
    except OSError:
        pass


def main(argv):
    if len(argv) < 2 or argv[1] not in ("seed", "store", "clear", "key"):
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "clear":
        d = os.environ.get("SAMEN_GEN_DEPS_CACHE", "").strip()
        if d == "off":
            print("gen_deps_cache: SAMEN_GEN_DEPS_CACHE=off — nothing to clear")
            return 0
        d = d or os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache"), "samen", "gen_deps")
        shutil.rmtree(os.path.abspath(os.path.expanduser(d)), ignore_errors=True)
        say("cleared %s" % d)
        return 0
    if len(argv) < 3:
        print("usage: gen_deps_cache.py %s <app_dir> [--env ENV]" % cmd, file=sys.stderr)
        return 2
    app_dir = os.path.abspath(argv[2])
    env = "test"
    if "--env" in argv:
        env = argv[argv.index("--env") + 1]
    try:
        if cmd == "key":
            key, names = compute_key(app_dir, env)
            print(key or "NOKEY: %s" % names)
            return 0
        return cmd_seed(app_dir, env) if cmd == "seed" else cmd_store(app_dir, env)
    except Exception as e:  # acceleration only: never fail the probe because the cache misbehaved
        if cmd == "seed":  # a seed that died must not leave a lock the others would wait on
            for d in HELD:
                release(d)
        say("ignored an error (%s: %s) — compiling from scratch" % (type(e).__name__, e))
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

"""no_local_paths — fail when a TRACKED file names a local machine path.

Scans `git ls-files` (text files only) for a home directory (/Users/<name>/, /home/<name>/), a
~/Desktop|Downloads|Documents path, a macOS temp dir (/private/tmp, /private/var) or an agent
scratchpad (/tmp/claude-…). Name a file in this repo by its GitHub URL
(https://github.com/ckluis/samen/blob/<sha>/<path>); a file that only ever existed on a laptop is
named by what it is, not where it was. Placeholders such as /Users/<name> or /Users/.../ pass.

SAMEN_LOCAL_PATHS_REPO overrides the repo root (the ci_test.sh fixture uses it).
"""
import os
import re
import subprocess
import sys

ROOT = os.environ.get("SAMEN_LOCAL_PATHS_REPO") or os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PATTERN = re.compile(
    r"/Users/[A-Za-z0-9_-]+/"
    r"|/home/[a-z][a-z0-9_-]*/"
    r"|~/(?:Desktop|Downloads|Documents)/"
    r"|/private/(?:tmp|var)/"
    r"|/tmp/claude-"
)
# This checker and its self-test must spell the patterns they look for.
SELF = {"scripts/no_local_paths", "scripts/no_local_paths.py", "scripts/ci_test.sh"}


def tracked():
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"], capture_output=True, check=True).stdout
    return [p for p in out.decode().split("\0") if p and p not in SELF]


def main():
    files = tracked()
    if not files:
        print("NO_LOCAL_PATHS: FAILED — no tracked files found (vacuous)")
        return 1
    hits = []
    for rel in files:
        path = os.path.join(ROOT, rel)
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError:
            continue
        if b"\0" in data[:8192]:
            continue  # binary
        if rel.startswith("scripts/sabotages/") and b"b/scripts/no_local_paths.py" in data:
            continue  # a sabotage of this checker quotes its patterns in the diff context
        for n, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
            m = PATTERN.search(line)
            if m:
                hits.append(f"{rel}:{n}: `{m.group(0)}` — {line.strip()[:120]}")
    if hits:
        for h in hits:
            print(h)
        print(f"NO_LOCAL_PATHS: FAILED — {len(hits)} local path(s) in tracked files. Name a repo file by its "
              "GitHub URL (https://github.com/ckluis/samen/blob/<sha>/<path>); a file that never left a laptop "
              "by what it is, not where it was.")
        return 1
    print(f"NO_LOCAL_PATHS: OK ({len(files)} tracked files, no local machine paths)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

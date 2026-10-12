#!/usr/bin/env python3
"""scripts/sabotage reanchor <n…> — re-anchor sabotage patches that stopped applying (ADR-053 §2.7, C8).

A patch that no longer applies is a guard with no red. The rule (CLAUDE.md, issue #53) is: re-anchor it —
same semantics, regenerated from a real edit — never delete it. This does that mechanically, and PROVES it:

  1. the MUST_FAIL tests still exist (grep -F in the patch's TEST_FILES);
  2. each touched file is THREE-WAY merged: base = the patch's pre-image blob, theirs = that blob with the
     patch applied, ours = the file as it is in the working tree now (`git merge-file`);
  3. the candidate patch is the diff between the working tree and the merge result; its header (every line
     before the first `diff --git`) is kept BYTE-IDENTICAL;
  4. proof: the MUST_FAIL tests PASS without the patch (baseline) and are among the failures WITH it
     (`scripts/sabotage.sh --range N-N`: flip + byte-exact restore);
  5. only then is the patch rewritten.

Anything else is REFUSED with a reason and the original patch is left byte-for-byte as it was (verified):
a 3-way conflict, a missing pre-image blob, a named test that no longer exists, a baseline that is red, a
patch that no longer flips its named test (C8: the semantics were not preserved), or a patch that breaks the
compile instead of a test.

usage: scripts/sabotage reanchor <number|patch-file>…
exit:  0 every named patch is re-anchored (or already applies)  ·  1 at least one was refused  ·  2 usage
"""
import hashlib
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SAB = os.path.join(REPO, "scripts", "sabotages")


class Refuse(Exception):
    pass


def run(args, cwd=REPO, inp=None, env=None):
    p = subprocess.run(args, cwd=cwd, input=inp, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    return p.returncode, p.stdout


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def find_patch(arg):
    if re.fullmatch(r"\d+", arg):
        n = int(arg)
        hits = sorted(f for f in os.listdir(SAB) if re.match(r"^0*%d-.*\.patch$" % n, f))
        if not hits:
            raise Refuse("no patch numbered %d in scripts/sabotages/" % n)
        if len(hits) > 1:
            raise Refuse("number %d is ambiguous (%s); a number shared by two patches cannot be replayed alone "
                         "by --range — re-anchor them by hand" % (n, ", ".join(hits)))
        return os.path.join(SAB, hits[0])
    p = arg if os.path.isabs(arg) else os.path.join(REPO, arg)
    if not os.path.isfile(p):
        p = os.path.join(SAB, os.path.basename(arg))
    if not os.path.isfile(p):
        raise Refuse("no such patch: %s" % arg)
    return p


def split_patch(text):
    """-> (header_text, [section_text…]) split at `diff --git` lines."""
    m = re.search(r"^diff --git ", text, re.M)
    if not m:
        raise Refuse("the patch has no `diff --git` section")
    header, body = text[: m.start()], text[m.start():]
    parts = re.split(r"(?m)^(?=diff --git )", body)
    return header, [p for p in parts if p]


def headers(header):
    out = {"APP": [], "TEST_FILES": [], "MUST_FAIL": []}
    for line in header.split("\n"):
        m = re.match(r"^# (APP|TEST_FILES|MUST_FAIL): (.*)$", line)
        if m:
            out[m.group(1)].append(m.group(2))
    return out


def test_dir_has(app, test_files, literal):
    for tf in test_files:
        p = os.path.join(REPO, app, tf)
        if os.path.isfile(p):
            with open(p, errors="replace") as f:
                if literal in f.read():
                    return True
    return False


def merge_section(section, scratch):
    """Three-way merge one file section. -> (path, current_bytes, merged_bytes)."""
    m = re.match(r"diff --git a/(\S+) b/(\S+)\n", section)
    if not m or m.group(1) != m.group(2):
        raise Refuse("only in-place edits can be re-anchored (rename/copy section: %r)" % section.split("\n", 1)[0])
    path = m.group(1)
    im = re.search(r"^index ([0-9a-f]+)\.\.([0-9a-f]+)", section, re.M)
    if not im or set(im.group(1)) == {"0"} or set(im.group(2)) == {"0"} or re.search(r"^(new|deleted) file mode", section, re.M):
        raise Refuse("%s: a patch that creates or deletes a file cannot be re-anchored mechanically" % path)
    rc, base = run(["git", "cat-file", "blob", im.group(1)])
    if rc != 0:
        raise Refuse("%s: the patch's pre-image blob %s is not in this repository (history was rewritten or "
                     "squashed), so there is no common base to 3-way merge against" % (path, im.group(1)))
    # theirs = base + the patch (the object for the post-image was never stored by `git diff`)
    d = tempfile.mkdtemp(dir=scratch)
    os.makedirs(os.path.join(d, os.path.dirname(path)), exist_ok=True)
    with open(os.path.join(d, path), "wb") as f:
        f.write(base)
    rc, out = run(["git", "apply", "-"], cwd=d, inp=section.encode())
    if rc != 0:
        raise Refuse("%s: the patch does not even apply to its own pre-image blob %s: %s"
                     % (path, im.group(1), out.decode(errors="replace").strip()[:200]))
    with open(os.path.join(d, path), "rb") as f:
        theirs = f.read()
    cur_path = os.path.join(REPO, path)
    if not os.path.isfile(cur_path):
        raise Refuse("%s no longer exists in the working tree (moved or deleted) — re-anchor by hand onto its new home" % path)
    with open(cur_path, "rb") as f:
        cur = f.read()
    files = {}
    for name, data in (("ours", cur), ("base", base), ("theirs", theirs)):
        files[name] = os.path.join(d, "m." + name)
        with open(files[name], "wb") as f:
            f.write(data)
    p = subprocess.run(["git", "merge-file", "-p", "-L", "ours", "-L", "base", "-L", "theirs",
                        files["ours"], files["base"], files["theirs"]],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        n = p.returncode if 0 < p.returncode < 128 else "?"
        raise Refuse("%s: 3-way merge CONFLICT (%s region(s)) — the lines the sabotage edits were themselves changed, "
                     "so its meaning cannot be carried over mechanically" % (path, n))
    if p.stdout == cur:
        raise Refuse("%s: the merge result equals the current file — the sabotage's edit is already present or "
                     "has no effect here; there is nothing left to sabotage" % path)
    return path, cur, p.stdout


def candidate_body(merges, scratch):
    """The diff from the working tree to the merge result, as a patch body with repo-relative paths."""
    g = tempfile.mkdtemp(dir=scratch)
    run(["git", "init", "-q", "."], cwd=g)
    for path, cur, _ in merges:
        os.makedirs(os.path.dirname(os.path.join(g, path)) or g, exist_ok=True)
        shutil.copy2(os.path.join(REPO, path), os.path.join(g, path))
    run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "add", "-A"], cwd=g)
    run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "cur"], cwd=g)
    for path, _, merged in merges:
        with open(os.path.join(g, path), "wb") as f:
            f.write(merged)
    rc, out = run(["git", "diff", "--no-color", "--no-ext-diff", "--binary"], cwd=g)
    if rc != 0 or not out.strip():
        raise Refuse("could not produce the re-anchored diff")
    return out


def classify_flip(rc, out):
    """-> None when the harness confirmed the flip + restore, else a refusal reason."""
    text = out.decode(errors="replace")
    if rc == 0 and "restore: byte-exact" in text:
        return None
    if "no test-failure headers found" in text:
        return ("under the re-anchored patch the suite fails with NO named test failure (compile or migration "
                "error) — the sabotage no longer exercises the guard")
    if "suite PASSED under sabotage" in text:
        return "under the re-anchored patch the tests PASS — the named tests no longer fail (the semantics were not preserved)"
    if "named test did not flip" in text:
        lines = [l.strip() for l in text.splitlines() if "did not flip" in l or re.match(r"^\s*\d+\) (test|property)", l)]
        return "the suite fails under the re-anchored patch but NOT the named test: " + " | ".join(lines[:4])
    if "SHA mismatch" in text or "residue" in text:
        return "the replay did not restore the tree byte-exact"
    return "the replay failed (exit %d): %s" % (rc, " | ".join(text.strip().splitlines()[-4:]))


def reanchor(patch):
    name = os.path.basename(patch)
    with open(patch, "rb") as f:
        original = f.read()
    text = original.decode()
    header, sections = split_patch(text)
    hd = headers(header)
    if not (hd["APP"] and hd["TEST_FILES"] and hd["MUST_FAIL"]):
        raise Refuse("%s: missing APP / TEST_FILES / MUST_FAIL header" % name)
    app = hd["APP"][0]
    tfs = hd["TEST_FILES"][0].split()
    num = int(re.match(r"(\d+)-", name).group(1))
    # 1. the named tests must still exist
    for mf in hd["MUST_FAIL"]:
        if not test_dir_has(app, tfs, mf):
            raise Refuse("%s: the named test no longer exists: MUST_FAIL \"%s\" is not in %s/{%s}. A patch cannot be "
                         "re-anchored onto a test that is gone — restore/rename the test or update the header by hand"
                         % (name, mf, app, ",".join(tfs)))
    rc, out = run(["git", "apply", "--check", patch])
    if rc == 0:
        return "already applies to the working tree — nothing to re-anchor (replay: scripts/sabotage.sh --range %d-%d)" % (num, num)
    scratch = tempfile.mkdtemp(prefix="samen_reanchor.")
    backup = os.path.join(scratch, "original.patch")
    shutil.copy2(patch, backup)
    replaced = False
    try:
        # 2. 3-way merge each file
        merges = [merge_section(s, scratch) for s in sections]
        body = candidate_body(merges, scratch)
        candidate = header.encode() + body
        # 3. the baseline: the named tests pass WITHOUT the patch
        rc, out = run(["mix", "test"] + tfs, cwd=os.path.join(REPO, app))
        if rc != 0:
            raise Refuse("%s: the baseline is RED — %s/{%s} fail on the current tree even without the sabotage, so "
                         "\"fails with it, passes without it\" cannot be shown: %s"
                         % (name, app, ",".join(tfs), " | ".join(l.strip() for l in out.decode(errors="replace").splitlines()
                                                                 if re.match(r"^\s*\d+\) (test|property)", l))[:300]))
        # 4. install the candidate in place and replay it through the real harness
        with open(patch, "wb") as f:
            f.write(candidate)
        replaced = True
        rc, out = run(["git", "apply", "--check", patch])
        if rc != 0:
            raise Refuse("%s: the re-anchored patch does not apply: %s" % (name, out.decode(errors="replace").strip()[:200]))
        rc, out = run(["bash", os.path.join(REPO, "scripts", "sabotage.sh"), "--range", "%d-%d" % (num, num)])
        why = classify_flip(rc, out)
        if why:
            raise Refuse("%s: %s" % (name, why))
        for path, cur, _ in merges:  # the replay must have left the tree exactly as it found it
            with open(os.path.join(REPO, path), "rb") as f:
                if f.read() != cur:
                    raise Refuse("%s: %s differs from before the replay" % (name, path))
        replaced = False  # keep the new patch
        flipped = [l.strip() for l in out.decode(errors="replace").splitlines() if "flip confirmed" in l]
        return "re-anchored (%d file(s) 3-way merged); header byte-identical; %s; baseline green; restore byte-exact" % (
            len(merges), "; ".join(flipped[:2]) or "flip confirmed")
    finally:
        if replaced:
            shutil.copy2(backup, patch)
            if sha(patch) != hashlib.sha256(original).hexdigest():
                print("sabotage reanchor: !! COULD NOT RESTORE %s byte-exact — recover it with git checkout" % name, file=sys.stderr)
        shutil.rmtree(scratch, ignore_errors=True)


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else 2
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    bad = 0
    for arg in argv:
        patch, before = None, None
        try:
            patch = find_patch(arg)
            before = sha(patch)
            msg = reanchor(patch)
            print("REANCHOR %s: OK — %s" % (os.path.basename(patch), msg))
        except Refuse as e:
            bad += 1
            print("REANCHOR %s: REFUSED — %s" % (arg, e))
            if patch and before and os.path.isfile(patch) and sha(patch) == before:
                print("  (the original patch is untouched)")
    if bad:
        print("SABOTAGE REANCHOR: FAILED — %d of %d refused; a refused patch is left exactly as it was. Never delete "
              "a guard to make apply-check pass." % (bad, len(argv)))
        return 1
    print("SABOTAGE REANCHOR: ALL OK (%d)" % len(argv))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""scripts/ci_test_legacy.py — the EQUIV case of scripts/ci_test.sh (ADR-053 §2.1: the wrappers
keep the pre-ADR-053 step list and markers).

  markers                                 read a pre-ADR-053 ci.sh / ci-fast.sh on stdin; print every
                                          `==> … PASSED` / `passed.` / `Skipping` marker it could
                                          print, sorted (the committed fixtures ci/legacy_*markers.txt)
  steps <legacy_steps.tsv> <markers.txt> <steps.conf>
                                          every legacy marker maps to manifest step(s) running the
                                          legacy command in the legacy directory; exit 1 otherwise
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def markers(src):
    out = set()
    spikes = re.findall(r'^run_spike "\$REPO_ROOT/spikes/(\w+)"', src, re.M)
    for line in src.splitlines():
        s = line.strip()
        if s.startswith("#"):
            continue
        m = re.match(r'echo "(==> [^"]*)"$', s)
        if not m:
            continue
        t = m.group(1)
        if t.endswith(": PASSED") and "$spike_name" in t:
            out.update(t.replace("$spike_name", sp) for sp in spikes)
        elif "$" not in t and re.search(r"PASSED|passed\.|^==> Skipping", t):
            out.add(t)
    for label in re.findall(r'run_gen_probe "[^"]+" \\\n\s+"([^"]+)"', src):
        out.add("==> %s: PASSED" % label)
    gm = re.search(r"^gate_markers=\((.*?)^\)", src, re.S | re.M)
    if gm:
        for q in re.findall(r"\$?'([^']*)'|\"([^\"]*)\"", gm.group(1)):
            for part in (q[0] or q[1]).split("\\n"):
                if part.strip():
                    out.add(part.strip())
    return sorted(out)


def steps(tsv, marker_file, conf):
    os.environ["SAMEN_CI_MANIFEST"] = conf
    import ci_driver
    man = ci_driver.Manifest(conf)
    legacy = {l.rstrip("\n") for l in open(marker_file) if l.strip()}
    rows, errs = {}, []
    for n, line in enumerate(open(tsv), 1):
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 3:
            errs.append("%s:%d: want 3 tab-separated fields" % (tsv, n))
            continue
        mk, cwd, frag = parts
        if mk not in legacy:
            errs.append("%s:%d: %r is not a legacy marker (the fixture cannot invent one)" % (tsv, n, mk))
        rows[mk] = (cwd, frag)
    for mk in sorted(legacy - set(rows)):
        errs.append("legacy marker with no row in %s: %r" % (tsv, mk))
    for mk, (cwd, frag) in sorted(rows.items()):
        if cwd == "-":
            continue  # a group/skip/final marker: proven printed by the list --markers half
        owners = [s for s in man.steps if mk in s.markers]
        group = [g for g, v in man.groups.items() if mk in v["markers"]]
        if group:
            owners = [s for s in man.steps if s.group in group]
            bad = [s.id for s in owners if s.cwd != cwd or frag not in (s.cmd + "\n" + (s.unsharded_cmd or ""))]
            if not owners or bad:
                errs.append("%r: group step(s) %s do not run %r in %s" % (mk, bad or "(none)", frag, cwd))
            continue
        if not owners:
            errs.append("%r: no manifest step prints it" % mk)
            continue
        if not any(s.cwd == cwd and frag in (s.cmd + "\n" + (s.unsharded_cmd or "")) for s in owners):
            errs.append("%r: step(s) %s do not run %r in %s" % (mk, [s.id for s in owners], frag, cwd))
    # dialyzer: the per-project steps together cover exactly the gate's default project list
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    src = open(os.path.join(root, "scripts", "dialyzer_gate.sh")).read()
    m = re.search(r"\|\| APPS=\(([^)]*)\)", src)
    want = set(m.group(1).split()) if m else set()
    have = set()
    for s in man.steps:
        mm = re.search(r"scripts/dialyzer_gate\.sh\s+(\S+)", s.cmd)
        if mm:
            have.add(mm.group(1))
    if not want or want != have:
        errs.append("dialyzer steps cover %s; dialyzer_gate.sh's default list is %s" % (sorted(have), sorted(want)))
    for e in errs:
        print(e)
    print("LEGACY STEP LIST: %d marker row(s) checked, %d problem(s)" % (len(rows), len(errs)))
    return 1 if errs else 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["markers"]:
        print("\n".join(markers(sys.stdin.read())))
        sys.exit(0)
    if sys.argv[1:2] == ["steps"] and len(sys.argv) == 5:
        sys.exit(steps(*sys.argv[2:5]))
    sys.stderr.write(__doc__)
    sys.exit(2)

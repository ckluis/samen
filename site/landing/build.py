#!/usr/bin/env python3
"""Assemble the landing page (repo-root index.html) from the parts in this directory.

Every number on the page that describes the tree is computed here, from the tree, at build
time — the page cannot drift from the repo the way a hand-typed count does.

Usage (from the repo root):  python3 site/landing/build.py [out]   (default out: index.html)
       python3 site/landing/build.py --check                      (exit 1 if index.html is stale)
"""
import glob, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
PARTS = ["00-head.html", "01-top.html", "02-act-start-trust.html", "03-act-rest-proof.html",
         "04-bottom.html", "05-script.html"]


def rel(*p):
    return os.path.join(ROOT, *p)


def count(pattern):
    return len(glob.glob(rel(pattern)))


def claude_md_count(name):
    m = re.search(r"<!--count:%s-->([^<]+)<!--/count-->" % re.escape(name), open(rel("CLAUDE.md")).read())
    if not m:
        sys.exit("build: CLAUDE.md has no <!--count:%s--> marker" % name)
    return m.group(1)


def gen_gate_steps():
    src = open(rel("samen_core", "priv", "gen_app_flagship_probe.exs")).read()
    m = re.search(r"verifier gate \((\d+) steps", src)
    if not m:
        sys.exit("build: cannot find the generated gate's step count in gen_app_flagship_probe.exs")
    return m.group(1)


def scopes():
    return sorted(os.path.basename(p)[:-3] for p in glob.glob(rel("samen_core", "lib", "samen", "scopes", "*.ex")))


def route_macros():
    src = open(rel("samen_web", "lib", "samen", "web", "router.ex")).read()
    return sorted(set(re.findall(r"defmacro (samen_[a-z_]+_routes)", src)))


def scope_tiles(names):
    label = {"crm": "CRM", "cms": "CMS", "sales_ops": "Sales ops"}
    out, cols, w, h, gx, gy = [], 4, 132, 62, 10, 10
    for i, n in enumerate(names):
        r, c = divmod(i, cols)
        x, y = c * (w + gx), r * (h + gy)
        txt = label.get(n, n.replace("_", " ").capitalize())
        out.append('<g transform="translate(%d,%d)"><rect width="%d" height="%d" rx="12" class="f-raised" stroke="#2A2E42"/>'
                   '<circle cx="18" cy="31" r="4" fill="#4CC294"/><text x="30" y="35" class="t-ink" font-size="13">%s</text></g>'
                   % (x, y, w, h, txt))
    return "\n    ".join(out)


def build_sha():
    try:
        return subprocess.check_output(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], text=True).strip()
    except Exception:
        return "unknown"


def values():
    sc = scopes()
    macros = route_macros()
    if not sc or not macros:
        sys.exit("build: found no scopes or no route macros — refusing to print a zero")
    return {
        "SABOTAGES": str(count("scripts/sabotages/*.patch")),
        "ADRS": str(count("docs/adr/ADR-*.md")),
        "VERIFIERS": str(count("samen_core/lib/mix/tasks/samen.verify.*.ex")),
        "SCOPES": str(len(sc)),
        "ROUTE_MACROS": str(len(macros)),
        "SCOPE_TILES": scope_tiles(sc),
        "GEN_GATE_STEPS": gen_gate_steps(),
        "PII_TIERS": str(count("samen_core/lib/samen/no_plaintext_pii/tiers/**/*.ex") + count("samen_core/lib/samen/no_plaintext_pii/tiers/*.ex")),
        "SHRED_TIERS": str(count("samen_core/lib/samen/no_plaintext_pii/tiers/post_shred/*.ex")),
        "MUT_WATCH_MODULES": claude_md_count("watchlist_modules"),
        "MUT_WATCH_MUTANTS": claude_md_count("watchlist_mutants"),
        "MUT_CORPUS_TARGETS": claude_md_count("corpus_targets"),
        "MUT_CORPUS_MUTANTS": claude_md_count("corpus_mutants"),
        # the commit the counts were read from; --check ignores it so a rebuild is not "stale" per commit
        "BUILD_SHA": build_sha(),
    }


def render(vals):
    html = "".join(open(os.path.join(HERE, p)).read() for p in PARTS)
    for k, v in vals.items():
        html = html.replace("{{%s}}" % k, v)
    left = sorted(set(re.findall(r"\{\{([A-Z_]+)\}\}", html)))
    if left:
        sys.exit("build: unfilled placeholder(s): " + ", ".join(left))
    return html


def main(argv):
    vals = values()
    if argv[:1] == ["--check"]:
        cur = open(rel("index.html")).read()
        vals["BUILD_SHA"] = (re.search(r"generated from the tree at build time \(([^)]*)\)", cur) or [None, ""])[1]
        if render(vals) != cur:
            print("LANDING: index.html is stale — run: python3 site/landing/build.py")
            return 1
        print("LANDING: OK (index.html matches site/landing/ and the tree's counts)")
        return 0
    out = argv[0] if argv else rel("index.html")
    html = render(vals)
    with open(out, "w") as f:
        f.write(html)
    print("LANDING: wrote %s (%d KB) · %s" % (out, len(html) // 1024,
          " · ".join("%s=%s" % (k, v) for k, v in vals.items() if k not in ("SCOPE_TILES",))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Lay out the landing page's #replay section from the REAL replay export.

Requires ADR-052 session replay (on main since PR #83) only to PRODUCE the input; this script
itself is plain Python 3 (stdlib only). Input: the JSON written by scripts/landing/replay_demo_export_test.exs.

    python3 -I scripts/landing/replay_demo_section.py /tmp/replay-demo/replay_demo.json /tmp/replay-demo [index.html]

writes <out>/replay.css and <out>/replay.html. index.html carries them verbatim: the CSS block
(it starts "SESSION REPLAY (ADR-052)") at the end of the head <style>, the section right before
"<!-- 08-generate -->". Given a third argument, the script splices both into that file in place
(replacing the previous block and section), so the page is reproducible byte for byte from the
JSON. Every value shown comes from the export; the script only formats, groups
and counts (and asserts: per-viewer screens are consistent, no seeded value is in any stored row,
the audit rows match the impersonation sessions).
"""
import hashlib, html, json, os, re, sys
from collections import Counter

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
D = json.load(open(src))
F = D["frames"]
N = len(F)
T = 14  # loop seconds (1 s per frame)
assert N == 14, N

V = [  # (short, export key, tab label)
    ("o", "operator_no_grant", "Operator &middot; no grant"),
    ("g", "operator_with_grant", "Operator &middot; reveal grant"),
    ("a", "tenant_admin", "Tenant admin"),
    ("e", "after_shred", "After erasure"),
]
TENANT = {"a", "e"}
esc = html.escape


def short(u):
    return u[:8] + "&hellip;" + u[-4:]


# --------------------------------------------------------------------------------------------
# screens: which recorded screen each frame shows (asserted against the export, per viewer)
SCREENS = {"A": range(0, 4), "B": range(4, 10), "C": range(10, 12), "D": range(12, 14)}
PLACEHOLDER = range(6, 10)  # tenant planes: the new-contact form frames do not render


def screen_of(i):
    for k, r in SCREENS.items():
        if i in r:
            return k


def rows_key(rows):
    return json.dumps(rows, sort_keys=True)


screen_rows = {}
for i, f in enumerate(F):
    for s, key, _ in V:
        view = f["views"][key]
        if view["error"]:
            assert s in TENANT and i in PLACEHOLDER and view["error"] == ":render_failed", (i, s, view["error"])
            continue
        assert not (s in TENANT and i in PLACEHOLDER), (i, s)
        k = (screen_of(i), s)
        if k in screen_rows:
            assert rows_key(screen_rows[k]) == rows_key(view["rows"]), ("screen drift", i, s)
        else:
            screen_rows[k] = view["rows"]

# --------------------------------------------------------------------------------------------
# cell rendering


def cell_cls(text):
    if text == "••••":
        return "rp-m"
    if text == "[erased]":
        return "rp-er"
    if text in ("—", None, ""):
        return "rp-no"
    if text.startswith("▒"):
        return "rp-r"
    return "rp-c"


def variants(values, extra_cls=""):
    """values: {viewer_short: text}. Emit the minimum set of variant spans. A value the reveal
    grant opened (clear for g, not for o) is its own span so it can carry the reveal tint."""
    groups = {}
    for s, _, _ in V:
        rev = s == "g" and cell_cls(values[s]) == "rp-c" and values["o"] != values[s]
        groups.setdefault((values[s], rev), []).append(s)
    if len(groups) == 1:
        ((text, _),) = groups
        return f'<span class="{cell_cls(text)}{extra_cls}">{esc(text)}</span>'
    out = []
    for (text, rev), vs in groups.items():
        vcls = " ".join("v" + s for s in vs)
        c = cell_cls(text) + (" rp-rev" if rev else "")
        out.append(f'<span class="x {vcls} {c}{extra_cls}">{esc(text)}</span>')
    return "".join(out)


def avatar(values):
    groups = {}
    for s, _, _ in V:
        groups.setdefault(values[s], []).append(s)
    out = []
    for text, vs in groups.items():
        vcls = "" if len(groups) == 1 else "x " + " ".join("v" + s for s in vs) + " "
        mask = " rp-av--q" if text == "??" else ""
        out.append(f'<i class="{vcls}rp-av{mask}">{esc(text)}</i>')
    return "".join(out)


def screen_html(name):
    # rows per viewer for this screen, aligned by row position
    per = {s: screen_rows[(name, s)] for s, _, _ in V}
    n = len(per["o"])
    assert all(len(per[s]) == n for s in per)
    trs = []
    for r in range(n):
        cols = {}
        for c in ("initials", "name", "email", "phone", "company", "title"):
            cols[c] = {s: per[s][r][c] for s in per}
        # company/title are the same for every viewer (shape only)
        for c in ("company", "title"):
            assert len(set(cols[c].values())) == 1, (name, r, c, cols[c])
        trs.append(
            "<tr>"
            f'<td class="rp-nm"><span class="rp-nmw">{avatar(cols["initials"])}{variants(cols["name"])}</span></td>'
            f'<td class="rp-em">{variants(cols["email"])}</td>'
            f'<td class="rp-ph">{variants(cols["phone"])}</td>'
            f'<td class="rp-co">{variants(cols["company"])}</td>'
            f'<td class="rp-ti">{variants(cols["title"])}</td>'
            '<td class="rp-act x va ve"><span class="rp-del">Delete</span></td>'
            "</tr>"
        )
    count = {s: F[next(iter(SCREENS[name]))]["views"][key]["count"] for s, key, _ in V}
    assert len(set(count.values())) == 1
    return (
        f'<div class="sx s{name}">'
        '<table><thead><tr><th class="rp-nm">Name</th><th class="rp-em">Email</th><th class="rp-ph">Phone</th>'
        '<th class="rp-co">Company</th><th class="rp-ti">Title</th><th class="rp-act x va ve"><span class="rp-sr">Actions</span></th></tr></thead>'
        f'<tbody>{"".join(trs)}</tbody></table>'
        f'<span class="rp-count" aria-hidden="true" data-n="{count["o"]}"></span>'
        "</div>"
    ), count["o"]


# --------------------------------------------------------------------------------------------
# JSON formatting (key order exactly as stored; long lists of records elided, marked)

def jtok(s):
    """syntax-tint one compact JSON fragment produced by json.dumps (keys stay the pre colour)"""
    out = []
    for m in re.finditer(r'"(?:[^"\\]|\\.)*"(\s*:)?|-?\d+(?:\.\d+)?|\btrue\b|\bfalse\b|\bnull\b|[^"\d\-tfn]+|.', s):
        t = m.group(0)
        if t.startswith('"'):
            if m.group(1):
                k = t[: t.rfind(":")].rstrip()
                rest = t[len(k):]
                kk = json.loads(k)
                cls = {"$ref": "ref", "$redacted": "red", "$shape": "shp"}.get(kk)
                if cls:
                    out.append(f'<b class={cls}>{esc(k)}</b>{rest}')
                elif kk.startswith("$"):
                    out.append(f'<i class=m>{esc(k)}</i>{rest}')
                elif kk == "length":
                    out.append(f'<i class=n>{esc(k)}</i>{rest}')
                else:
                    out.append(esc(t))
            else:
                out.append(f'<i class=s>{esc(t)}</i>')
        elif re.fullmatch(r"-?\d+(?:\.\d+)?", t):
            out.append(f'<i class=n>{t}</i>')
        elif t in ("true", "false", "null"):
            out.append(f'<i class=l>{t}</i>')
        else:
            out.append(esc(t))
    return "".join(out)


WIDTH = 52


def inline_ok(v, compact, ind, width=None):
    if len(compact) + ind <= (width or WIDTH) or not isinstance(v, (dict, list)) or not v:
        return True
    if isinstance(v, dict) and len(v) == 1:
        (k,) = v
        if k.startswith("$") and k not in ("$record", "$shape"):
            return True
    if isinstance(v, dict) and "key" in v and "type" in v and not v.get("fields"):
        return True
    return False


def fmt(v, ind=0, key=None, width=None):
    """-> [(depth, html)] one entry per display line (hanging-indented by CSS)"""
    compact = json.dumps(v, ensure_ascii=False, separators=(", ", ": "))
    if inline_ok(v, compact, ind, width):
        return [(ind, jtok(compact))]
    lines = []
    if isinstance(v, dict):
        lines.append((ind, "{"))
        items = list(v.items())
        for n, (k, x) in enumerate(items):
            comma = "," if n < len(items) - 1 else ""
            kj = jtok(json.dumps(k) + ": ")
            sub = fmt(x, ind + 1, k, width)
            lines.append((ind + 1, kj + sub[0][1]))
            lines.extend(sub[1:])
            d, h = lines[-1]
            lines[-1] = (d, h + comma)
        lines.append((ind, "}"))
    else:
        lines.append((ind, "["))
        items = v
        recs = [x for x in items if isinstance(x, dict) and "$record" in x]
        if key == "items" and len(recs) == len(items) and len(items) > 1:
            sub = fmt(items[0], ind + 1, None, width)
            lines.extend(sub)
            d, h = lines[-1]
            lines[-1] = (d, h + ",")
            lines.append((ind + 1, f'<i class=e>&#8943; {len(items) - 1} more "$record" rows, same shape &mdash; elided on this page</i>'))
        else:
            for n, x in enumerate(items):
                sub = fmt(x, ind + 1, None, width)
                lines.extend(sub)
                if n < len(items) - 1:
                    d, h = lines[-1]
                    lines[-1] = (d, h + ",")
        lines.append((ind, "]"))
    return lines


def render_lines(lines):
    return "".join(f"<b class=j{min(d, 12)}>{h}</b>" for d, h in lines)


# --------------------------------------------------------------------------------------------
# per-frame content

def label_parts(lbl):
    head, _, rest = lbl.partition(" ")
    return head, rest


def shape_fields(fields, prefix=""):
    out = []
    for f in fields:
        k = prefix + (f.get("key") or "?")
        if f.get("fields"):
            out.extend(shape_fields(f["fields"], k + "."))
        else:
            out.append((k, f.get("type"), f.get("length"), f.get("class"), f.get("value")))
    return out


def frame_detail(f):
    p = json.loads(f["stored"])
    kind = f["kind"]
    if kind == "mount":
        return (
            f'view <b>{esc(p["view"].split(".")[-1])}</b> &middot; md5 <code>{p["view_md5"][:8]}&hellip;</code>'
            f' &middot; {len(p["assigns"])} assigns, each sanitized'
        )
    if kind == "params":
        fs = shape_fields(p["params"]["$shape"]["fields"])
        sh = " ".join(f'<span class="rp-sh"><b>{esc(k)}</b> {t}&middot;{l} {esc(c)}</span>' for k, t, l, c, _ in fs)
        return f'route template <b>{esc(p["route"])}</b> &mdash; never the concrete path &middot; {sh}'
    if kind == "render":
        ks = list(p["assigns"].keys())
        shown = ", ".join(esc(k) for k in ks[:4]) + (f" +{len(ks) - 4}" if len(ks) > 4 else "")
        return f'only the changed assigns: <b>{shown}</b>'
    if kind == "event":
        fs = shape_fields(p["params"]["$shape"]["fields"])
        if not fs:
            return "no params"
        heads = {k.split(".")[0] for k, *_ in fs}
        prefix = ""
        if len(heads) == 1 and all("." in k for k, *_ in fs):
            (h,) = heads
            prefix = f'<span class="rp-pfx">{esc(h)}.</span>'
            fs = [(k[len(h) + 1:], t, l, c, v) for k, t, l, c, v in fs]
        parts = []
        for k, t, l, c, val in fs:
            kept = f' kept <b class="rp-kept">{esc(val)}</b>' if val is not None else ""
            cls = "" if c in (None, "none") else f" {esc(c)}"
            parts.append(f'<span class="rp-sh"><b>{esc(k)}</b> {t}&middot;{l}{cls}{kept}</span>')
        note = "" if any(v is not None for *_, v in fs) else '<span class="rp-typed">typed &rarr; shape only</span>'
        return note + prefix + " ".join(parts)
    if kind == "exit":
        return f'reason <b>{esc(p["reason"])}</b> &mdash; never the exit term'
    return ""


def refs_summary(refs):
    c = Counter(r["outcome"] for r in refs)
    lab = {"clear": ("ok", "shown (current)"), "masked": ("mut", "&#8226;&#8226;&#8226;&#8226; masked"),
           "shredded": ("bad", "erased (shredded)"), "empty": ("mut", "empty"), "gone": ("warn", "gone")}
    pills = "".join(
        f'<span class="rp-pill {lab[o][0]}"><i></i>{n} {lab[o][1]}</span>' for o, n in c.items()
    )
    return f'<span class="rp-refn">References <b>{len(refs)}</b></span>{pills}'


def frame_refs_html(i):
    vals = {s: refs_summary(F[i]["views"][k]["refs"]) for s, k, _ in V}
    groups = {}
    for s, _, _ in V:
        groups.setdefault(vals[s], []).append(s)
    return "".join(
        f'<span class="x {" ".join("v" + s for s in vs)}">{h}</span>' for h, vs in groups.items()
    )


# --------------------------------------------------------------------------------------------
# naive vs stored contrast (computed from the real pre-sanitization assigns)

people_strings = set()
for f in F:
    nv = f["naive"]
    if nv["kind"] in ("render", "mount"):
        page = (nv["assigns"].get("page") or {}).get("items") or []
        for it in page:
            for k in ("display_name", "job_title"):
                if it.get(k):
                    people_strings.add(it[k])
            for k in ("full_name",):
                if it.get(k):
                    n = json.loads(it[k]) if isinstance(it[k], str) else it[k]
                    people_strings.add((n["first"] + " " + n["last"]).strip())
            for k, sub in (("emails", "address"), ("phones", "number")):
                v = it.get(k)
                if v:
                    lst = json.loads(v) if isinstance(v, str) else v
                    for e in lst:
                        people_strings.add(e[sub])
        for name in (nv["assigns"].get("company_names") or {}).values():
            people_strings.add(name)
    if nv["kind"] == "event":
        def walk(x):
            if isinstance(x, dict):
                for kk, vv in x.items():
                    if kk in ("org", "field"):
                        continue
                    walk(vv)
            elif isinstance(x, str):
                people_strings.add(x)
        walk(nv["params"])
people_strings.discard("")


def count_occ(x, vals):
    if isinstance(x, dict):
        return sum(count_occ(v, vals) for v in x.values())
    if isinstance(x, list):
        return sum(count_occ(v, vals) for v in x)
    if isinstance(x, str):
        n = 0
        for v in vals:
            if x == v or (len(v) > 3 and v in x):
                n += 1
        return n
    return 0


naive_occ = sum(count_occ(f["naive"], people_strings) for f in F)


def leaves(x):
    if isinstance(x, dict):
        for k, v in x.items():
            yield k
            yield from leaves(v)
    elif isinstance(x, list):
        for v in x:
            yield from leaves(v)
    elif isinstance(x, str):
        yield x


stored_hits = 0
for f in F:
    for leaf in leaves(json.loads(f["stored"])):
        for v in people_strings:
            if leaf == v or (len(v) > 3 and v in leaf):
                stored_hits += 1
assert stored_hits == 0, stored_hits
N_DISTINCT = len(people_strings)

# --------------------------------------------------------------------------------------------
# HTML


tabs = "".join(
    f'<label class="rp-tab rp-tab--{s}" for="rpv-{s}"><span class="rp-d"></span>{lab}</label>' for s, _, lab in V
)

caps = {
    "o": "An operator inside an <b>impersonation session</b> for Blue Ridge &mdash; the only way an operator can open a replay. Every referenced field resolves to <span class=\"rp-m\">&#8226;&#8226;&#8226;&#8226;</span>; the session id is the correlation on the audit row.",
    "g": "The same operator role, holding a second-party-approved <b>reveal grant on Ada Whitfield</b>. Her row resolves through the vault, inside a reveal span. Nobody else&rsquo;s does: a grant is per subject.",
    "a": "Blue Ridge&rsquo;s own <b>admin</b>, on the tenant plane: their org, in the clear. The typed text is still shape only &mdash; the recording never had it, so no viewer can get it back.",
    "e": "The same admin after <code>Samen.Erasure.shred</code> of Ada Whitfield. Her key is gone, so every reference to her resolves to <span class=\"rp-er\">[erased]</span>. The replay rows were not touched &mdash; same bytes as before.",
}
cap_html = "".join(f'<p class="rp-cap x v{s}">{c}</p>' for s, c in caps.items())

rid = D["replay_id"]
org = D["org_id"]
url = {
    "o": f"/operator/replays/{org}/{rid}",
    "g": f"/operator/replays/{org}/{rid}",
    "a": f"/settings/replays/{rid}",
    "e": f"/settings/replays/{rid}",
}
url_html = (
    f'<span class="x vo vg">{url["o"]}</span><span class="x va ve">{url["a"]}</span>'
)
crumb_html = '<span class="x vo vg">Operator plane</span><span class="x va ve">Settings</span>'
started = D["session_row"]["rps_started_at"].replace("T", " ")[:19]

# the drift pill shows "code unchanged since recording": the player said so for every viewer
assert set(D["drift"].values()) == {"same"}, D["drift"]

# per-frame strips
flabels, fdetails, fjson, frefs, ticks = [], [], [], [], []
for i, f in enumerate(F):
    head, rest = label_parts(f["label"])
    flabels.append(
        f'<span class="fx f{i}" style="--i:{i}"><b class="rp-k rp-k--{f["kind"]}">{esc(head)}</b> {esc(rest)}'
        f' <i>&middot; at {f["at_ms"]} ms &middot; frame {i + 1} / {N}</i></span>'
    )
    fdetails.append(f'<span class="fx f{i}" style="--i:{i}">{frame_detail(f)}</span>')
    sha = hashlib.sha256(f["stored"].encode()).hexdigest()
    body = render_lines(fmt(json.loads(f["stored"])))
    fjson.append(
        f'<div class="fx f{i} rp-jf" style="--i:{i}">'
        f'<div class="rp-jmeta"><span>seq <b>{f["seq"]}</b> &middot; kind <b>{esc(f["kind"])}</b> &middot; '
        f'{len(f["stored"].encode()):,} bytes</span><span class="rp-sha">sha256 <b>{sha[:12]}</b>&hellip;</span></div>'
        f'<pre class="rp-json">{body}</pre></div>'
    )
    ticks.append(
        f'<label class="rp-tick t{i} rp-tk--{f["kind"]}" for="rpf-{i}" style="--i:{i}">'
        f'<b>{i + 1:02d}</b><span>{esc(head)}</span><i>{esc(rest) or "&nbsp;"}</i></label>'
    )

frefs = [f'<span class="sx s{name}">{frame_refs_html(r.start)}</span>' for name, r in SCREENS.items()]
screens = []
counts = {}
for name in ("A", "B", "C", "D"):
    h, n = screen_html(name)
    screens.append(h)
    counts[name] = n

# the count bubble per screen (real `<span class="n">` value)
count_html = "".join(
    f'<span class="sx s{name}">{counts[name]}</span>' for name in ("A", "B", "C", "D")
)
count_html += '<span class="sx sP x va ve">&nbsp;</span>'

placeholder_html = (
    '<div class="sx sP x va ve rp-ph-card">'
    "<b>This frame cannot be rendered by today&rsquo;s view (a placeholder or changed code).</b>"
    "<span>Frames 7&ndash;10 are the New-contact form. The recorder never stores a form, so the player shows "
    "this card for them on the tenant plane &mdash; and the operator plane, where the form is not offered, "
    "renders the list underneath.</span></div>"
)

audit_rows = []
for s, key, lab in V:
    idx = {"o": 0, "g": 1, "a": 2, "e": 3}[s]
    a = D["audit"][idx]
    corr = a["aud_correlation_id"]
    audit_rows.append(
        f'<tr class="ar ar-{s}"><th scope="row">{lab}</th>'
        f'<td><code>{esc(a["aud_event_type"])}</code></td>'
        f'<td><code>{short(a["aud_subject_id"])}</code></td>'
        f'<td><code>{short(a["aud_actor_id"])}</code></td>'
        f'<td><code>{short(corr) if corr else "null"}</code></td>'
        f'<td><code>{esc(a["aud_detail"])}</code></td></tr>'
    )
assert D["audit"][0]["aud_correlation_id"] == D["impersonation"]["operator_no_grant"]
assert D["audit"][1]["aud_correlation_id"] == D["impersonation"]["operator_with_grant"]
assert all(a["aud_subject_id"] == rid for a in D["audit"])
assert sorted(D["audit_columns"]) == sorted(["aud_actor_id", "aud_correlation_id", "aud_detail", "aud_event_type", "aud_id", "aud_occurred_at", "aud_subject_id"])

# contrast: the same three moments, by value vs as stored


STRIKE = set(people_strings)
for f in F:
    for it in ((f["naive"].get("assigns") or {}).get("page") or {}).get("items") or []:
        n = it.get("full_name")
        if isinstance(n, str):
            n = json.loads(n)
        if n:
            STRIKE.update([n["first"], n["last"]])
STRIKE_RE = re.compile("|".join(re.escape(esc(json.dumps(p, ensure_ascii=False)[1:-1])) for p in sorted(STRIKE, key=len, reverse=True)))


def red_json(v):
    s = esc(json.dumps(v, ensure_ascii=False, indent=1))
    return STRIKE_RE.sub(lambda m: f"<s>{m.group(0)}</s>", s)


ada_id = D["shredded_subject"]
nv_items = F[2]["naive"]["assigns"]["page"]["items"]
nv_ada = next(it for it in nv_items if it["id"] == ada_id)
nv_ada = {k: nv_ada[k] for k in ("display_name", "full_name", "emails", "phones", "job_title")}
st_items = json.loads(F[2]["stored"])["assigns"]["page"]["$record"]["fields"]["items"]
st_ada = next(it for it in st_items if it["$record"]["pk"] == ada_id)["$record"]["fields"]
st_ada = {k: st_ada[k] for k in ("display_name", "full_name", "emails", "phones", "job_title")}
nv_form = F[7]["naive"]["params"]
st_form = json.loads(F[7]["stored"])["params"]
nv_filter = F[11]["naive"]["params"]
st_filter = json.loads(F[11]["stored"])["params"]

contrast_left = (
    f'<p class="rp-cm">// frame 3 &middot; render &mdash; one of the list rows</p><pre>{red_json(nv_ada)}</pre>'
    f'<p class="rp-cm">// frame 8 &middot; event validate_new &mdash; the form being typed</p><pre>{red_json(nv_form)}</pre>'
    f'<p class="rp-cm">// frame 12 &middot; the filter box</p><pre>{red_json(nv_filter)}</pre>'
)


def st_pre(v):
    return '<pre class="rp-jl">' + render_lines(fmt(v, width=70)) + "</pre>"


contrast_right = (
    f'<p class="rp-cm">// frame 3 &middot; render &mdash; the same row</p>{st_pre(st_ada)}'
    f'<p class="rp-cm">// frame 8 &middot; event validate_new</p>{st_pre(st_form)}'
    f'<p class="rp-cm">// frame 12 &middot; event other (an undeclared event keeps no name)</p>{st_pre(st_filter)}'
)

stored_total = D["stored_bytes"]

section = f"""
<!-- ======================= SESSION REPLAY (ADR-052) =======================
     Placed after #erasure: the four viewers below are the page's three ideas at once
     (two planes, the reveal grant, key-destruction erasure) applied to one recording.

     REAL DATA, RE-CREATED SCREEN. Every value in this section comes from one session recorded
     by the ADR-052 P2 recorder over the real Samen.Web.CRM.ContactsLive (fictional Blue Ridge
     contacts, .example addresses) and played back by the real P3 player for four viewers:
     scripts/landing/replay_demo_export_test.exs (ADR-052 session replay), laid out by
     scripts/landing/replay_demo_section.py. Verbatim from that
     export: the frame labels and timestamps, every rpf_payload (key order as Postgres returns it;
     long record lists elided where marked), the rendered cell text per viewer (initials, name,
     email, phone, company, title), the reference outcomes, the replay.viewed rows and the
     by-value contrast. Re-created: the screen itself is drawn in this page's CSS instead of the
     player's sandboxed srcdoc iframe (~68 KB of kit CSS per frame would blow the page budget), and
     the recorded view's workspace label (the samen_web test host's "Security Probe") is shown as
     the org it recorded, Blue Ridge Logistics. No script elements: radios + :checked, like #simulator. -->
<section class="stage rp-sec" id="replay">
  <div class="wrap">

    <span class="sec-label">Session replay &#183; ADR-052</span>
    <h2 style="max-width:18ch">Watch what happened. <em>Never what they typed.</em></h2>
    <p class="lede" style="margin-top:24px">
      A session replay that stores values is usually the largest plaintext copy in a product &mdash; every name
      on every screen, every keystroke in every form, kept for weeks. Samen&rsquo;s replay stores
      <strong>references and shapes</strong>: which record, which field, how long the text was. The value is
      looked up when someone presses play, <strong>on the viewer&rsquo;s plane, under the viewer&rsquo;s
      grants</strong>. So one recording plays back four ways &mdash; and an erased person stays erased inside it.
    </p>
    <p class="rp-tag"><b>1</b> recording <span>&middot;</span> <b>4</b> viewers <span>&middot;</span> <b>0</b> plaintext values stored</p>

    <div class="rp">
      <input type="radio" name="rpv" id="rpv-o" checked aria-label="Viewer: operator, no grant">
      <input type="radio" name="rpv" id="rpv-g" aria-label="Viewer: operator with a reveal grant">
      <input type="radio" name="rpv" id="rpv-a" aria-label="Viewer: tenant admin">
      <input type="radio" name="rpv" id="rpv-e" aria-label="Viewer: tenant admin after erasure">
      <input type="radio" name="rpf" id="rpf-a" checked aria-label="Auto-play all frames">
      {"".join(f'<input type="radio" name="rpf" id="rpf-{i}" aria-label="Pin frame {i + 1}">' for i in range(N))}

      <div class="rp-tabs" role="presentation">{tabs}</div>
      <div class="rp-caps">{cap_html}</div>

      <div class="rp-stage">
        <div class="rp-win">
          <div class="rp-bar"><i></i><i></i><i></i><span class="rp-url">{url_html}</span></div>
          <div class="rp-shell">
            <div class="rp-shead">
              <div><span class="rp-crumb">{crumb_html} <i>/</i> Replays <i>/</i> ContactsLive</span><b>Session replay</b></div>
              <span class="rp-drift"><i></i>code unchanged since recording</span>
            </div>
            <div class="rp-blind"><span><b>ContactsLive</b> recorded {started} &middot; {N} frames. Referenced fields show their
              <b>current</b> value, resolved for you now. Typed input is shape only.</span><em>values are CURRENT &middot; resolved on your plane now</em></div>
            <div class="rp-fhead"><div class="rp-stack rp-fl">{"".join(flabels)}</div><div class="rp-stack rp-fd">{"".join(fdetails)}</div></div>
            <div class="rp-screen">
              <div class="rp-app">
                <div class="rp-top">
                  <div class="rp-crumb2">Blue Ridge Logistics <i>/</i> CRM <i>/</i> Contacts</div>
                  <div class="rp-h"><b>Contacts</b><span class="rp-btns"><span class="rp-btn">Show archived</span><span class="rp-btn rp-btn--p x va ve">+ New contact</span></span></div>
                </div>
                <div class="rp-plane x vo vg"><i></i><b>Operator</b><span>Operator plane &middot; masked</span></div>
                <div class="rp-plane rp-plane--t x va ve"><i></i><b>Blue Ridge Logistics</b><span>Tenant plane &middot; in the clear</span></div>
                <div class="rp-list">
                  <div class="rp-gt"><b>Contacts</b><span class="rp-n rp-stack">{count_html}</span><span class="rp-lane">&middot; name / email / phone via PiiResolution &middot; <span class="x vo vg">operator plane &middot; masked</span><span class="x va ve">your org in the clear</span></span><span class="rp-filter">Filter contacts&hellip;</span></div>
                  
                  <div class="rp-card rp-stack">{"".join(screens)}{placeholder_html}</div>
                </div>
              </div>
            </div>
            <div class="rp-refs rp-stack">{"".join(frefs)}</div>
          </div>
        </div>

        <aside class="rp-pg" aria-label="What Postgres holds">
          <div class="rp-pghead">
            <span class="rp-pgk">What Postgres holds</span>
            <b>replay_frame.rpf_payload</b>
            <span class="rp-same"><i></i>same bytes &middot; four viewers</span>
          </div>
          <div class="rp-stack rp-jw">{"".join(fjson)}</div>
          <p class="rp-pgfoot">Switch the viewer: nothing on this side changes &mdash; not one byte, not after the
            erasure either. <b class="j-ref">"$ref"</b> is a pointer the player resolves for whoever is watching;
            <b class="j-red">"$redacted"</b> keeps a kind and a length &mdash; never the text.</p>
        </aside>

        <div class="rp-tl">
          <div class="rp-tlh">
            <span class="rp-tlk">Timeline &middot; {N} frames &middot; 5 interactions</span>
            <span class="rp-auto"><span class="rp-auto-on"><i></i>auto-play &middot; click a frame to pin it</span><label for="rpf-a" class="rp-auto-off">&#9654; resume auto-play</label><span class="rp-auto-rm">auto-play off (reduced motion) &middot; click a frame</span></span>
          </div>
          <div class="rp-track"><span class="rp-head"></span><span class="rp-prog"></span>{"".join(ticks)}</div>
        </div>
      </div>
      <p class="figcap rp-figcap">Real data, redrawn: one session recorded by the ADR-052 recorder over the real ContactsLive
        (fictional Blue Ridge contacts) and replayed by the real player for each viewer. The labels, timestamps, payloads,
        cell text, reference outcomes and audit rows are exported verbatim by
        <code>scripts/landing/replay_demo_export_test.exs</code>; the screen is redrawn in this page&rsquo;s CSS (the
        player shows it in a script-free sandboxed iframe). The recording ran in a scripted test session, hence
        milliseconds. A masked or erased cell shows the player&rsquo;s own placeholder, <span class="rp-m">&#8226;&#8226;&#8226;&#8226;</span>
        or <span class="rp-er">[erased]</span>; &ldquo;&mdash;&rdquo; means there is no value (the contact created in the
        session has no email or phone).</p>

      <div class="rp-audit">
        <div class="rp-auh"><span class="sec-label" style="margin:0">Every open is on the record</span>
          <p class="small">One <code>replay.viewed</code> row per open, on Blue Ridge&rsquo;s audit chain &mdash; ids and a bounded detail, never a value, never a reason text. Stepping through frames writes nothing.</p></div>
        <div class="rp-auscroll"><table>
          <thead><tr><th>viewer</th><th>aud_event_type</th><th>aud_subject_id</th><th>aud_actor_id</th><th>aud_correlation_id</th><th>aud_detail</th></tr></thead>
          <tbody>{"".join(audit_rows)}</tbody>
        </table></div>
        <p class="tiny" style="margin-top:10px">subject = the replay session &middot; actor = the viewer&rsquo;s id &middot; correlation = the operator&rsquo;s impersonation session (tenant views have none)</p>
      </div>
    </div>

    <div class="hr"></div>

    <span class="sec-label">The same session, two ways to keep it</span>
    <h2 style="max-width:22ch">A replay that records by value keeps all of it. <em>This one keeps the shape.</em></h2>
    <div class="split-even rp-vs" style="margin-top:28px">
      <div class="rp-vsl">
        <div class="rp-vsh"><b>A by-value replay stores this</b><span>{N_DISTINCT} plaintext values &middot; {naive_occ} copies in one session</span></div>
        {contrast_left}
      </div>
      <div class="rp-vsr">
        <div class="rp-vsh"><b>Samen stores this</b><span>0 plaintext values &middot; {stored_total:,} bytes of references and shapes</span></div>
        {contrast_right}
      </div>
    </div>
    <p class="small" style="margin-top:16px;max-width:76ch">Left: the same session&rsquo;s real assigns and event params before
      the sanitizer ran &mdash; what keeping them would have stored. Right: the rows Postgres actually holds. Each of the
      {N_DISTINCT} values was checked against every stored string: none is there.</p>

    <div class="g4 rp-proof" style="margin-top:34px">
      <div class="card"><div class="metric">0</div><div class="metric-lab">plaintext values in replay rows</div>
        <p>Vault fields are stored as <code>$ref</code>, freeform text and typed input as a length. A frame with a bare
          string anywhere is refused at write; the <code>:replay</code> tier scans every stored row in CI.</p>
        <p class="tiny">R5&ndash;R7 &middot; sab 421&ndash;423, 429, 438, 483&ndash;485</p></div>
      <div class="card"><div class="metric">Off</div><div class="metric-lab">until the operator opts an org in</div>
        <p>Capture needs the host&rsquo;s replay plane <em>and</em> the org on the operator-owned <code>samen.replay</code>
          flag. An unknown flag is off and an off org&rsquo;s hooks detach. Kept 14 days by default.</p>
        <p class="tiny">R11/R12 &middot; sab 424, 426, 434, 489, 490&ndash;494</p></div>
      <div class="card"><div class="metric">1 row</div><div class="metric-lab">per open &middot; impersonation required</div>
        <p>An operator watches only inside an active impersonation session, re-checked every frame batch; tenants need
          an admin role in that org. No session: nothing renders, nothing is written.</p>
        <p class="tiny">R9/R10 &middot; sab 447&ndash;452</p></div>
      <div class="card"><div class="metric">75</div><div class="metric-lab">sabotages ship with it</div>
        <p>421&ndash;495, each proving a named test fails when its guard breaks. Erasure reaches replays without deleting
          them: the post-shred oracle resolves every stored reference to the erased subject and demands <code>[erased]</code>.</p>
        <p class="tiny">R8 &middot; sab 445, 486&ndash;488 &middot; <code>:post_shred_replay</code></p></div>
    </div>

  </div>
</section>
"""

# --------------------------------------------------------------------------------------------
# CSS

frame_screen = {i: screen_of(i) for i in range(N)}
pin_rules = []
for i in range(N):
    sc = frame_screen[i]
    keep = f".sx:not(.s{sc})" if i not in PLACEHOLDER else f".sx:not(.s{sc}):not(.sP)"
    pin_rules.append(f"#rpf-{i}:checked~* .fx:not(.f{i}),#rpf-{i}:checked~* {keep}{{display:none}}")
    pin_rules.append(f"#rpf-{i}:checked~* .t{i}{{background:var(--rp-tick-on);color:#fff}}#rpf-{i}:checked~* .rp-head{{transform:translateX({i * 100}%)}}")


def pct(x):
    return f"{x * 100 / N:.3f}%"


def window_kf(name, a, b):
    # visible for frames [a, b)
    parts = []
    if a > 0:
        parts.append(f"0%,{pct(a - 0.001)}{{visibility:hidden}}")
    parts.append(f"{pct(a)},{pct(b - 0.001)}{{visibility:visible}}")
    if b < N:
        parts.append(f"{pct(b)},100%{{visibility:hidden}}")
    return f"@keyframes rp-s{name}{{{''.join(parts)}}}"


kfs = [window_kf(n, r.start, r.stop) for n, r in SCREENS.items()] + [window_kf("P", PLACEHOLDER.start, PLACEHOLDER.stop)]

css = f"""
/* ================== SESSION REPLAY (ADR-052) — CSS-only player ==================
   Viewer = radios rpv-*, frame = radios rpf-* (rpf-a = auto-play). Variant spans carry .x + the
   viewers they belong to (.vo .vg .va .ve); per-frame elements .fx.fN; recorded screens .sx.sX.
   Auto-play: 1 s per frame, {T} s loop, keyframed visibility. Reduced motion: frame 1, no loop. */
.rp-sec{{background:radial-gradient(900px 520px at 88% 0%,rgba(59,76,202,.07),transparent 62%),var(--paper)}}
.rp-tag{{margin-top:22px;font-family:var(--mono);font-size:13px;letter-spacing:.04em;color:var(--muted)}}
.rp-tag b{{font-family:var(--display);font-size:24px;font-weight:560;color:var(--ink);margin-right:3px}}
.rp-tag span{{color:var(--rule);margin:0 8px}}
.rp{{position:relative;left:50%;transform:translateX(-50%);width:min(1240px,calc(100vw - 32px));margin-top:38px;
  --rp-o:#3B4CCA;--rp-g:#B4690E;--rp-a:#1B7A5A;--rp-e:#C4443B;--rp-tick-on:#3B4CCA}}
.rp>input{{position:absolute;width:1px;height:1px;opacity:0;pointer-events:none}}
#rpv-o:checked~* .x:not(.vo),#rpv-g:checked~* .x:not(.vg),#rpv-a:checked~* .x:not(.va),#rpv-e:checked~* .x:not(.ve){{display:none}}
.rp-tabs{{display:flex;flex-wrap:wrap;justify-content:center;gap:6px;padding:5px;background:var(--card);border:1px solid var(--rule);border-radius:100px;width:fit-content;margin:0 auto 14px;box-shadow:0 1px 2px rgba(20,22,34,.05)}}
.rp-tab{{cursor:pointer;font-family:var(--mono);font-size:12.5px;letter-spacing:.02em;padding:9px 18px;border-radius:100px;color:var(--muted);white-space:nowrap;display:flex;align-items:center;gap:8px;transition:background .18s ease,color .18s ease}}
.rp-tab:hover{{color:var(--ink)}}
.rp-d{{width:7px;height:7px;border-radius:50%;background:currentColor;opacity:.6;flex:none}}
.rp-tab--o .rp-d{{background:var(--rp-o)}}.rp-tab--g .rp-d{{background:var(--rp-g)}}.rp-tab--a .rp-d{{background:var(--rp-a)}}.rp-tab--e .rp-d{{background:var(--rp-e)}}
#rpv-o:checked~.rp-tabs [for=rpv-o],#rpv-g:checked~.rp-tabs [for=rpv-g],#rpv-a:checked~.rp-tabs [for=rpv-a],#rpv-e:checked~.rp-tabs [for=rpv-e]{{color:#fff}}
#rpv-o:checked~.rp-tabs [for=rpv-o]{{background:var(--rp-o)}}#rpv-g:checked~.rp-tabs [for=rpv-g]{{background:var(--rp-g)}}
#rpv-a:checked~.rp-tabs [for=rpv-a]{{background:var(--rp-a)}}#rpv-e:checked~.rp-tabs [for=rpv-e]{{background:var(--rp-e)}}
.rp-tab .rp-d{{transition:background .18s}}
#rpv-o:checked~.rp-tabs [for=rpv-o] .rp-d,#rpv-g:checked~.rp-tabs [for=rpv-g] .rp-d,#rpv-a:checked~.rp-tabs [for=rpv-a] .rp-d,#rpv-e:checked~.rp-tabs [for=rpv-e] .rp-d{{background:#fff;opacity:1}}
.rp>input[name=rpv]:focus-visible~.rp-tabs{{outline:2px solid var(--accent);outline-offset:4px}}
.rp>input[name=rpf]:focus-visible~.rp-stage .rp-track{{outline:2px solid #A8B2F5;outline-offset:3px}}
.rp-caps{{max-width:76ch;margin:0 auto 22px;text-align:center;font-size:15px;line-height:1.55;color:var(--muted);min-height:3.2em}}
.rp-caps b{{color:var(--ink)}}
.rp-stage{{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,400px);grid-template-areas:"win pg" "tl tl";gap:14px;background:var(--night);border-radius:22px;padding:clamp(10px,1.4vw,16px);
  box-shadow:0 2px 4px rgba(14,15,22,.08),0 40px 90px -40px rgba(14,15,22,.55);color:var(--night-ink)}}
.rp-stage>*{{min-width:0}}
.rp-stack{{display:grid}}.rp-stack>*{{grid-area:1/1;min-width:0}}
/* ---- the player window ---- */
.rp-win{{grid-area:win;background:var(--card);border-radius:14px;overflow:hidden;color:var(--ink);display:flex;flex-direction:column}}
.rp-bar{{display:flex;align-items:center;gap:7px;padding:10px 14px;background:#F3F2EE;border-bottom:1px solid var(--rule)}}
.rp-bar>i{{width:9px;height:9px;border-radius:50%;background:#DDDAD2;flex:none}}
.rp-url{{font-family:var(--mono);font-size:11.5px;color:var(--faint);margin-left:8px;background:#fff;border:1px solid var(--rule);border-radius:7px;padding:4px 10px;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
.rp-url span::before{{content:"\\1F512\\FE0E  ";filter:grayscale(1);opacity:.55}}
.rp-shell{{padding:12px 14px;display:flex;flex-direction:column;gap:9px;flex:1}}
.rp-shead{{display:flex;align-items:flex-end;justify-content:space-between;gap:12px;flex-wrap:wrap}}
.rp-shead b{{display:block;font-size:17px;font-weight:650;letter-spacing:-.02em}}
.rp-crumb{{font-size:11.5px;color:var(--faint)}}.rp-crumb i,.rp-crumb2 i{{font-style:normal;opacity:.5;margin:0 4px}}
.rp-drift{{font-size:11.5px;font-weight:550;color:var(--uc-green);background:var(--uc-green-wash);border-radius:100px;padding:3px 10px;display:inline-flex;align-items:center;gap:6px}}
.rp-drift i{{width:6px;height:6px;border-radius:50%;background:currentColor}}
.rp-blind{{display:flex;align-items:center;gap:12px;padding:8px 12px;border-radius:10px;background:var(--uc-brand-wash);border:1px solid #DCE0FA;font-size:11.5px;color:#37407A;line-height:1.4}}
.rp-blind b{{color:#28306B}}
.rp-blind em{{margin-left:auto;font-style:normal;font-family:var(--mono);font-size:10.5px;background:#fff;border:1px solid #DCE0FA;border-radius:7px;padding:4px 8px;white-space:nowrap}}
.rp-fhead{{display:flex;flex-direction:column;gap:4px;border-top:1px solid var(--rule-soft);padding-top:10px}}
.rp-fl{{font-family:var(--mono);font-size:12.5px;color:var(--ink)}}
.rp-fl i{{font-style:normal;color:var(--faint)}}
.rp-k{{font-weight:600;padding:1px 7px;border-radius:5px;background:var(--rule-soft);margin-right:2px}}
.rp-k--event{{background:#1B1C22;color:#fff}}
.rp-fd{{font-size:12px;color:var(--muted);line-height:1.5;min-height:1.5em;max-height:50px;overflow:hidden}}
#rpf-a:not(:checked)~* .rp-fd{{max-height:none}}
.rp-fd b{{color:var(--ink);font-weight:600}}
.rp-fd code{{font-size:11px}}
.rp-sh{{display:inline-block;font-family:var(--mono);font-size:11px;background:#F4F3EF;border:1px solid var(--rule);border-radius:6px;padding:1px 7px;margin:2px 4px 2px 0;color:var(--muted)}}
.rp-sh b{{font-weight:600}}
.rp-kept{{color:var(--good)!important}}
.rp-pfx{{font-family:var(--mono);font-size:11px;color:var(--faint);margin-right:2px}}
.rp-typed{{font-family:var(--mono);font-size:10.5px;letter-spacing:.06em;text-transform:uppercase;color:var(--reveal);margin-right:8px}}
/* the recorded screen (ContactsLive), redrawn */
.rp-screen{{--uc-line2:#E3E3E8;padding:8px;border-radius:12px;background:var(--uc-canvas);border:1px solid var(--rule);color:var(--uc-ink);font-size:13px;line-height:1.45}}
.rp-app{{background:var(--uc-card);border:1px solid var(--uc-line);border-radius:10px;overflow:hidden}}
.rp-top{{padding:12px 16px 0}}
.rp-crumb2{{font-size:11.5px;color:var(--uc-faint);margin-bottom:6px}}
.rp-h{{display:flex;align-items:center;gap:10px;flex-wrap:wrap}}
.rp-h>b{{font-size:18px;font-weight:650;letter-spacing:-.025em}}
.rp-btns{{margin-left:auto;display:flex;gap:6px}}
.rp-btn{{font-size:11.5px;font-weight:550;border:1px solid var(--uc-line2);border-radius:8px;padding:5px 10px;white-space:nowrap}}
.rp-btn--p{{background:#1B1C22;border-color:#1B1C22;color:#fff}}
.rp-plane{{margin:10px 16px 0;display:flex;align-items:center;gap:8px;font-size:11.5px;padding:7px 11px;border-radius:9px;background:var(--uc-brand-wash);border:1px solid #DCE0FA;color:#37407A}}
.rp-plane i{{width:7px;height:7px;border-radius:50%;background:var(--uc-brand)}}
.rp-plane span{{margin-left:auto;font-family:var(--mono);font-size:10.5px}}
.rp-plane--t{{background:var(--uc-green-wash);border-color:#CBE7D5;color:#215938}}.rp-plane--t i{{background:var(--uc-green)}}
.rp-list{{padding:10px 16px 14px}}
.rp-gt{{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:9px}}
.rp-gt>b{{font-size:13px;font-weight:600}}
.rp-n{{font-size:11px;font-weight:600;color:var(--uc-muted);background:#F1F1F4;border-radius:20px;padding:1px 8px;min-width:22px;text-align:center}}
.rp-lane{{font-size:11.5px;color:var(--uc-faint)}}
.rp-filter{{margin-left:auto;font-size:11.5px;color:var(--uc-faint);border:1px solid var(--uc-line2);border-radius:8px;padding:4px 10px;width:170px;max-width:100%}}
.rp-card{{border:1px solid var(--uc-line2);border-radius:10px;overflow:hidden;background:var(--uc-card)}}
.rp-card table{{width:100%;border-collapse:collapse;table-layout:fixed}}
.rp-card th{{text-align:left;font-size:10.5px;font-weight:550;color:var(--uc-faint);padding:7px 9px;border-bottom:1px solid var(--uc-line);white-space:nowrap}}
.rp-card td{{padding:6px 9px;border-bottom:1px solid var(--uc-line);font-size:12px;vertical-align:middle;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:11.5px}}
.rp-card tr:last-child td{{border-bottom:0}}
.rp-card .rp-nm{{width:23%}}.rp-card .rp-em{{width:29%}}.rp-card .rp-ph{{width:14%}}.rp-card .rp-co{{width:11%}}.rp-card .rp-ti{{width:11%}}.rp-card .rp-act{{width:12%}}
.rp-nmw{{display:flex;align-items:center;gap:7px;min-width:0}}.rp-nmw>span{{overflow:hidden;text-overflow:ellipsis}}
.rp-av{{width:22px;height:22px;border-radius:50%;background:#DDE7F5;color:#3B4CCA;font-size:9px;font-weight:700;font-style:normal;display:inline-grid;place-items:center;flex:none}}
.rp-av--q{{background:repeating-linear-gradient(115deg,#E1E3EC 0 4px,#ECEDF3 4px 8px);color:#9A9BA6}}
.rp-c{{color:var(--uc-ink)}}td.rp-nm .rp-c{{color:#3B4CCA;font-weight:500}}
.rp-rev{{background:var(--reveal-wash);box-shadow:0 0 0 1px var(--reveal-line);border-radius:4px;padding:0 3px;color:var(--reveal)!important}}
.rp-m{{font-family:var(--mono);letter-spacing:.14em;color:#8C8D99;background:var(--rule-soft);border-radius:5px;padding:1px 6px;font-size:11px}}
.rp-er{{font-family:var(--mono);font-size:10.5px;letter-spacing:.06em;color:#8E2A22;background:repeating-linear-gradient(135deg,#FBECEA 0 6px,#F6DEDB 6px 12px);border:1px dashed #E2A59F;border-radius:5px;padding:1px 6px}}
.rp-r{{font-family:var(--mono);font-size:10.5px;color:#A3A4AE;letter-spacing:0}}
.rp-no{{color:#B5B6BF}}
.rp-del{{font-size:10px;color:#b91c1c;border:1px solid #E7B4B4;border-radius:6px;padding:2px 6px}}
.rp-sr{{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}}
.rp-count{{display:none}}
.rp-ph-card{{background:repeating-linear-gradient(135deg,#FBFBFC 0 10px,#F5F5F7 10px 20px);padding:22px clamp(18px,6%,60px);display:flex;flex-direction:column;gap:8px;justify-content:center;align-items:center;text-align:center;font-size:12.5px;color:var(--uc-muted);z-index:1;outline:1px dashed #D3D4DC;outline-offset:-10px;border-radius:10px}}
.rp-ph-card span{{max-width:56ch}}
.rp-ph-card b{{color:var(--uc-ink);font-weight:550}}
.rp-refs{{font-size:11.5px}}
.rp-refs>span>span{{display:inline-flex;align-items:center;gap:6px;margin:2px 6px 2px 0;vertical-align:middle}}
.rp-refn{{font-family:var(--mono);color:var(--faint);font-size:11px!important}}.rp-refn b{{color:var(--ink)}}
.rp-pill{{font-weight:550;padding:2px 9px;border-radius:100px;font-size:11px;white-space:nowrap}}
.rp-pill i{{width:6px;height:6px;border-radius:50%;background:currentColor}}
.rp-pill.ok{{background:var(--uc-green-wash);color:var(--uc-green)}}.rp-pill.mut{{background:#F1F1F4;color:var(--uc-muted)}}
.rp-pill.bad{{background:var(--uc-red-wash);color:var(--uc-red)}}.rp-pill.warn{{background:var(--uc-amber-wash);color:var(--uc-amber)}}
/* ---- what Postgres holds ---- */
.rp-pg{{grid-area:pg;background:var(--night-2);border:1px solid var(--night-rule);border-radius:14px;display:flex;flex-direction:column;min-height:0;overflow:hidden}}
.rp-pghead{{padding:14px 16px 12px;border-bottom:1px solid var(--night-rule);display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px}}
.rp-pgk{{width:100%;font-family:var(--mono);font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:var(--night-faint)}}
.rp-pghead>b{{font-family:var(--mono);font-size:13px;font-weight:500;color:var(--night-ink)}}
.rp-same{{margin-left:auto;font-family:var(--mono);font-size:10.5px;color:#5FD3A0;border:1px solid #23503F;background:#11251E;border-radius:100px;padding:3px 9px;display:inline-flex;align-items:center;gap:6px;white-space:nowrap}}
.rp-same i{{width:6px;height:6px;border-radius:50%;background:#5FD3A0;box-shadow:0 0 0 3px rgba(95,211,160,.18)}}
.rp-jw{{flex:1;min-height:420px;position:relative;display:block}}
.rp-jw>.rp-jf{{position:absolute;inset:0;display:flex;flex-direction:column;min-height:0}}
.rp-jmeta{{display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap;padding:9px 16px;font-family:var(--mono);font-size:10.5px;color:var(--night-faint);border-bottom:1px dashed var(--night-rule)}}
.rp-jmeta b{{color:var(--night-muted);font-weight:500}}
.rp-sha b{{color:#A8B2F5!important}}
.rp-json{{margin:0;padding:12px 16px 16px;font-family:var(--mono);font-size:11.2px;line-height:1.62;color:#8C90A8;white-space:pre-wrap;overflow-wrap:anywhere;overflow:auto;flex:1;min-height:0;tab-size:2}}
.rp-json i,.rp-vs i{{font-style:normal}}
.rp-json>b,.rp-jl>b{{display:block;font-weight:400;padding-left:calc(var(--dd,0) * 1.6ch + 2.2ch);text-indent:-2.2ch}}
{''.join(f'.j{n}{{--dd:{n}}}' for n in range(13))}
.rp-json .e,.rp-vs .e{{color:var(--night-faint);font-style:italic}}
.rp-json .s,.rp-vs .s{{color:#B5E3C8}}.rp-json .n,.rp-vs .n{{color:#F0C27B}}.rp-json .l,.rp-vs .l{{color:#E59A92}}.rp-json .m,.rp-vs .m{{color:#9AA4E8}}
.ref,.j-ref{{color:#fff;background:#3B4CCA;border-radius:4px;padding:0 3px;font-weight:600}}
.red,.j-red{{color:#1A1405;background:#E8B86B;border-radius:4px;padding:0 3px;font-weight:600}}
.shp{{color:#fff;background:#6D45C4;border-radius:4px;padding:0 3px;font-weight:600}}
.j-el{{color:var(--night-faint);font-style:italic}}
.rp-pgfoot{{margin:0;padding:12px 16px 14px;border-top:1px solid var(--night-rule);font-size:12.5px;line-height:1.5;color:var(--night-muted)!important}}
.rp-pgfoot b{{font-family:var(--mono);font-size:11px}}
/* ---- timeline ---- */
.rp-tl{{grid-area:tl;padding:4px 2px 2px}}
.rp-tlh{{display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap;font-family:var(--mono);font-size:11px;letter-spacing:.06em;color:var(--night-faint);margin:2px 4px 10px;text-transform:uppercase}}
.rp-auto label{{cursor:pointer;color:#A8B2F5}}
.rp-auto-on i{{display:inline-block;width:7px;height:7px;border-radius:50%;background:#5FD3A0;margin-right:7px;animation:rp-pulse 1.4s ease-in-out infinite}}
.rp-auto-off,.rp-auto-rm{{display:none}}
#rpf-a:not(:checked)~.rp-stage .rp-auto-on{{display:none}}#rpf-a:not(:checked)~.rp-stage .rp-auto-off{{display:inline}}
.rp-track{{position:relative;display:grid;grid-template-columns:repeat({N},minmax(0,1fr));gap:4px;border-radius:12px}}
.rp-head{{position:absolute;left:0;top:0;bottom:0;border-radius:10px;background:var(--rp-tick-on);box-shadow:0 6px 20px -6px rgba(59,76,202,.8);transition:transform .25s cubic-bezier(.2,.6,.2,1);animation:rp-head {T}s steps({N},end) infinite;pointer-events:none}}
.rp-head{{width:calc(100% / {N})}}
.rp-prog{{position:absolute;left:0;right:0;bottom:-6px;height:2px;background:#5FD3A0;transform-origin:0 50%;animation:rp-prog {T}s linear infinite;border-radius:2px;opacity:.75}}
.rp-tick{{position:relative;cursor:pointer;padding:8px 6px 9px;border-radius:10px;background:transparent;border:1px solid var(--night-rule);font-family:var(--mono);min-width:0;display:flex;flex-direction:column;gap:1px;color:var(--night-ink);transition:border-color .15s,color .15s;z-index:1}}
.rp-tick:hover{{border-color:#7C86E8}}
.rp-tick b{{font-size:10px;font-weight:500;opacity:.55}}
.rp-tick span{{font-size:11.5px;font-weight:500}}
.rp-tick i{{font-style:normal;font-size:10px;opacity:.6;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
.rp-tk--event{{border-color:#3A4180}}.rp-tk--event span::before{{content:"";display:inline-block;width:6px;height:6px;border-radius:50%;background:#F0C27B;margin-right:5px;vertical-align:1px}}
.rp-tick{{animation:rp-tick {T}s infinite;animation-delay:calc(var(--i) * 1s)}}
@keyframes rp-tick{{0%,7.1%{{color:#fff;border-color:#7C86E8}}7.15%,100%{{color:var(--night-ink)}}}}
@keyframes rp-head{{from{{transform:translateX(0)}}to{{transform:translateX({N * 100}%)}}}}
@keyframes rp-prog{{from{{transform:scaleX(0)}}to{{transform:scaleX(1)}}}}
@keyframes rp-pulse{{50%{{opacity:.35}}}}
/* auto-play: per-frame + per-screen visibility */
.rp .fx{{visibility:hidden;animation:rp-f {T}s infinite;animation-delay:calc(var(--i) * 1s)}}
@keyframes rp-f{{0%,{100 / N - 0.01:.3f}%{{visibility:visible}}{100 / N:.3f}%,100%{{visibility:hidden}}}}
{''.join(kfs)}
.rp .sx{{visibility:hidden}}
.rp .sA{{animation:rp-sA {T}s infinite}}.rp .sB{{animation:rp-sB {T}s infinite}}.rp .sP{{animation:rp-sP {T}s infinite}}.rp .sC{{animation:rp-sC {T}s infinite}}.rp .sD{{animation:rp-sD {T}s infinite}}
/* pinned frame */
#rpf-a:not(:checked)~* .fx,#rpf-a:not(:checked)~* .sx{{animation:none;visibility:visible}}
#rpf-a:not(:checked)~* .rp-head,#rpf-a:not(:checked)~* .rp-tick{{animation:none}}
#rpf-a:not(:checked)~* .rp-prog{{animation:none;opacity:0}}
{''.join(pin_rules)}
@media(prefers-reduced-motion:reduce){{
  .rp .fx,.rp .sx,.rp .rp-head,.rp .rp-tick,.rp .rp-prog,.rp-auto-on i{{animation:none!important}}
  #rpf-a:checked~* .fx:not(.f0),#rpf-a:checked~* .sx:not(.sA){{display:none}}
  #rpf-a:checked~* .fx.f0,#rpf-a:checked~* .sx.sA{{visibility:visible}}
  #rpf-a:checked~* .t0{{background:var(--rp-tick-on);color:#fff}}
  .rp-prog{{display:none}}
  #rpf-a:checked~.rp-stage .rp-auto-on{{display:none}}#rpf-a:checked~.rp-stage .rp-auto-rm{{display:inline}}
  .rp-tab,.rp-head{{transition:none}}
}}
/* audit strip */
.rp-figcap{{max-width:100ch;margin:16px auto 0;text-align:left;font-family:var(--body);font-size:13px;letter-spacing:0;line-height:1.55;color:var(--muted)}}
.rp-figcap code{{font-size:.95em}}
.rp-audit{{margin-top:30px;background:var(--card);border:1px solid var(--rule);border-radius:14px;padding:18px 20px}}
.rp-auh{{display:flex;flex-wrap:wrap;gap:6px 18px;align-items:baseline;margin-bottom:12px}}
.rp-auh .small{{font-size:14px;max-width:80ch}}
.rp-auscroll{{overflow-x:auto}}
.rp-audit table{{width:100%;border-collapse:collapse;font-size:12px;min-width:760px}}
.rp-audit th,.rp-audit td{{text-align:left;padding:8px 10px;border-bottom:1px solid var(--rule-soft);white-space:nowrap}}
.rp-audit thead th{{font-family:var(--mono);font-size:10.5px;font-weight:500;color:var(--faint);letter-spacing:.04em}}
.rp-audit tbody th{{font-weight:550;font-size:12.5px}}
.rp-audit code{{font-size:11px;background:transparent;padding:0;color:var(--muted)}}
.rp-audit tr.ar{{transition:background .18s}}
#rpv-o:checked~* .ar-o,#rpv-g:checked~* .ar-g,#rpv-a:checked~* .ar-a,#rpv-e:checked~* .ar-e{{background:var(--accent-wash)}}
#rpv-o:checked~* .ar-o th,#rpv-g:checked~* .ar-g th,#rpv-a:checked~* .ar-a th,#rpv-e:checked~* .ar-e th{{box-shadow:inset 3px 0 0 var(--accent)}}
/* contrast */
.rp-vs{{align-items:start}}
.rp-vs>div{{border-radius:14px;padding:18px 20px;min-width:0}}
.rp-vsl{{background:#FFF8F7;border:1px solid #F1CFCB}}
.rp-vsr{{background:var(--night);border:1px solid var(--night-rule);color:var(--night-ink)}}
.rp-vsh{{display:flex;flex-direction:column;gap:2px;margin-bottom:10px}}
.rp-vsh b{{font-size:15px;font-weight:600}}
.rp-vsh span{{font-family:var(--mono);font-size:11.5px;letter-spacing:.03em}}
.rp-vsl .rp-vsh b{{color:#8E2A22}}.rp-vsl .rp-vsh span{{color:#C4443B}}
.rp-vsr .rp-vsh span{{color:#5FD3A0}}
.rp-vs pre{{margin:0 0 6px;font-family:var(--mono);font-size:11.2px;line-height:1.6;white-space:pre-wrap;overflow-wrap:anywhere}}
.rp-vsl pre{{color:#6A4744}}
.rp-vsl s{{color:#B42318;background:#FDE3E0;text-decoration-thickness:1.5px;text-decoration-color:#C4443B;border-radius:3px;padding:0 2px}}
.rp-vsr pre{{color:#8C90A8}}
.rp-cm{{font-family:var(--mono);font-size:10.5px;margin:12px 0 4px;letter-spacing:.02em}}
.rp-vsl .rp-cm{{color:#B98A86}}.rp-vsr .rp-cm{{color:var(--night-faint)!important}}
.rp-proof .card p{{font-size:14.5px}}
.rp-proof .metric{{font-size:clamp(30px,3.6vw,44px)}}
.rp-proof .tiny{{margin-top:12px;color:var(--accent-deep)}}
/* ---- responsive ---- */
@media(max-width:1000px){{
  .rp-stage{{grid-template-columns:minmax(0,1fr);grid-template-areas:"win" "tl" "pg"}}
  .rp-jw{{height:460px;flex:none}}
}}
@media(max-width:860px){{
  .rp-track{{grid-template-columns:repeat(7,minmax(0,1fr))}}
  .rp-head,.rp-prog{{display:none}}
  #rpf-a:checked~* .rp-tick{{animation:rp-tickm {T}s infinite;animation-delay:calc(var(--i) * 1s)}}
}}
@keyframes rp-tickm{{0%,7.1%{{background:var(--rp-tick-on);color:#fff}}7.15%,100%{{background:var(--night-2)}}}}
@media(max-width:640px){{
  .rp-track{{grid-template-columns:repeat(4,minmax(0,1fr))}}
  .rp-tick span{{font-size:10.5px}}
  .rp-tab{{letter-spacing:0}}
  .rp-tabs{{display:grid;grid-template-columns:1fr 1fr;border-radius:16px;width:100%}}
  .rp-tab{{justify-content:center;padding:9px 6px;font-size:11px;border-radius:12px}}
  .rp-blind{{flex-direction:column;align-items:flex-start;gap:6px}}.rp-blind em{{margin-left:0}}
  .rp-shell{{padding:12px 10px}}
  .rp-top{{padding:12px 12px 0}}.rp-plane{{margin:10px 12px 0}}.rp-list{{padding:10px 12px 12px}}
  .rp-card thead{{display:none}}
  .rp-card table,.rp-card tbody{{display:block}}
  .rp-card tr{{display:grid;grid-template-columns:auto minmax(0,1fr) auto;grid-template-areas:"nm nm act" "em em ph" "co ti ti";gap:3px 10px;padding:9px 10px;border-bottom:1px solid var(--uc-line)}}
  .rp-card tr:last-child{{border-bottom:0}}
  .rp-card td{{border:0;padding:0;width:auto!important;display:block}}
  .rp-card td.rp-nm{{grid-area:nm}}.rp-card td.rp-em{{grid-area:em}}.rp-card td.rp-ph{{grid-area:ph;text-align:right}}
  .rp-card td.rp-co{{grid-area:co}}.rp-card td.rp-ti{{grid-area:ti;text-align:right}}.rp-card td.rp-act{{grid-area:act;text-align:right}}
  .rp-filter{{width:100%;margin-left:0}}
  .rp-tag b{{font-size:20px}}
}}
@media(max-width:400px){{.rp{{width:calc(100vw - 20px)}}.rp-stage{{border-radius:16px;padding:8px}}}}
"""

open(f"{out}/replay.css", "w").write(css)
open(f"{out}/replay.html", "w").write(section)

if len(sys.argv) > 3:
    # Splice into the landing page. Both outputs carry their own leading newline: the CSS block
    # runs from the newline before its banner to </style>; the section from the newline before its
    # banner comment to the blank line before "<!-- 08-generate -->".
    page_path = sys.argv[3]
    page = open(page_path, encoding="utf-8").read()
    c0 = page.index("/* ================== SESSION REPLAY (ADR-052)") - 1
    c1 = page.index("</style>", c0)
    assert page[c0] == "\n" and css.startswith("\n") and section.startswith("\n"), "splice anchors"
    page = page[:c0] + css + page[c1:]
    h0 = page.index("<!-- ======================= SESSION REPLAY (ADR-052)") - 1
    h1 = page.index("\n<!-- 08-generate -->", h0)
    assert page[h0] == "\n", "splice anchors"
    page = page[:h0] + section + page[h1:]
    assert "<script" not in page
    open(page_path, "w", encoding="utf-8").write(page)
    print("spliced", page_path, len(page.encode()))
print("distinct", N_DISTINCT, "occ", naive_occ, "css", len(css.encode()), "html", len(section.encode()))
print(sorted(people_strings))

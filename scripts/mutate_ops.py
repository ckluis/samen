#!/usr/bin/env python3
# scripts/mutate_ops.py -- the PARSE half of the mutation-testing engine (scripts/mutate.sh).
#
# This helper does ONE job: given a source file, an ANCHOR regex that uniquely names a
# function-clause's opening line, and a comma-separated list of OPERATORS, it enumerates
# every mutable site in that clause and materialises one full mutated copy of the file per
# site into <outdir>/NNN.mut. It prints a TSV index to stdout, one row per mutant:
#
#     NNN <TAB> <operator> <TAB> <file>:<line> <TAB> <human description>
#
# plus a single leading `ANCHOR <TAB> <file>:<start>-<end>` row for logging. It NEVER
# touches the target file itself -- the shell owns snapshot/restore/exit-code/accounting,
# the invariants that must not live in a language where a verdict can be silently corrupted.
# A mutation that yields non-compiling Elixir is not this helper's problem: the shell runs a
# compile step and classifies it STILLBORN. So an operator here errs toward ATTEMPTING a
# mutation and letting the compiler judge, never toward silent skips that hide a live guard.
#
# ---- THE OPERATOR SET (the declared list; add a fifth without touching the engine) --------
# The four operators are the shapes THIS project shipped unproven:
#   drop-conjunct    `A and B` -> `A`  (and, symmetrically, -> `B`). CF-17(c) exactly:
#                    context_gate's `... > max and foldable(views, lines) == []` losing an arm.
#   flip-comparison  >  <->  <= ,  <  <->  >= ,  ==  <->  != .
#   force-guard      an if/unless/while condition replaced by `true`, then by `false`.
#   tuple-arm        a pattern-match arm's body replaced by a passthrough of what it bound
#                    (the dispatch/4 / SILENT-FLATTEN shape: an arm that stops normalising).
# A fifth operator is a function registered in OPERATORS below + a name in OPERATOR_ORDER.
# `generate` iterates the registry; the engine core never changes.

import os
import re
import sys

# --------------------------------------------------------------------------------------------
# Operator implementations. Each takes (lines, a, e): the full list of source lines (each
# still carrying its trailing "\n") and the inclusive 0-based [a, e] index range of the
# target clause. Each returns a list of (line_1based, description, new_lines) tuples, where
# new_lines is a FULL copy of `lines` with the mutation applied -- so materialisation is
# byte-exact everywhere the operator did not deliberately change.
# --------------------------------------------------------------------------------------------

def _is_comment(line):
    return line.lstrip().startswith("#")


def op_drop_conjunct(lines, a, e):
    out = []
    for i in range(a, e + 1):
        if _is_comment(lines[i]):
            continue
        c = lines[i].rstrip("\n")
        stripped = c.rstrip()

        # ---- trailing form: the line ENDS with ` and` / ` or`, right operand on line j ----
        m = re.search(r"\s+(and|or)\s*$", stripped)
        if m and re.search(r"\S", stripped[: m.start()]):
            op = m.group(1)
            left = stripped[: m.start()]           # indent + LEFT operand (maybe + keyword)
            j = i + 1
            while j <= e and lines[j].strip() == "":
                j += 1
            if j > e:
                continue
            rstr = lines[j].rstrip("\n").strip()
            opener = ""
            rcond = rstr
            if rstr == "do":
                opener, rcond = " do", ""
            elif rstr.endswith(" do"):
                opener = " do"
                rcond = re.sub(r"\s+do\s*$", "", rstr)

            # keep-left: drop the RIGHT conjunct (this is the CF-17(c) survivor).
            nl = list(lines)
            nl[i] = left + opener + "\n"
            del nl[j]
            out.append((i + 1,
                        "drop-conjunct: keep LEFT, drop `%s %s`" % (op, rcond or rstr),
                        nl))

            # keep-right: drop the LEFT conjunct -- only when the left line opens with a
            # control keyword we can safely re-use, else the fragment cannot stand alone.
            indent = re.match(r"^(\s*)", left).group(1)
            kwm = re.match(r"^\s*(if|unless|while)\b", left)
            if kwm and rcond:
                kw = kwm.group(1)
                nl2 = list(lines)
                nl2[i] = "%s%s %s%s\n" % (indent, kw, rcond, opener)
                del nl2[j]
                out.append((i + 1,
                            "drop-conjunct: keep RIGHT `%s`, drop LEFT" % rcond,
                            nl2))
            continue

        # ---- inline form: `LEFT and RIGHT` with real operands on both sides, one line ----
        im = re.search(r"\s(and|or)\s", c)
        if im:
            op = im.group(1)
            before, after = c[: im.start()], c[im.end():]
            if re.search(r"\S", before) and re.search(r"\S", after):
                indent = re.match(r"^(\s*)", c).group(1)
                opener = ""
                after_cond = after.rstrip()
                if after_cond.endswith(" do"):
                    opener = " do"
                    after_cond = re.sub(r"\s+do\s*$", "", after_cond)
                nl = list(lines)
                nl[i] = before.rstrip() + opener + "\n"
                out.append((i + 1, "drop-conjunct: inline keep LEFT, drop after `%s`" % op, nl))
                kwm = re.match(r"^\s*(if|unless|while)\b", before)
                if kwm:
                    kw = kwm.group(1)
                    nl2 = list(lines)
                    nl2[i] = "%s%s %s%s\n" % (indent, kw, after_cond.strip(), opener)
                    out.append((i + 1, "drop-conjunct: inline keep RIGHT, drop before `%s`" % op, nl2))
    return out


_CMP = re.compile(r"(?<![<>=!~|+\-*/])(>=|<=|==|!=|>|<)(?![=><~\-|])")
_FLIP = {">": "<=", "<": ">=", ">=": "<", "<=": ">", "==": "!=", "!=": "=="}


def op_flip_comparison(lines, a, e):
    out = []
    for i in range(a, e + 1):
        if _is_comment(lines[i]):
            continue
        c = lines[i].rstrip("\n")
        for m in _CMP.finditer(c):
            op = m.group(1)
            rep = _FLIP[op]
            nl = list(lines)
            nl[i] = c[: m.start()] + rep + c[m.end():] + "\n"
            out.append((i + 1, "flip-comparison: `%s` -> `%s`" % (op, rep), nl))
    return out


def op_force_guard(lines, a, e):
    out = []
    for i in range(a, e + 1):
        if _is_comment(lines[i]):
            continue
        c = lines[i].rstrip("\n")
        km = re.match(r"^(\s*)(if|unless|while)\b", c)
        if not km:
            continue
        indent, kw = km.group(1), km.group(2)

        # one-liner: `if cond, do: X` (keyword form)
        mm = re.match(r"^(\s*)(if|unless|while)\s+(.*?),\s*do:(.*)$", c)
        if mm:
            for val in ("true", "false"):
                nl = list(lines)
                nl[i] = "%s%s %s, do:%s\n" % (indent, kw, val, mm.group(4))
                out.append((i + 1, "force-guard: %s condition -> %s" % (kw, val), nl))
            continue

        # block form: find the (first) line carrying the `do` opener of THIS if.
        do_i = None
        for j in range(i, e + 1):
            if re.search(r"\bdo\s*$", lines[j].rstrip("\n")):
                do_i = j
                break
        if do_i is None:
            continue
        for val in ("true", "false"):
            nl = list(lines[:i]) + ["%s%s %s do\n" % (indent, kw, val)] + list(lines[do_i + 1:])
            out.append((i + 1, "force-guard: %s condition -> %s" % (kw, val), nl))
    return out


def op_tuple_arm(lines, a, e):
    out = []
    for i in range(a, e + 1):
        if _is_comment(lines[i]):
            continue
        c = lines[i].rstrip("\n")
        if "->" not in c:
            continue
        idx = c.find("->")
        lhs = c[:idx].rstrip()
        rhs = c[idx + 2:].strip()
        if rhs == "" or lhs == "":
            continue  # multi-line body / typespec-ish; leave alone (safe)
        indent = re.match(r"^(\s*)", c).group(1)
        lhs_core = re.split(r"\bwhen\b", lhs)[0].strip()

        passthrough = None
        eqm = re.search(r"=\s*([a-z_][A-Za-z0-9_]*)\s*$", lhs_core)
        if eqm:                                            # PATTERN = binding  -> binding
            passthrough = eqm.group(1)
        else:
            tm = re.match(r"^\{([^,{}]+),\s*([^{}]+)\}$", lhs_core)
            if tm:                                         # {tag, elem} -> {tag, elem} raw
                passthrough = "{%s, %s}" % (tm.group(1).strip(), tm.group(2).strip())
            else:
                vm = re.match(r"^([a-z_][A-Za-z0-9_]*)$", lhs_core)
                if vm:                                     # catch-all var -> var
                    passthrough = vm.group(1)
        if passthrough is None or passthrough == rhs:
            continue
        nl = list(lines)
        nl[i] = "%s%s -> %s\n" % (indent, lhs, passthrough)
        out.append((i + 1, "tuple-arm: replace body with passthrough `%s`" % passthrough, nl))
    return out


# ---- the declared registry. A fifth operator: add a function + these two lines. ------------
OPERATOR_ORDER = ["drop-conjunct", "flip-comparison", "force-guard", "tuple-arm"]
OPERATORS = {
    "drop-conjunct": op_drop_conjunct,
    "flip-comparison": op_flip_comparison,
    "force-guard": op_force_guard,
    "tuple-arm": op_tuple_arm,
}


def find_clause(lines, anchor_regex):
    rx = re.compile(anchor_regex)
    a = None
    for i, line in enumerate(lines):
        if rx.search(line.rstrip("\n")):
            a = i
            break
    if a is None:
        return None
    indent = re.match(r"^(\s*)", lines[a]).group(1)
    end_rx = re.compile(r"^" + re.escape(indent) + r"end\b")
    for j in range(a + 1, len(lines)):
        if end_rx.match(lines[j].rstrip("\n")):
            return (a, j)
    return (a, len(lines) - 1)


def cmd_generate(path, anchor_regex, ops_csv, outdir):
    with open(path, "r") as fh:
        lines = fh.readlines()
    clause = find_clause(lines, anchor_regex)
    if clause is None:
        sys.stderr.write("mutate_ops: anchor /%s/ not found in %s\n" % (anchor_regex, path))
        return 2
    a, e = clause
    print("ANCHOR\t%s:%d-%d" % (path, a + 1, e + 1))

    requested = [o.strip() for o in ops_csv.split(",") if o.strip()]
    for o in requested:
        if o not in OPERATORS:
            sys.stderr.write("mutate_ops: unknown operator '%s'\n" % o)
            return 2

    os.makedirs(outdir, exist_ok=True)
    seq = 0
    seen = set()
    for op in OPERATOR_ORDER:
        if op not in requested:
            continue
        for (line1, desc, new_lines) in OPERATORS[op](lines, a, e):
            blob = "".join(new_lines)
            if blob in seen:
                continue          # never emit a mutant byte-identical to another (or origin)
            seen.add(blob)
            if blob == "".join(lines):
                continue          # a no-op is not a mutant
            seq += 1
            with open(os.path.join(outdir, "%03d.mut" % seq), "w") as out:
                out.write(blob)
            print("%03d\t%s\t%s:%d\t%s" % (seq, op, path, line1, desc))
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "list-operators":
        for o in OPERATOR_ORDER:
            print(o)
        return 0
    if len(argv) == 6 and argv[1] == "generate":
        return cmd_generate(argv[2], argv[3], argv[4], argv[5])
    sys.stderr.write(
        "usage: mutate_ops.py generate <file> <anchor_regex> <ops_csv> <outdir>\n"
        "       mutate_ops.py list-operators\n")
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))

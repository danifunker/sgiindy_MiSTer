"""classify.py KEY - decide which base roots are the REX3 window.

Evidence levels (strongest first):
  abs      the address is a constant inside a REX3 window
  strong   a function's accesses through one root are all REX3 register
           offsets and look like REX3 (GO alias, 0x13xx page, DCB pair, or
           >= 3 offsets over >= 2 register banks) - census.strength()
  agg      same root expression aggregated over the whole binary (globals)
           or over the source file (argument-field roots such as
           ld(e.a0+0x6e74)) is strong and never hits a non-register offset
  call     the root is an argument register and a caller passes a REX3
           base in it (or the callee proves it REX3 and the caller's value
           is then REX3 too)
Everything else is rejected. Writes out/<key>.rex.pkl: list of REX3 accesses."""
import sys
import pickle
from collections import defaultdict, Counter
sys.path.insert(0, __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0])
from census import strength, regname, is_global
from mipsflow import fmt

HERE = __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0]

# functions whose source file must match (the kernel is full of big structs
# whose field offsets look like REX3 registers)
SCOPE = {"unix": "NEWPORT"}
# the REX3 base pointer each binary keeps in its context structure, found by
# the census (strong in dozens of functions, never a non-register offset):
#   libGLcore: gc->[0x6e74]   IRIS GL: gc->[0x1f0]   Xsgi: *pScreen->devPrivates
#   [rex3ScreenPrivateIndex]  kernel: newport info->[0x60]
PATTERN = {
    "glcore": r"\+0x6e74\)$",
    "irisgl": r"\+0x1f0\)$",
    "xsgi": r"^ld\(ld\(\(ld\(.*0x1d4\) \+r \(g\(0x1041e2a4\) << 0x2\)\)\)\)$",
    "unix": r"\+0x60\)$",
}
# roots settled by reading the code (dis.py): (function, substring of fmt(root))
MANUAL = {
    "unix": [
        ("newportFIFO", "-0x77e49250)"),             # board table[i].rex -> CONFIG read
        ("ip22_newportInterrupt", "-0x77e49248)+0x60)"),   # table[i].info->rex -> STATUS
        ("ip24_newportInterrupt", "-0x77e49248)+0x60)"),
        ("ng1_error", "=?@8818c728"),                # table[i].rex: CONFIG write
        ("ng1_error", "=?@8818c748"),                # CONFIG write
        ("ng1_error", "=?@8818c78c"),                # TOPSCAN, USER_STATUS reads
    ],
}


def is_argfield(r):
    """ld(...e.X...) : a field reached from an argument/local"""
    return r[0] == "ld" and not is_global(r)


def classify(key, verbose=False):
    D = pickle.load(open(HERE + "/out/%s.pkl" % key, "rb"))
    acc, calls = D["acc"], D["calls"]
    src = D["srcfile"]
    fgroups = defaultdict(list)            # (flo, root) -> [j]
    for j, a in enumerate(acc):
        fgroups[(a["flo"], a["root"])].append(j)
    offw = lambda js: {(acc[j]["wo"], acc[j]["width"], acc[j]["st"]) for j in js}
    fver = {}
    for g, js in fgroups.items():
        fver[g] = "abs" if acc[js[0]]["abs"] else strength(offw(js))
    # aggregated keys
    agg = defaultdict(list)
    for g, js in fgroups.items():
        flo, r = g
        if acc[js[0]]["abs"]:
            continue
        if is_global(r):
            agg[("G", r)].extend(js)
        elif is_argfield(r):
            agg[("F", src.get(flo, "?"), r)].extend(js)
    aver = {k: strength(offw(js)) for k, js in agg.items()}

    def aggkey(g):
        flo, r = g
        if is_global(r):
            return ("G", r)
        if is_argfield(r):
            return ("F", src.get(flo, "?"), r)
        return None

    rex = {}                               # group -> evidence
    scope = SCOPE.get(key)
    inscope = lambda flo: scope is None or scope in src.get(flo, "")
    fname = {}
    for g, js in fgroups.items():
        fname[g[0]] = acc[js[0]]["fn"]
    for (fn_, sub) in MANUAL.get(key, []):
        for g in fgroups:
            f_ = fmt(g[1])
            if fname[g[0]] == fn_ and (f_ == sub[1:] if sub.startswith("=") else sub in f_):
                rex[g] = "manual"
    import re
    pat = re.compile(PATTERN[key]) if key in PATTERN else None
    for g, v in fver.items():
        if pat and inscope(g[0]) and g not in rex and v not in ("no", "odd") and pat.search(fmt(g[1])):
            rex[g] = "pattern" if v not in ("strong", "abs") else v
    for g, v in fver.items():
        if not inscope(g[0]) or g in rex:
            continue
        if v == "odd":
            continue
        if v in ("abs", "strong"):
            ak = aggkey(g)
            # a global root that some OTHER function uses as a struct is not REX3
            if ak and ak[0] == "G" and aver.get(ak) == "no":
                continue
            rex[g] = v
        elif v in ("weak", "small", "odd"):
            ak = aggkey(g)
            if ak and aver.get(ak) == "strong":
                rex[g] = "agg"
    # weak groups inside the Newport code, reviewed by hand (review lists in
    # the transcript): register-held REX3 pointers in the asm helpers.  Keep
    # those with a store, or reads of REX3-only registers (GO/0x13xx/DCB).
    from census import bank
    WEAKSCOPE = {
        "glcore": lambda flo: "NEWPORT" in src.get(flo, "") or ("/" not in src.get(flo, "/")),
        "irisgl": lambda flo: "NEWPORT" in src.get(flo, "") or ("/" not in src.get(flo, "/")),
        "unix": lambda flo: "NEWPORT" in src.get(flo, ""),
        "xsgi": lambda flo: 0x100C0000 <= flo < 0x10112000,
    }
    ws = WEAKSCOPE.get(key)
    if ws:
        for g, v in fver.items():
            if g in rex or v != "weak" or not ws(g[0]):
                continue
            f_ = fmt(g[1])
            if "0xf1b115c" in f_ or "g(0x1010)" in f_:      # DGL comm buffer, a struct
                continue
            js = fgroups[g]
            if any(acc[j]["st"] for j in js) or                     any(bank(acc[j]["wo"]) in ("G", "P", "D") for j in js):
                rex[g] = "reviewed"
    # call propagation over argument registers
    ARG = {4: ("e", 4), 5: ("e", 5), 6: ("e", 6), 7: ("e", 7)}
    rexroots = defaultdict(set)            # flo -> roots that are REX3 in that function
    for g in rex:
        rexroots[g[0]].add(g[1])
    changed = True
    rounds = 0
    while changed and rounds < 10:
        changed = False
        rounds += 1
        for c in calls:
            if c["tgt"] is None:
                continue
            for r, alts in c["args"].items():
                if len(alts) != 1:
                    continue
                root, off = alts[0]
                if off not in (0, 0x800):
                    continue
                callee_g = (c["tgt"], ARG[r])
                caller_g = (c["flo"], root)
                # caller -> callee
                if root in rexroots[c["flo"]] and callee_g in fver and callee_g not in rex \
                        and fver[callee_g] != "no":
                    rex[callee_g] = "call"
                    rexroots[c["tgt"]].add(ARG[r])
                    changed = True
                # callee -> caller
                if ARG[r] in rexroots[c["tgt"]] and caller_g in fver and caller_g not in rex \
                        and fver[caller_g] != "no" and root[0] != "c":
                    rex[caller_g] = "call"
                    rexroots[c["flo"]].add(root)
                    changed = True
    # an access whose base is a phi of several roots is kept only if no
    # alternative root is known to be a non-REX3 structure
    alts = defaultdict(list)
    for j, a in enumerate(acc):
        if a["nalts"] > 1:
            alts[(a["flo"], a["pc"])].append(j)
    dropped = set()
    for key_, js in alts.items():
        roots = [(acc[j]["flo"], acc[j]["root"]) for j in js]
        if any((aggkey(g) and aver.get(aggkey(g)) == "no") or fver.get(g) == "no" for g in roots):
            dropped.update(js)
    # PROM: the 0xbfc1b204-0xbfc1f6xx cluster is a serial/keyboard driver whose
    # struct keeps two register pointers at +0x148/+0x14c (lbu/sb through
    # them, bytes 0x11/0x15/0x17 - an SCC), and bfc30fc0 a string routine
    EXCL = {"prom": [(0xBFC1B000, 0xBFC1F800), (0xBFC30FC0, 0xBFC31000)],
            # Xsgi sub_100e1068: +0x12c read-modify-write through a stack
            # temp and a call result - a struct field, not BRESS2
            "xsgi": [(0x100E1068, 0x100E1070)]}
    for g in list(rex):
        if any(lo <= g[0] < hi for lo, hi in EXCL.get(key, [])):
            del rex[g]
    out = []
    seen_pc = set()                        # one row per instruction, even when a
    for g, ev in rex.items():              # phi base named it under two roots
        for j in fgroups[g]:
            if j in dropped or acc[j]["pc"] in seen_pc:
                continue
            seen_pc.add(acc[j]["pc"])
            a = dict(acc[j])
            a["ev"] = ev
            r = regname(a["wo"], a["width"])
            if r is None:
                continue
            a["reg"], a["go"] = r
            out.append(a)
    pickle.dump(dict(img=D["img"], rex=out, srcfile=src, dsyms=D["dsyms"],
                     fver=fver, aver=aver, rexgroups=rex),
                open(HERE + "/out/%s.rex.pkl" % key, "wb"))
    ev = Counter(a["ev"] for a in out)
    print("%s: %d REX3 accesses in %d functions; evidence %s" % (
        D["img"], len(out), len({a["flo"] for a in out}), dict(ev)))
    return out


if __name__ == "__main__":
    for k in sys.argv[1:]:
        classify(k)

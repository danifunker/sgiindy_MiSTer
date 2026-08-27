#!/usr/bin/env python3
"""compare.py - diff two cpu-tests runs test by test.

The suite prints one line per test, `name .... PASS` or a name followed by
indented failure detail. Comparing two runs by hand does not scale to 240
tests, and the number that matters is not "how many failed" but "which tests
differ from the reference, and in which direction".

    tests/compare.py tests/baseline/iris-r4400.log build/r4300.log

Exit status is 1 when the run under test regresses against the reference on
any test, so it can gate CI.
"""

import re
import sys

# "identity/prid .............................. PASS"
#
# Not anchored to the start of the line: a test that *reports* an observation
# leaves its own line open, so the next test's name gets printed after that
# report - "[cop2: ExcCode=0 CE=0]excep/exl_set_and_cleared ....... PASS" is a
# real line from a passing run, and anchoring loses that test entirely.
RESULT = re.compile(r'([a-z0-9_]+/[a-z0-9_]+)\s+\.\.+\s*(.*)$')
SUMMARY = re.compile(r'RESULT:\s+(\d+)\s+checks passed,\s+(\d+)\s+failed')
CPUNAME = re.compile(r'IRIS CPU test suite\s+cpu=(\S+)')


def parse(path):
    """-> (cpu, {test: 'PASS'|'FAIL'|'SKIP'}, (passed, failed))"""
    tests, cpu, totals = {}, "?", None
    cur = None
    for line in open(path, errors="replace"):
        line = line.rstrip("\n")
        m = CPUNAME.search(line)
        if m:
            cpu = m.group(1)
        m = SUMMARY.search(line)
        if m:
            totals = (int(m.group(1)), int(m.group(2)))
        m = RESULT.search(line)
        if m:
            cur = m.group(1)
            rest = m.group(2).strip()
            if rest.startswith("PASS"):
                tests[cur] = "PASS"
            elif rest.startswith("skip"):
                tests[cur] = "SKIP"
            else:
                # The name line stays open until the test's last check, so a
                # test whose line ends without PASS has failed - unless a
                # later bare "PASS" closes it, handled below.
                tests[cur] = "FAIL"
        elif cur and line.strip() == "PASS":
            # A test that only *reported* observations closes its line later.
            if tests.get(cur) == "FAIL":
                tests[cur] = "PASS"
            cur = None
        elif cur and line.strip().endswith("PASS") and line.startswith("      ["):
            if tests.get(cur) == "FAIL":
                tests[cur] = "PASS"
            cur = None
    return cpu, tests, totals


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    ref_path, new_path = argv[1], argv[2]
    ref_cpu, ref, ref_tot = parse(ref_path)
    new_cpu, new, new_tot = parse(new_path)

    print(f"reference : {ref_path}  cpu={ref_cpu}  "
          f"{len(ref)} tests" + (f"  {ref_tot[0]} pass / {ref_tot[1]} fail" if ref_tot else ""))
    print(f"under test: {new_path}  cpu={new_cpu}  "
          f"{len(new)} tests" + (f"  {new_tot[0]} pass / {new_tot[1]} fail" if new_tot else ""))
    print()

    regressions, fixes, missing = [], [], []
    for name in sorted(set(ref) | set(new)):
        r, n = ref.get(name), new.get(name)
        if n is None:
            missing.append(name)
        elif r is None:
            continue
        elif r == n:
            continue
        elif r == "PASS" and n != "PASS":
            regressions.append((name, r, n))
        elif r != "PASS" and n == "PASS":
            fixes.append((name, r, n))
        else:
            fixes.append((name, r, n))

    if regressions:
        print(f"REGRESSIONS ({len(regressions)}) - pass on the reference, not here:")
        for name, r, n in regressions:
            print(f"  {name:44s} {r} -> {n}")
        print()
    if fixes:
        print(f"differences the other way ({len(fixes)}):")
        for name, r, n in fixes:
            print(f"  {name:44s} {r} -> {n}")
        print()
    if missing:
        print(f"not reached in the run under test ({len(missing)}):")
        for name in missing[:20]:
            print(f"  {name}")
        if len(missing) > 20:
            print(f"  ... and {len(missing) - 20} more")
        print()

    if not regressions and not missing:
        print("no regressions against the reference.")
    return 1 if (regressions or missing) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

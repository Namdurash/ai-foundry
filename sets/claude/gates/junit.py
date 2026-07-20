#!/usr/bin/env python3
"""Convert a JUnit XML report to a flat JSON array of per-test results.

Bash + jq cannot parse XML without a fragile grep over `<testcase` lines, so the
one place this framework reaches past bash is here. python3 is on every mac and
every CI image; when it is absent, verify-red falls back to coarse mode and says
so. This shim is intentionally tiny and dependency-free (stdlib only).

Output: [{"id","file","status","message"}] where status is
pass | failure | error | skipped. `file` comes from pytest's per-testcase
attribute so a result can be matched to the test file the plan declared.
"""
import json
import sys
import xml.etree.ElementTree as ET


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: junit.py <report.xml>", file=sys.stderr)
        return 2
    try:
        tree = ET.parse(sys.argv[1])
    except (ET.ParseError, OSError):
        # An unparseable or missing report is not per-test data; let the caller
        # fall back to coarse mode rather than emit a misleading empty array.
        return 1

    out = []
    for tc in tree.iter("testcase"):
        classname = tc.get("classname", "")
        name = tc.get("name", "")
        test_id = f"{classname}::{name}" if classname else name
        status = "pass"
        message = ""
        for child in tc:
            tag = child.tag.split("}")[-1]  # strip any namespace
            if tag in ("failure", "error"):
                status = tag
                message = (child.get("message", "") or "") + " " + (child.text or "")
            elif tag == "skipped":
                status = "skipped"
                message = child.get("message", "") or ""
        out.append(
            {
                "id": test_id,
                "file": tc.get("file", ""),
                "status": status,
                "message": message.strip()[:800],
            }
        )

    if not out:
        # A report with zero testcases means nothing was collected — coarse mode
        # is more honest than an empty "everything passed".
        return 1

    json.dump(out, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())

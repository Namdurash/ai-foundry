#!/usr/bin/env python3
"""Convert a JUnit XML report to a flat JSON array of per-test results.

Bash + jq cannot parse XML without a fragile grep over `<testcase` lines, so the
one place this framework reaches past bash is here. python3 is on every mac and
every CI image; when it is absent, verify-red falls back to coarse mode and says
so. This shim is intentionally tiny and dependency-free (stdlib only).

Output: [{"id","file","status","message"}] where status is
pass | failure | error | skipped. `file` is what lets a result be matched to the
test file the plan declared: pytest's own @file where the report carries one,
and otherwise rebuilt from @classname — see _file_from_classname.
"""
import json
import sys
import xml.etree.ElementTree as ET


def _file_from_classname(dotted: str) -> str:
    """The test file a dotted pytest name came from, or "" if it cannot be told.

    pytest emits @file on <testcase> only under junit_family=xunit1: the xunit2
    schema has no such attribute, so pytest filters it out — and xunit2 is the
    default since pytest 6.0. Without @file every result looks like it belongs
    to no file at all, none of them match the plan's declared tests, and
    verify-red is blind on exactly the projects that are on a current pytest.

    What is left is @classname, which pytest builds from the node id: the file
    path with "." for "/" and ".py" dropped, then one component per enclosing
    class — "tests/api/test_users.py::TestList::test_empty" becomes
    "tests.api.test_users.TestList". Going back means knowing where the path
    ends and the classes begin, and the dots do not say. Classes are the
    capitalised tail (pytest collects `Test*` classes by default), so that is
    what gets dropped; a module file in CamelCase would be read wrong, and
    nothing pytest collects by default is named that way.

    A report from another producer can still hand us a classname shaped like a
    module path (a Java package, say) and get a .py path that never existed.
    Harmless where the value is used: it is only ever matched against the test
    files the plan declared, and a path that does not exist matches nothing.
    """
    parts = dotted.split(".")
    while parts and parts[-1][:1].isupper():
        parts.pop()
    if not parts or not all(p.isidentifier() for p in parts):
        return ""
    return "/".join(parts) + ".py"


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
        # An empty classname is pytest reporting a whole file that would not
        # import: the node id was the path alone, so the dotted module ends up
        # in @name. That one is a collection error in a declared test file —
        # the gate has to see which file it was to call it broken rather than
        # blame the pre-existing suite.
        file_attr = tc.get("file") or _file_from_classname(classname or name)
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
                "file": file_attr,
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

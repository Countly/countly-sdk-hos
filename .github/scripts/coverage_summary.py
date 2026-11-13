"""Prints a Markdown summary of the coverage report that hvigorw collectCoverage writes as coverageReport.json."""
import json
import os
import sys

MAX_LISTED = 50


def ratio(coverage):
    """Returns 'pct% (covered/total)' for one coverage entry of the report."""
    return f"{coverage['pct']}% ({coverage['covered']}/{coverage['total']})"


def main():
    """Prints the overall and per-file coverage, failing when no line was covered, which means nothing was measured."""
    if len(sys.argv) != 2:
        sys.exit("Usage: python3 coverage_summary.py <coverageReport.json>")
    with open(sys.argv[1], encoding="utf-8") as handle:
        report = json.load(handle)
    summary, files = report["summary"], report.get("files", [])
    if not files or summary["lines"]["covered"] == 0:
        sys.exit("::error title=Coverage::The coverage report has no covered line, so the device run measured nothing")
    print("### Device test coverage\n")
    print("| Lines | Functions | Branches |\n|---|---|---|")
    print(f"| {ratio(summary['lines'])} | {ratio(summary['functions'])} | {ratio(summary['branches'])} |")
    print(f"\n<details><summary>Per file, first {min(MAX_LISTED, len(files))} of {len(files)}</summary>\n")
    print("| File | Lines | Functions | Branches |\n|---|---|---|---|")
    for file in sorted(files, key=lambda item: item["path"])[:MAX_LISTED]:
        path = os.path.relpath(file["path"]) if os.path.isabs(file["path"]) else file["path"]
        per_file = file["summary"]
        print(f"| {path} | {ratio(per_file['lines'])} | {ratio(per_file['functions'])} | {ratio(per_file['branches'])} |")
    print("\n</details>")


if __name__ == "__main__":
    main()

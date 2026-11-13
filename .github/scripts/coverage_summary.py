"""Prints a Markdown summary of the coverage report that hvigorw collectCoverage writes as coverageReport.json."""
import json
import os
import sys

MAX_LISTED = 50


def ratio(coverage):
    """Returns 'pct% (covered/total)' for one coverage entry of the report."""
    return f"{coverage['pct']}% ({coverage['covered']}/{coverage['total']})"


def per_file_table(files):
    """Returns the Markdown table of the coverage of the first MAX_LISTED files, in path order."""
    rows = ["| File | Lines | Functions | Branches |", "|---|---|---|---|"]
    for file in sorted(files, key=lambda item: item["path"])[:MAX_LISTED]:
        path = os.path.relpath(file["path"]) if os.path.isabs(file["path"]) else file["path"]
        per_file = file["summary"]
        rows.append(f"| {path} | {ratio(per_file['lines'])} | {ratio(per_file['functions'])} | {ratio(per_file['branches'])} |")
    return "\n".join(rows)


def write_fragment(folder, summary, details):
    """Writes report.md under folder, the CI report fragment: a title, the summary line, then the details."""
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "report.md"), "w", encoding="utf-8") as fragment:
        fragment.write(f"Coverage\n{summary}\n{details}\n")


def main():
    """Prints the overall and per-file coverage, also to the given fragment folder; fails when no line was covered."""
    if len(sys.argv) not in (2, 3):
        sys.exit("Usage: python3 coverage_summary.py <coverageReport.json> [<CI report fragment folder>]")
    with open(sys.argv[1], encoding="utf-8") as handle:
        report = json.load(handle)
    summary, files = report["summary"], report.get("files", [])
    if not files or summary["lines"]["covered"] == 0:
        sys.exit("::error title=Coverage::The coverage report has no covered line, so the device run measured nothing")
    overall = f"| {ratio(summary['lines'])} | {ratio(summary['functions'])} | {ratio(summary['branches'])} |"
    caption = f"Per file, first {min(MAX_LISTED, len(files))} of {len(files)}"
    text = (f"### Device test coverage\n\n| Lines | Functions | Branches |\n|---|---|---|\n{overall}\n\n"
            f"<details><summary>{caption}</summary>\n\n{per_file_table(files)}\n\n</details>")
    print(text)
    if len(sys.argv) == 3:
        write_fragment(sys.argv[2], f"Line coverage {summary['lines']['pct']}%", text)


if __name__ == "__main__":
    main()

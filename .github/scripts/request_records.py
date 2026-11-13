"""Compares the request records the device tests printed into the aa test log with the ones in api/requests/."""

import difflib
import os
import sys

PREFIX = "COUNTLY_REQUEST_RECORD "


def printed_records(log_path):
    """Returns the records the log holds, by scenario name, each as the text of its file."""
    lines = {}
    with open(log_path, encoding="utf-8", errors="replace") as log:
        for line in log:
            at = line.find(PREFIX)
            if at == -1:
                continue
            name, _, text = line[at + len(PREFIX):].rstrip("\r\n").partition(" ")
            lines.setdefault(name, []).append(text)
    return {name: "\n".join(text) + "\n" for name, text in lines.items()}


def committed_records(records_dir):
    """Returns the records in the repository, by scenario name, with Windows line endings removed."""
    if not os.path.isdir(records_dir):
        return {}
    records = {}
    for file_name in sorted(os.listdir(records_dir)):
        if file_name.endswith(".json"):
            with open(os.path.join(records_dir, file_name), encoding="utf-8") as record:
                records[file_name[:-len(".json")]] = record.read().replace("\r\n", "\n")
    return records


def main(log_path, records_dir, out_dir):
    """Writes the printed records under out_dir, reports every difference in the job summary and returns 1 on any."""
    printed = printed_records(log_path)
    committed = committed_records(records_dir)
    report = []
    for name, text in sorted(printed.items()):
        target = os.path.join(out_dir, records_dir, name + ".json")
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w", encoding="utf-8") as record:
            record.write(text)
        if committed.get(name) == text:
            print(f"The {name} scenario sends the requests {records_dir}/{name}.json records.")
            continue
        diff = difflib.unified_diff(committed.get(name, "").splitlines(), text.splitlines(), f"{records_dir}/{name}.json", "sent", lineterm="")
        report.append(f"### The requests of the {name} scenario differ from {records_dir}/{name}.json\n\n```diff\n" + "\n".join(list(diff)[:300]) + "\n```\n")
    for name in sorted(set(committed) - set(printed)):
        report.append(f"### The {name} scenario printed no record\n\nThe device tests did not run it, or it failed before printing.\n")
    if not printed:
        report.append("### The device tests printed no request record\n")
    if not report:
        return 0
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as out:
            out.write("Commit the files from this run's request-records artifact, with a CHANGELOG.md line, if the change is deliberate.\n\n")
            out.write("\n".join(report))
    print("::error title=Request records::The requests the SDK sends differ from api/requests/. The job summary shows how.")
    return 1


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:4]))

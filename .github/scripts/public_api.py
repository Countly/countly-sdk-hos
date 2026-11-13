"""
Prints the public ArkTS API of a HarmonyOS HAR as sorted lines, so two versions can be compared.

Reads the declaration files (.d.ets) the compiler writes into the HAR. Every name that package/Index.d.ets
exports is followed into the declaration file it comes from and becomes a "<name> <kind>" line, plus one
"<name>: <member>" line for each member that is not private. Comments and blank lines are left out.

Usage: public_api.py <HAR file>
"""
import posixpath
import re
import sys
import tarfile

EXPORT_FROM = re.compile(r"^export\s*\{([^}]*)\}\s*from\s*'([^']+)'")
EXPORT_ALL = re.compile(r"^export\s*\*\s*from\s*'([^']+)'")
DECLARATION = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:export\s+)?(?:default\s+)?(?:declare\s+)?(?:abstract\s+)?"
    r"(class|interface|enum|struct|function|const|let|type|namespace)\s+(\w+)")


def declaration_files(har):
    """Returns {path inside the HAR: text} for every .d.ets file in the HAR."""
    with tarfile.open(har, "r:gz") as archive:
        return {member.name: archive.extractfile(member).read().decode("utf-8")
                for member in archive.getmembers() if member.isfile() and member.name.endswith(".d.ets")}


def module_file(files, importer, specifier):
    """Returns the declaration file that the import specifier in importer refers to."""
    path = posixpath.normpath(posixpath.join(posixpath.dirname(importer), specifier))
    for candidate in (f"{path}.d.ets", f"{path}/Index.d.ets"):
        if candidate in files:
            return candidate
    sys.exit(f"{importer} exports from {specifier}, but the HAR has no declaration file for it.")


def is_noise(line):
    """Returns whether a stripped line is a comment, blank or a private member."""
    return not line or line.startswith(("//", "/*", "*", "*/", "private "))


def declarations(text):
    """Returns {name: (kind, [member lines])} for each top-level declaration in a declaration file."""
    found, current, depth = {}, None, 0
    for raw in text.splitlines():
        line = " ".join(raw.split())
        if depth == 0:
            match = DECLARATION.match(line)
            if match:
                kind, name = match.groups()
                current = name
                found[name] = (kind, [] if "{" in line else [line])
        elif depth == 1 and current and not is_noise(line) and line != "}":
            found[current][1].append(line)
        depth = max(0, depth + line.count("{") - line.count("}"))
        if depth == 0:
            current = None
    return found


def main():
    """Prints the sorted public API lines of the HAR named on the command line."""
    files = declaration_files(sys.argv[1])
    index = "package/Index.d.ets"
    if index not in files:
        sys.exit(f"{sys.argv[1]} has no {index}.")
    lines = set()
    for raw in files[index].splitlines():
        line = raw.strip()
        named, everything = EXPORT_FROM.match(line), EXPORT_ALL.match(line)
        if named:
            source = declarations(files[module_file(files, index, named.group(2))])
            for item in filter(None, (part.strip() for part in named.group(1).split(","))):
                original, _, alias = item.partition(" as ")
                original = original.replace("type ", "").strip()
                kind, members = source.get(original, ("missing", []))
                exported = alias.strip() or original
                lines.add(f"{exported} {kind}")
                lines.update(f"{exported}: {member}" for member in members)
        elif everything:
            source = declarations(files[module_file(files, index, everything.group(1))])
            for name, (kind, members) in source.items():
                lines.add(f"{name} {kind}")
                lines.update(f"{name}: {member}" for member in members)
    if not lines:
        sys.exit(f"{index} exports nothing.")
    print("\n".join(sorted(lines)))


if __name__ == "__main__":
    main()

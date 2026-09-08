"""Fetch locked VCS requirements before package builds run."""

import argparse
import re
import subprocess
from pathlib import Path
from urllib.parse import parse_qs


VCS_REQUIREMENT = re.compile(
    r"^(?P<name>[A-Za-z0-9_.-]+(?:\[[^\]]+\])?)\s+@\s+"
    r"git\+(?P<url>https://github\.com/[^#@]+?\.git)"
    r"@(?P<commit>[0-9a-f]{40})(?:#(?P<fragment>.*))?$"
)


def parse_requirement(line):
    """Return a VCS requirement's source fields, or ``None`` for other lines."""
    if "git+" not in line:
        return None
    match = VCS_REQUIREMENT.fullmatch(line)
    if match is None:
        raise ValueError(f"Unsupported VCS requirement: {line}")
    fragment = parse_qs(match["fragment"] or "", keep_blank_values=True)
    unknown = set(fragment) - {"subdirectory"}
    if unknown or any(len(values) != 1 for values in fragment.values()):
        raise ValueError(f"Unsupported VCS fragment: {line}")
    subdirectory = fragment.get("subdirectory", [None])[0]
    if subdirectory and (
        Path(subdirectory).is_absolute() or ".." in Path(subdirectory).parts
    ):
        raise ValueError(f"Absolute VCS subdirectory: {line}")
    return {
        "name": match["name"],
        "url": match["url"],
        "commit": match["commit"],
        "subdirectory": subdirectory,
    }


def repository_directory(url, root):
    """Return a stable source directory for a GitHub URL."""
    name = url.rsplit("/", 1)[-1][:-4]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
        raise ValueError(f"Unsafe repository name: {name}")
    return Path(root) / name


def fetch_repository(url, commit, destination):
    """Fetch one exact commit with Git's credential helper only."""
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not (destination / ".git").is_dir():
        subprocess.run(["git", "init", str(destination)], check=True, capture_output=True)
        subprocess.run(
            ["git", "-C", str(destination), "remote", "add", "origin", url],
            check=True,
            capture_output=True,
        )
    subprocess.run(
        ["git", "-C", str(destination), "fetch", "--depth=1", "origin", commit],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", str(destination), "checkout", "--detach", "FETCH_HEAD"],
        check=True,
        capture_output=True,
    )
    actual = subprocess.check_output(
        ["git", "-C", str(destination), "rev-parse", "HEAD"], text=True
    ).strip()
    if actual != commit:
        raise ValueError(f"Fetched {url} at {actual}, expected {commit}")


def prepare_requirements(requirements, root, output):
    """Fetch VCS sources and rewrite those requirements to local paths."""
    sources = {}
    rewritten = []
    for raw_line in Path(requirements).read_text().splitlines():
        line = raw_line.strip()
        requirement = parse_requirement(line)
        if requirement is None:
            rewritten.append(raw_line)
            continue
        source_dir = repository_directory(requirement["url"], root)
        key = (requirement["url"], requirement["commit"])
        if key not in sources:
            fetch_repository(requirement["url"], requirement["commit"], source_dir)
            sources[key] = source_dir
        source = source_dir
        if requirement["subdirectory"]:
            source = source / requirement["subdirectory"]
        if not source.is_dir():
            raise ValueError(f"VCS subdirectory does not exist: {source}")
        rewritten.append(f"{requirement['name']} @ {source.as_uri()}")
    Path(output).write_text("\n".join(rewritten) + "\n")
    return len(sources)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--requirements", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    count = prepare_requirements(args.requirements, args.directory, args.output)
    print(f"fetched {count} VCS source(s)")


if __name__ == "__main__":
    main()

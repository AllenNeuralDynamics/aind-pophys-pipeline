"""Verify existing OCI archives and record an exact, unpublished candidate set."""

import argparse
import hashlib
import json
import re
import tarfile
from pathlib import Path

from candidates import ROOT, validate


def check_archive(path, report):
    """Verify manifest, config and layer bytes without extracting image files."""
    with tarfile.open(path, "r:") as archive:
        members = {member.name: member for member in archive.getmembers()}
        if len(members) != len(archive.getmembers()):
            raise ValueError("Duplicate archive member")

        def blob(digest, size=None):
            if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
                raise ValueError(f"Unsupported digest: {digest}")
            name = "blobs/" + digest.replace(":", "/")
            member = members[name]
            if not member.isfile() or (size is not None and member.size != size):
                raise ValueError(f"Invalid blob type or size: {digest}")
            hasher = hashlib.sha256()
            with archive.extractfile(member) as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    hasher.update(chunk)
            if "sha256:" + hasher.hexdigest() != digest:
                raise ValueError(f"Blob checksum mismatch: {digest}")
            return member

        def document(digest):
            member = blob(digest)
            if member.size > 1024 * 1024:
                raise ValueError("Oversized OCI metadata")
            with archive.extractfile(member) as stream:
                return json.load(stream)

        with archive.extractfile("index.json") as stream:
            index = json.load(stream)
        digest = report["digest"]
        if digest not in {entry["digest"] for entry in index["manifests"]}:
            raise ValueError("Report digest is not an archive root")
        manifest = document(digest)
        if "manifests" in manifest:
            descriptors = [
                item for item in manifest["manifests"]
                if item.get("platform") == {"architecture": "amd64", "os": "linux"}
            ]
            if len(descriptors) != 1:
                raise ValueError("Expected one Linux amd64 image")
            digest = descriptors[0]["digest"]
            manifest = document(digest)
        if digest != report["platform_manifest_digest"]:
            raise ValueError("Platform manifest differs from build report")
        config = document(manifest["config"]["digest"])
        if (config["os"], config["architecture"]) != ("linux", "amd64"):
            raise ValueError("Unexpected image platform")
        for layer in manifest["layers"]:
            blob(layer["digest"], layer["size"])
        size = sum(layer["size"] for layer in manifest["layers"])
        if size != report["compressed_layer_bytes"]:
            raise ValueError("Compressed size differs from build report")
        if len(manifest["layers"]) != report["layers"]:
            raise ValueError("Layer count differs from build report")
    if path.stat().st_size != report["oci_archive_bytes"]:
        raise ValueError("Archive size differs from build report")
    return {"platform": "linux/amd64", "all_referenced_blob_checksums": True}


def collect(reports, rows):
    """Require exactly one verified artifact per declared stage."""
    entries, failures, seen = [], [], set()
    for path in reports:
        try:
            report = json.loads(path.read_text())
            stage = report["stage"]
            if stage not in rows or stage in seen:
                raise ValueError(f"Unknown or duplicate stage: {stage}")
            seen.add(stage)
            if not report["image_built"] or report["published"] or report["promoted"]:
                raise ValueError("Expected a built, unpublished, unpromoted candidate")
            if report["image"].rsplit(":", 1)[0] != rows[stage]["image"]:
                raise ValueError("Image repository differs from stage map")
            archive = path.parent / "image.tar"
            invariants = check_archive(archive, report)
            entries.append({
                **report,
                "required_visibility": "private",
                "archive": str(archive.relative_to(ROOT)),
                "build_report": str(path.relative_to(ROOT)),
                "invariants": invariants,
            })
        except (OSError, ValueError, KeyError, TypeError, tarfile.TarError) as error:
            failures.append({"report": str(path), "error": str(error)})
    missing = sorted(set(rows) - seen)
    if missing:
        failures.append({"missing_stages": missing})
    return {
        "schema_version": 1,
        "purpose": "Exact existing artifacts for a future private registry copy; no rebuild.",
        "counts": {
            "candidate": len(reports), "processed": len(entries), "skipped": 0,
            "failed": len(failures), "missing": len(missing),
        },
        "limitations": [
            "Images were built across successive recipe revisions, not one uniform checkout.",
            "Successful image builds do not establish scientific parity or GPU execution.",
            "Required private visibility is policy, not evidence of an existing registry package.",
        ],
        "images": sorted(entries, key=lambda entry: entry["stage"]),
        "failures": failures,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reports", type=Path, nargs="+", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = collect([path.resolve() for path in args.reports], validate())
    # A failed audit must not leave a success-shaped publication inventory.
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"counts": result["counts"], "failures": result["failures"]}))
    raise SystemExit(bool(result["failures"]))


if __name__ == "__main__":
    main()

"""Audit or publish existing OCI candidates without rebuilding or changing digests."""

import argparse
import base64
import binascii
import hashlib
import json
import os
import re
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

from candidates import ROOT, validate
from inventory import check_archive

ALLOWED_VISIBILITIES = {"private", "internal"}


def registry_token(authfile):
    """Read Skopeo's GHCR login for API checks without printing credentials."""
    data = json.loads(authfile.read_text())
    credential = data.get("auths", {}).get("ghcr.io", {}).get("auth")
    if not credential:
        raise ValueError("Auth file needs a ghcr.io login; use skopeo login --authfile PATH ghcr.io")
    try:
        user, token = base64.b64decode(credential, validate=True).decode().split(":", 1)
    except (ValueError, UnicodeError, binascii.Error) as error:
        raise ValueError("Invalid GHCR credentials in auth file") from error
    if not user or not token:
        raise ValueError("Empty GHCR login")
    return token


def package_visibility(repository, token):
    """Read visibility; only HTTP 404 represents an absent/unavailable package."""
    match = re.fullmatch(r"ghcr\.io/allenneuraldynamics/(pophys-[a-z0-9-]+)", repository)
    if match is None:
        raise ValueError("Unexpected candidate repository")
    url = f"https://api.github.com/orgs/AllenNeuralDynamics/packages/container/{match[1]}"
    request = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            visibility = json.load(response)["visibility"]
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise ValueError(f"Package visibility check failed: HTTP {error.code}") from None
    except urllib.error.URLError:
        raise ValueError("Package visibility check failed: network error") from None
    if visibility not in ALLOWED_VISIBILITIES:
        raise ValueError(f"Refusing package visibility {visibility!r}")
    return visibility


def remote_digest(image, authfile):
    """Read exact remote manifest bytes; do not reinterpret or recompress."""
    result = subprocess.run(
        ["skopeo", "inspect", "--authfile", str(authfile), "--raw", f"docker://{image}"],
        capture_output=True,
    )
    if result.returncode:
        if b"manifest unknown" in result.stderr.lower():
            return None
        raise ValueError("Remote manifest inspection failed; check GHCR access/network")
    return "sha256:" + hashlib.sha256(result.stdout).hexdigest()


def audit_entry(entry, rows, authfile, token):
    stage = entry["stage"]
    repository, separator, tag = entry["image"].rpartition(":")
    if stage not in rows or rows[stage]["image"] != repository:
        raise ValueError("Inventory repository disagrees with stage map")
    if not separator or not re.fullmatch(r"candidate-[a-z0-9_.-]+", tag):
        raise ValueError("Expected a candidate tag")
    archive = (ROOT / entry["archive"]).resolve()
    if not archive.is_relative_to((ROOT / ".image-work").resolve()):
        raise ValueError("Archive must be inside .image-work")
    check_archive(archive, entry)
    visibility = package_visibility(repository, token)
    digest = remote_digest(entry["image"], authfile) if visibility else None
    if digest is not None and digest != entry["digest"]:
        raise ValueError("Remote candidate tag already points to different bytes; refusing overwrite")
    return {
        "stage": stage, "image": entry["image"], "digest": entry["digest"],
        "archive": entry["archive"], "visibility": visibility,
        "status": "already_present" if digest else "ready",
    }


def publish_entry(row, authfile, token):
    repository = row["image"].rpartition(":")[0]
    # Recheck immediately before a write, not just during the initial audit.
    visibility = package_visibility(repository, token)
    digest = remote_digest(row["image"], authfile) if visibility else None
    if digest is not None:
        if digest != row["digest"]:
            raise ValueError("Remote tag changed since audit; refusing overwrite")
        row.update(status="already_present", visibility=visibility)
        return
    subprocess.run([
        "skopeo", "copy", "--preserve-digests", "--authfile", str(authfile),
        f"oci-archive:{ROOT / row['archive']}", f"docker://{row['image']}",
    ], check=True)
    visibility = package_visibility(repository, token)
    if visibility not in ALLOWED_VISIBILITIES:
        raise ValueError("Published package visibility could not be verified; stop publication")
    if remote_digest(row["image"], authfile) != row["digest"]:
        raise ValueError("Published manifest digest differs from inventory; stop publication")
    row.update(status="published", visibility=visibility)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, default=ROOT / "environment/candidate-inventory.json")
    parser.add_argument("--authfile", type=Path, required=True)
    parser.add_argument("--execute", action="store_true", help="Upload ready candidates; default is read-only")
    args = parser.parse_args()
    token = registry_token(args.authfile)
    manifest = json.loads(args.inventory.read_text())
    rows = validate()
    entries = manifest["images"]
    if manifest["failures"] or len(entries) != len(rows) or {x["stage"] for x in entries} != set(rows):
        raise ValueError("Inventory must contain exactly eleven verified stages")
    report = {"execute": args.execute, "images": [], "failures": []}
    output = ROOT / ".image-work/publication-status.json"
    output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        statuses = [row["status"] for row in report["images"]]
        report["counts"] = {
            "candidate": len(entries), "processed": len(statuses),
            "skipped": statuses.count("already_present"), "published": statuses.count("published"),
            "ready": statuses.count("ready"), "failed": len(report["failures"]),
        }
        temporary = output.with_suffix(".tmp")
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        os.replace(temporary, output)

    # Audit the complete set before the first write.
    for entry in entries:
        try:
            report["images"].append(audit_entry(entry, rows, args.authfile, token))
        except (ValueError, OSError, KeyError, TypeError) as error:
            report["failures"].append({"stage": entry.get("stage"), "error": str(error)})
        save()
    if not report["failures"] and args.execute:
        for row in report["images"]:
            if row["status"] == "already_present":
                continue
            try:
                publish_entry(row, args.authfile, token)
            except (ValueError, OSError, subprocess.CalledProcessError) as error:
                report["failures"].append({"stage": row["stage"], "error": str(error)})
                save()
                break
            save()
    print(json.dumps({"counts": report["counts"], "failures": report["failures"]}))
    return int(bool(report["failures"]))


if __name__ == "__main__":
    raise SystemExit(main())

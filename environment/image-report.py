"""Record candidate digests and compressed layer sizes without promoting an image."""

import argparse
import hashlib
import json
import re
import subprocess
import tarfile
from pathlib import Path


def summarize(read, digest):
    """Read an OCI manifest/index and report the single Linux amd64 image."""
    payload = read(digest)
    if payload.endswith(b"\n") and "sha256:" + hashlib.sha256(payload[:-1]).hexdigest() == digest:
        payload = payload[:-1]
    if "sha256:" + hashlib.sha256(payload).hexdigest() != digest:
        raise ValueError("Image manifest checksum mismatch")
    manifest = json.loads(payload)
    if "manifests" in manifest:
        descriptors = [item for item in manifest["manifests"]
                       if item.get("platform", {}).get("architecture") == "amd64"
                       and item.get("platform", {}).get("os") == "linux"]
        if len(descriptors) != 1:
            raise ValueError("Expected exactly one linux/amd64 image")
        return summarize(read, descriptors[0]["digest"])
    layers = manifest["layers"]
    return {"platform_manifest_digest": digest, "layers": len(layers),
            "compressed_layer_bytes": sum(layer["size"] for layer in layers)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--digest", required=True)
    parser.add_argument("--stage", required=True)
    parser.add_argument("--output", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--archive", type=Path)
    mode.add_argument("--published", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", args.digest):
        raise ValueError("A real BuildKit image digest is required")
    if args.archive:
        with tarfile.open(args.archive) as archive:
            def read(digest):
                return archive.extractfile("blobs/" + digest.replace(":", "/")).read()
            result = summarize(read, args.digest)
        result["oci_archive_bytes"] = args.archive.stat().st_size
    else:
        repository = args.image.rsplit(":", 1)[0]
        def read(digest):
            return subprocess.check_output([
                "docker", "buildx", "imagetools", "inspect", "--raw", f"{repository}@{digest}"
            ])
        result = summarize(read, args.digest)
    result.update(stage=args.stage, image=args.image, digest=args.digest,
                  image_built=True, published=args.published, promoted=False)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()

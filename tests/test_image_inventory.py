import hashlib
import importlib.util
import io
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ENVIRONMENT = Path(__file__).parents[1] / "environment"
with patch.object(sys, "path", [str(ENVIRONMENT), *sys.path]):
    spec = importlib.util.spec_from_file_location("inventory", ENVIRONMENT / "inventory.py")
    inventory = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(inventory)


class InventoryTests(unittest.TestCase):
    def fixture(self, path, corrupt=False):
        layer = b"compressed layer fixture"
        config = json.dumps({"os": "linux", "architecture": "amd64"}).encode()

        def descriptor(data):
            return {"digest": "sha256:" + hashlib.sha256(data).hexdigest(), "size": len(data)}

        manifest = json.dumps({"config": descriptor(config), "layers": [descriptor(layer)]}).encode()
        digest = descriptor(manifest)["digest"]
        with tarfile.open(path, "w") as archive:
            files = {"index.json": json.dumps({"manifests": [{"digest": digest}]}).encode()}
            for data in (layer, config, manifest):
                files["blobs/" + descriptor(data)["digest"].replace(":", "/")] = (
                    b"X" * len(data) if corrupt and data == layer else data
                )
            for name, data in files.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        return {
            "digest": digest, "platform_manifest_digest": digest,
            "layers": 1, "compressed_layer_bytes": len(layer),
            "oci_archive_bytes": path.stat().st_size,
        }

    def test_valid_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.tar"
            report = self.fixture(path)
            self.assertTrue(inventory.check_archive(path, report)["all_referenced_blob_checksums"])

    def test_corrupt_layer_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.tar"
            report = self.fixture(path, corrupt=True)
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                inventory.check_archive(path, report)

    def test_report_digest_must_match_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.tar"
            report = self.fixture(path)
            report["digest"] = "sha256:" + "0" * 64
            with self.assertRaisesRegex(ValueError, "archive root"):
                inventory.check_archive(path, report)

    def test_missing_stages_fail_collection(self):
        result = inventory.collect([], {"DFF": {}})
        self.assertEqual(result["counts"]["missing"], 1)
        self.assertTrue(result["failures"])

import importlib.util
import io
import json
import sys
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

ENVIRONMENT = Path(__file__).parents[1] / "environment"
with patch.object(sys, "path", [str(ENVIRONMENT), *sys.path]):
    spec = importlib.util.spec_from_file_location("publish_inventory", ENVIRONMENT / "publish_inventory.py")
    publication = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(publication)


class PublicationTests(unittest.TestCase):
    def test_accepts_only_private_or_internal(self):
        for visibility in ("private", "internal", "public", "unknown"):
            with self.subTest(visibility=visibility):
                with patch.object(publication.urllib.request, "urlopen",
                                  return_value=io.BytesIO(json.dumps({"visibility": visibility}).encode())):
                    if visibility in ("private", "internal"):
                        self.assertEqual(publication.package_visibility(
                            "ghcr.io/allenneuraldynamics/pophys-dff", "unused"), visibility)
                    else:
                        with self.assertRaisesRegex(ValueError, "Refusing"):
                            publication.package_visibility("ghcr.io/allenneuraldynamics/pophys-dff", "unused")

    def test_only_404_is_treated_as_absent(self):
        for status in (401, 403, 404, 500):
            with self.subTest(status=status):
                error = urllib.error.HTTPError("https://api.github.com", status, "error", {}, None)
                with patch.object(publication.urllib.request, "urlopen", side_effect=error):
                    if status == 404:
                        self.assertIsNone(publication.package_visibility(
                            "ghcr.io/allenneuraldynamics/pophys-dff", "unused"))
                    else:
                        with self.assertRaises(ValueError):
                            publication.package_visibility("ghcr.io/allenneuraldynamics/pophys-dff", "unused")

    def test_retry_skips_matching_image_and_refuses_changed_tag(self):
        row = {"image": "ghcr.io/allenneuraldynamics/pophys-dff:candidate-test", "digest": "sha256:expected"}
        with patch.object(publication, "package_visibility", return_value="internal"):
            with patch.object(publication.subprocess, "run") as copy:
                with patch.object(publication, "remote_digest", return_value="sha256:expected"):
                    publication.publish_entry(row, Path("/unused"), "unused")
                    self.assertEqual(row["status"], "already_present")
                with patch.object(publication, "remote_digest", return_value="sha256:different"):
                    with self.assertRaisesRegex(ValueError, "refusing overwrite"):
                        publication.publish_entry(row, Path("/unused"), "unused")
                copy.assert_not_called()

    def test_copy_preserves_digest_and_rechecks_visibility(self):
        row = {"image": "ghcr.io/allenneuraldynamics/pophys-dff:candidate-test",
               "digest": "sha256:expected", "archive": ".image-work/test/image.tar"}
        with patch.object(publication, "package_visibility", side_effect=[None, "internal"]):
            with patch.object(publication, "remote_digest", return_value="sha256:expected"):
                with patch.object(publication.subprocess, "run") as copy:
                    publication.publish_entry(row, Path("/unused"), "unused")
                    self.assertIn("--preserve-digests", copy.call_args.args[0])
                    self.assertEqual(row["status"], "published")

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
    def test_public_permission_is_exact_and_never_allows_unknown(self):
        repository = "ghcr.io/allenneuraldynamics/pophys-dff"
        for visibility, allowed, accepted in (
            ("public", [repository], True),
            ("public", ["ghcr.io/allenneuraldynamics/pophys-nwb"], False),
            ("unknown", [repository], False),
        ):
            with self.subTest(visibility=visibility, allowed=allowed):
                with patch.object(publication.urllib.request, "urlopen",
                                  return_value=io.BytesIO(json.dumps({"visibility": visibility}).encode())):
                    if accepted:
                        self.assertEqual(publication.package_visibility(
                            repository, "unused", allowed), "public")
                    else:
                        with self.assertRaisesRegex(ValueError, "Refusing"):
                            publication.package_visibility(repository, "unused", allowed)

    def test_subset_must_be_explicit_and_complete(self):
        manifest = {"images": [{"stage": "DFF"}], "failures": [], "stages": ["DFF"]}
        self.assertEqual(publication.publication_entries(manifest, {"DFF": {}}), manifest["images"])
        with self.assertRaises(ValueError):
            publication.publication_entries(manifest, {"DFF": {}, "DECROSSTALK_SPLIT": {}})
        for images in ([], [{"stage": "DFF"}, {"stage": "DFF"}], [{"stage": "UNKNOWN"}]):
            with self.subTest(images=images), self.assertRaises(ValueError):
                publication.publication_entries({**manifest, "images": images}, {"DFF": {}})
        with self.assertRaises(ValueError):
            publication.publication_entries({**manifest, "failures": ["bad"]}, {"DFF": {}})

    def test_public_permission_survives_pre_and_post_copy_checks(self):
        repository = "ghcr.io/allenneuraldynamics/pophys-dff"
        row = {"image": repository + ":candidate-test", "digest": "sha256:expected",
               "archive": ".image-work/test/image.tar"}
        with patch.object(publication, "package_visibility", return_value="public") as visibility:
            with patch.object(publication, "remote_digest", side_effect=[None, "sha256:expected"]):
                with patch.object(publication.subprocess, "run"):
                    publication.publish_entry(row, Path("/unused"), "unused", [repository])
        self.assertEqual(row["status"], "published")
        self.assertEqual(visibility.call_count, 2)
        for call in visibility.call_args_list:
            self.assertEqual(call.args[2], [repository])

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

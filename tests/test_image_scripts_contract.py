import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
ENVIRONMENT = ROOT / "environment"
IMAGE_INFO = ROOT / ".github" / "scripts" / "image_info.sh"
REGISTRY = "ghcr.io/allenneuraldynamics"


def run_with_docker_stub(command, root: Path):
    """Run command with a logging docker stub first on PATH; return the result and the logged calls."""
    log = root / "docker.log"
    stub = root / "bin" / "docker"
    stub.parent.mkdir()
    stub.write_text(f'#!/usr/bin/env bash\necho "$@" >> "{log}"\n')
    stub.chmod(0o755)
    if not os.access(stub, os.X_OK):  # PATH lookup would skip the stub and reach a real docker
        raise unittest.SkipTest("the temporary directory does not allow executables")
    env = {**os.environ, "PATH": f"{stub.parent}{os.pathsep}{os.environ['PATH']}"}
    result = subprocess.run(command, capture_output=True, text=True, env=env)
    calls = [line.split() for line in log.read_text().splitlines()] if log.exists() else []
    return result, calls


@unittest.skipUnless(shutil.which("jq"), "the image scripts need jq")
class ImageScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.recipes = json.loads((ENVIRONMENT / "images.json").read_text())

    def pull(self, *args, custom=None):
        """Run pull_pipeline_images.sh in a copy of the repo layout; return the result and pulled images."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for relative in ("scripts/pull_pipeline_images.sh", "environment/images.json"):
                (root / relative).parent.mkdir(exist_ok=True)
                shutil.copy(ROOT / relative, root / relative)
            (root / "pipeline").mkdir()
            if custom is not None:
                (root / "pipeline/images_custom.env").write_text(custom)
            script = root / "scripts/pull_pipeline_images.sh"
            result, calls = run_with_docker_stub(["bash", str(script), "--engine", "docker", *args], root)
        return result, [call[-1] for call in calls]

    def push(self, *args):
        with tempfile.TemporaryDirectory() as tmp:
            return run_with_docker_stub(["bash", str(ENVIRONMENT / "push_all.sh"), *args], Path(tmp))

    def test_pull_names_images_from_images_json_and_the_tag(self):
        result, pulled = self.pull("--tag", "9.9.9")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            sorted(pulled),
            sorted(f"{REGISTRY}/{recipe['image_name']}:9.9.9" for recipe in self.recipes.values()),
        )

    def test_pull_applies_custom_overrides_to_the_selected_steps(self):
        result, pulled = self.pull(
            "--tag", "9.9.9", "--steps", "CONVERTER,DFF",
            custom="# local build\nCONVERTER=localhost/pophys-converter:dev\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(pulled, ["localhost/pophys-converter:dev", f"{REGISTRY}/pophys-dff:9.9.9"])

    def test_pull_rejects_unknown_steps_before_pulling(self):
        result, pulled = self.pull("--tag", "9.9.9", "--steps", "NOPE")
        self.assertEqual((result.returncode, pulled), (65, []))

    def test_push_tags_latest_only_for_the_main_target(self):
        repo = f"{REGISTRY}/pophys-converter"
        result, calls = self.push("4.0.0", "main", "CONVERTER")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            calls,
            [["push", f"{repo}:4.0.0"], ["tag", f"{repo}:4.0.0", f"{repo}:latest"], ["push", f"{repo}:latest"]],
        )
        result, calls = self.push("4.0.0", "dev", "CONVERTER")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [["push", f"{repo}:4.0.0-dev"]])
        self.assertIn("with tag 4.0.0-dev", result.stdout)

    def test_push_rejects_an_unknown_target_or_image_before_calling_docker(self):
        for args in ((), ("4.0.0", "staging", "CONVERTER"), ("4.0.0", "main", "NOPE")):
            with self.subTest(args=args):
                result, calls = self.push(*args)
                self.assertEqual((result.returncode, calls), (1, []))

    @unittest.skipUnless(
        shutil.which("git") and shutil.which("sha256sum"), "image_info.sh needs git and sha256sum"
    )
    def test_image_info_describes_every_stage_as_main_pulls_it(self):
        def run(*args):
            return subprocess.run([str(IMAGE_INFO), *args], cwd=ROOT, capture_output=True, text=True)

        def info(*args):
            result = run(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()

        for stage, recipe in self.recipes.items():
            with self.subTest(stage=stage):
                self.assertEqual(info(stage, "name"), f"{REGISTRY}/{recipe['image_name']}")
                self.assertEqual(info(stage, "dockerfile"), recipe["dockerfile"])
                self.assertEqual(info(stage, "python"), recipe["python"])
                self.assertTrue((ENVIRONMENT / "stages" / info(stage, "stage_dir")).is_dir())
                self.assertRegex(info(stage, "hash"), r"^[0-9a-f]{16}$")
        for args in (("NOPE", "name"), ("DFF", "nope")):
            self.assertEqual(run(*args).returncode, 64, args)
        main = (ROOT / "pipeline" / "main.nf").read_text()
        self.assertIn(f'"{REGISTRY}/${{entry.image_name}}:', main)


if __name__ == "__main__":
    unittest.main()

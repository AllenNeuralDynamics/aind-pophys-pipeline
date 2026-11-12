import re
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
MAIN = (ROOT / "pipeline" / "main.nf").read_text()
WORKFLOWS = ROOT / ".github" / "workflows"


def function_body(text: str, name: str) -> str:
    start = text.index(f"def {name}(")
    return text[start:text.index("\n}\n", start)]


class ContainerTagTests(unittest.TestCase):
    def test_tag_resolution_order(self):
        body = function_body(MAIN, "resolve_container_tag")
        positions = [
            body.index("params.container_tag"),
            body.index("System.getenv('CONTAINER_TAG')"),
            body.index('PIPELINE_VERSION = "([^"]+)"'),
        ]
        self.assertEqual(positions, sorted(positions))
        self.assertIn('file("${baseDir}/nextflow.config")', body)
        self.assertIn("throw new IllegalArgumentException", body)

    def test_tag_is_resolved_before_images(self):
        self.assertLess(
            MAIN.index("params.container_tag = resolve_container_tag()"),
            MAIN.index("params.stage_images = parse_stage_images(image_stages, params.container_tag)"),
        )

    def test_code_ocean_config_holds_the_release_version(self):
        config = (ROOT / "pipeline" / "nextflow.config").read_text()
        self.assertRegex(config, r'(?m)^\s*PIPELINE_VERSION = "\d+\.\d+\.\d+"$')

    def test_no_version_file(self):
        self.assertFalse((ROOT / "pipeline" / "pipeline_version.txt").exists())
        for path in [ROOT / "pipeline" / "preflight.sh", ROOT / "scripts" / "pull_pipeline_images.sh"]:
            self.assertNotIn("pipeline_version.txt", path.read_text(), path)

    def test_pull_script_defaults_to_the_release_version(self):
        script = (ROOT / "scripts" / "pull_pipeline_images.sh").read_text()
        self.assertIn('TAG="${CONTAINER_TAG:-}"', script)
        self.assertIn("PIPELINE_VERSION", script)
        self.assertIn('"$PIPELINE_DIR/nextflow.config"', script)

    def test_push_script_pushes_only_the_named_tags(self):
        script = (ROOT / "environment" / "push_all.sh").read_text()
        self.assertNotIn("--all-tags", script)
        self.assertIn('docker push "$REPO:$CONTAINER_TAG_ARG"', script)
        self.assertIn('docker push "$REPO:latest"', script)


class WorkflowTests(unittest.TestCase):
    def read(self, name: str) -> str:
        return (WORKFLOWS / name).read_text()

    def test_release_workflow_uses_the_organization_version_bump(self):
        self.assertIn(
            "uses: AllenNeuralDynamics/.github/.github/workflows/release-tag-and-publish-pipeline.yml@main",
            self.read("release.yml"),
        )

    def test_dev_pull_requests_build_dev_images(self):
        workflow = self.read("pr-dev.yml")
        self.assertIn("branches: [dev, multi-backend-alignment]", workflow)
        self.assertIn("uses: ./.github/workflows/_build-images.yml", workflow)
        self.assertRegex(workflow, r"with:\n\s+tag: dev\n")
        self.assertIn("python -m unittest discover -s tests -t .", workflow)
        self.assertIn("name: ci-ok", workflow)

    def test_release_pull_requests_check_dev_images(self):
        workflow = self.read("pr-main.yml")
        self.assertIn("github.head_ref != 'dev'", workflow)
        self.assertIn('"docker://$NAME:dev"', workflow)
        self.assertIn("org.aind.env-hash", workflow)
        self.assertNotIn("skopeo copy", workflow)

    def test_releases_promote_dev_images(self):
        workflow = self.read("promote-images.yml")
        self.assertRegex(workflow, r"workflow_run:\n\s+workflows: \[Release\]")
        self.assertIn("github.event.workflow_run.conclusion == 'success'", workflow)
        self.assertIn("pipeline/nextflow.config", workflow)
        self.assertIn('for tag in "$VERSION" latest; do', workflow)
        self.assertLess(workflow.index("REMOTE_HASH"), workflow.index("skopeo copy"))

    def test_no_version_file_workflows_remain(self):
        for name in ["build-images.yml", "pr-tests.yml"]:
            self.assertFalse((WORKFLOWS / name).exists(), name)
        self.assertFalse((ROOT / ".github" / "scripts" / "check_version.py").exists())
        for path in WORKFLOWS.glob("*.yml"):
            self.assertNotRegex(path.read_text(), r"pipeline_version|check_version", path.name)


if __name__ == "__main__":
    unittest.main()

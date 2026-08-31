import re
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
PIPELINE = ROOT / "pipeline"
MANIFEST = PIPELINE / "capsule_versions.env"
MAIN = PIPELINE / "main.nf"

STAGES = (
    "CONVERTER",
    "MOTION_CORRECTION",
    "MOVIE_QC",
    "DECROSSTALK_SPLIT",
    "DECROSSTALK_ROI_IMAGES",
    "EXTRACTION",
    "DFF",
    "OASIS",
    "CLASSIFIER",
    "NWB",
    "AGGREGATOR",
)
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def read_manifest(path: Path) -> dict[str, str]:
    values = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not key:
            raise AssertionError(f"Invalid manifest line: {raw_line}")
        if key in values:
            raise AssertionError(f"Duplicate manifest key: {key}")
        values[key] = value.strip().strip('"').strip("'")
    return values


class PipelineContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = read_manifest(MANIFEST)
        cls.main = MAIN.read_text()

    def test_manifest_declares_every_stage(self):
        for stage in STAGES:
            self.assertIn(f"{stage}_CAPSULE_SOURCE_MODE", self.manifest)
            self.assertTrue(self.manifest[f"{stage}_IMAGE_CO"])
            mode = self.manifest[f"{stage}_CAPSULE_SOURCE_MODE"]
            if mode == "git":
                self.assertTrue(self.manifest[f"{stage}_CAPSULE_REPO"].startswith("https://"))
                self.assertRegex(self.manifest[f"{stage}_CAPSULE_COMMIT"], SHA_RE)
                self.assertRegex(self.manifest[f"{stage}_LIBRARY_COMMIT"], SHA_RE)
            else:
                self.assertEqual(mode, "published")
                self.assertTrue(self.manifest[f"{stage}_CAPSULE_ID"])
                self.assertTrue(self.manifest[f"{stage}_REF"])

    def test_main_uses_manifest_image_map(self):
        self.assertNotIn("import groovy.json.JsonSlurper", self.main)
        for stage in STAGES:
            self.assertIn(f"params.stage_images['{stage}']", self.main)
            capsule_id = self.manifest.get(f"{stage}_CO_CAPSULE_ID")
            if capsule_id:
                if self.manifest[f"{stage}_CAPSULE_SOURCE_MODE"] == "published":
                    self.assertIn(f"params.versions['{stage}_CO_CAPSULE_ID']", self.main)
                else:
                    self.assertIn(capsule_id, self.main)

    def test_git_source_stages_use_sha_checkout_helper(self):
        self.assertIn("def gitCloneFunction", self.main)
        self.assertIn("git -C capsule-repo -c core.fileMode=false checkout", self.main)
        for stage in STAGES:
            if self.manifest[f"{stage}_CAPSULE_SOURCE_MODE"] == "git":
                self.assertIn(f"{stage}_CAPSULE_REPO", self.main)
                self.assertIn(f"{stage}_CAPSULE_COMMIT", self.main)

    def test_published_holdouts_use_manifest_identity_and_ref(self):
        for stage in ("DECROSSTALK_SPLIT", "AGGREGATOR"):
            self.assertIn(f"params.versions['{stage}_CAPSULE_ID']", self.main)
            self.assertIn(f"params.versions['{stage}_REF']", self.main)
            self.assertIn(f"params.versions['{stage}_CO_CAPSULE_ID']", self.main)

    def test_v2_fan_in_contract_remains_present(self):
        self.assertIn("stageAs: 'processing_??/*'", self.main)
        self.assertIn("stageAs: 'quality_control_??/*'", self.main)
        self.assertIn(".flatten().filter", self.main)
        self.assertIn("publishRelativeSkipRunLevel", self.main)

    def test_backend_configs_declare_expected_executor_and_gpu(self):
        code_ocean = (PIPELINE / "nextflow.config").read_text()
        local = (PIPELINE / "nextflow_local.config").read_text()
        slurm = (PIPELINE / "nextflow_slurm.config").read_text()
        self.assertIn("params.backend = 'codeocean'", code_ocean)
        self.assertIn("accelerator = 1", code_ocean)
        self.assertIn("params.backend = 'local'", local)
        self.assertIn("executor = 'local'", local)
        self.assertIn("params.backend = 'slurm'", slurm)
        self.assertIn("executor = 'slurm'", slurm)
        self.assertIn("clusterOptions = '--gres=gpu:1'", slurm)
        self.assertIn('containerOptions = "--nv ${data_bind}"', slurm)
        self.assertNotIn('--shm-size', slurm)
        self.assertIn('--volume ${data_path}:/tmp/data', local)
        self.assertIn('--bind ${data_path}:/tmp/data', slurm)

    def test_process_resources_are_configured_outside_main(self):
        directives = re.findall(r"^\s*(?:cpus|memory|accelerator|label)\b", self.main, re.MULTILINE)
        self.assertEqual(directives, [])


if __name__ == "__main__":
    unittest.main()

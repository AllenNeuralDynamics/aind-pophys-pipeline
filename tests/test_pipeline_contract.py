import json
import re
import subprocess
import tempfile
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
        cls.baseline = json.loads((PIPELINE / "baseline.json").read_text())

    def test_manifest_declares_every_stage(self):
        for stage in STAGES:
            self.assertIn(f"{stage}_CAPSULE_SOURCE_MODE", self.manifest)
            self.assertTrue(self.manifest[f"{stage}_IMAGE_CO"])
            mode = self.manifest[f"{stage}_CAPSULE_SOURCE_MODE"]
            if mode == "git":
                self.assertTrue(self.manifest[f"{stage}_CAPSULE_REPO"].startswith("https://"))
                self.assertRegex(self.manifest[f"{stage}_CAPSULE_COMMIT"], SHA_RE)
                self.assertRegex(self.manifest[f"{stage}_LIBRARY_COMMIT"], SHA_RE)
            elif mode == "published":
                self.assertTrue(self.manifest[f"{stage}_CAPSULE_ID"])
                self.assertTrue(self.manifest[f"{stage}_REF"])
            else:
                self.assertEqual(mode, "co_git")
                self.assertTrue(self.manifest[f"{stage}_CAPSULE_ID"])
                self.assertRegex(self.manifest[f"{stage}_CAPSULE_COMMIT"], r"^[0-9a-f]{7,40}$")

    def test_main_uses_manifest_image_map(self):
        self.assertNotIn("import groovy.json.JsonSlurper", self.main)
        for stage in STAGES:
            self.assertIn(f"params.stage_images['{stage}']", self.main)
            capsule_id = self.manifest.get(f"{stage}_CO_CAPSULE_ID")
            if capsule_id:
                if self.manifest[f"{stage}_CAPSULE_SOURCE_MODE"] in ("published", "co_git"):
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
        for stage in ("DECROSSTALK_SPLIT",):
            self.assertIn(f"params.versions['{stage}_CAPSULE_ID']", self.main)
            self.assertIn(f"params.versions['{stage}_REF']", self.main)
            self.assertIn(f"params.versions['{stage}_CO_CAPSULE_ID']", self.main)

    def test_co_internal_aggregator_uses_pinned_upgrade_capsule(self):
        self.assertEqual(self.manifest["AGGREGATOR_CAPSULE_SOURCE_MODE"], "co_git")
        self.assertEqual(self.manifest["AGGREGATOR_CAPSULE_ID"], "7054171")
        self.assertEqual(self.manifest["AGGREGATOR_CAPSULE_COMMIT"], "b2ecb5d")
        self.assertIn(
            "git -C capsule-repo checkout ${params.versions['AGGREGATOR_CAPSULE_COMMIT']} --quiet",
            self.main,
        )
        self.assertNotIn("AGGREGATOR_REF", self.main)
        self.assertIn("--upgrade_legacy_metadata", self.main)

    def test_source_pins_match_selected_baseline(self):
        pins = self.baseline["stage_source_pins"]
        git_stages = {
            stage for stage in STAGES if self.manifest[f"{stage}_CAPSULE_SOURCE_MODE"] == "git"
        }
        self.assertEqual(set(pins), git_stages)
        for stage, (capsule, library) in pins.items():
            self.assertEqual(self.manifest[f"{stage}_CAPSULE_COMMIT"], capsule)
            self.assertEqual(self.manifest[f"{stage}_LIBRARY_COMMIT"], library)

    def test_baseline_records_debug_evidence_without_changing_defaults(self):
        self.assertEqual(self.baseline["parameters"]["debug"], "True")
        self.assertEqual(self.baseline["parameters"]["aggregate_quality_control"], "0")
        self.assertFalse(self.baseline["evidence_scope"]["full_length"])
        self.assertNotIn("STOP_AFTER_CONVERTER", self.main)
        parameters = json.loads((ROOT / "pipeline_parameters.json").read_text())
        self.assertEqual(parameters["debug"], "0")
        self.assertEqual(parameters["upgrade_legacy_metadata"], "True")
        panel = json.loads((ROOT / ".codeocean/app-panel.json").read_text())
        defaults = {p["param_name"]: p["default_value"] for p in panel["parameters"]}
        self.assertEqual(defaults["upgrade_legacy_metadata"], "True")
        self.assertEqual(defaults["aggregate_quality_control"], "1")

    def test_model_mounts_and_process_inputs_match(self):
        datasets = json.loads((ROOT / ".codeocean/datasets.json").read_text())
        actual = {d["mount"]: d["id"] for d in datasets["attached_datasets"]}
        for asset in self.baseline["data_assets"]:
            if asset["mount"] != "ophys_mount":
                self.assertEqual(actual[asset["mount"]], asset["id"])
        for stage, assets in {
            "EXTRACTION": "attached:cellpose_models",
            "DECROSSTALK_ROI_IMAGES": "attached:cellpose_models",
            "CLASSIFIER": "attached:2p_roi_classifier,attached:roinet",
        }.items():
            self.assertEqual(self.manifest[f"{stage}_RUNTIME_ASSETS"], assets)
        self.assertEqual(self.main.count('ln -s "/tmp/data/cellpose_models"'), 2)
        self.assertIn('ln -s "/tmp/data/roinet"', self.main)
        self.assertEqual(self.main.count("cellpose_data.collect().ifEmpty([])"), 3)
        self.assertEqual(self.main.count("roinet_data.collect().ifEmpty([])"), 1)

    def test_upstream_metadata_is_routed_to_both_consumers(self):
        self.assertEqual(
            self.main.count("converter_processing_json.flatten().collect().ifEmpty([])"), 2
        )
        self.assertEqual(
            self.main.count("path(upstream_processing_json, stageAs: 'processing_??/*')"), 2
        )
        self.assertIn("nwb_upstream_processing_json", self.main)
        self.assertIn('d="capsule/data/processed/\\$(dirname "\\$f")"', self.main)

    def test_metadata_staging_preserves_same_named_documents(self):
        for process, destination in (
            ("motion_correction", "capsule/data"),
            ("ophys_nwb", "capsule/data/processed"),
            ("pipeline_processing_metadata_aggregator", "capsule/data"),
        ):
            with self.subTest(process=process), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for number in (1, 2):
                    path = root / f"processing_{number:02d}/processing.json"
                    path.parent.mkdir()
                    path.write_text(json.dumps({"source": number}))
                block = re.search(
                    rf"^process {process} \{{(.*?)^\}}", self.main, re.MULTILINE | re.DOTALL
                ).group(1)
                helper = re.search(
                    r"    stage_nested\(\) \{.*?^    \}", block, re.MULTILINE | re.DOTALL
                ).group(0).replace("\\$", "$")
                subprocess.run(
                    ["bash", "-eu", "-c", helper + "\nstage_nested processing_01/processing.json processing_02/processing.json"],
                    cwd=root,
                    check=True,
                    capture_output=True,
                    text=True,
                )
                for number in (1, 2):
                    path = root / destination / f"processing_{number:02d}/processing.json"
                    self.assertEqual(json.loads(path.read_text()), {"source": number})

    def test_active_image_recipe_matches_manifest(self):
        environment = ROOT / "environment"
        active = [
            row.split("\t") for row in (environment / "images.tsv").read_text().splitlines()
            if row and not row.startswith("#")
        ]
        self.assertTrue(active)
        for stage, dockerfile, _, tag, _ in active:
            self.assertTrue(self.manifest[f"{stage}_CAPSULE_COMMIT"].startswith(tag))
            source = (environment / dockerfile).read_text()
            self.assertIn(
                f".git@{self.manifest[f'{stage}_LIBRARY_COMMIT'][:7]}#egg=", source
            )

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

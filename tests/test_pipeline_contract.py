import json
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
        cls.baseline = json.loads((PIPELINE / "baseline.json").read_text())

    def test_manifest_declares_every_stage(self):
        for stage in STAGES:
            self.assertIn(f"{stage}_CAPSULE_SOURCE_MODE", self.manifest)
            self.assertTrue(self.manifest[f"{stage}_IMAGE_CO"])
            mode = self.manifest[f"{stage}_CAPSULE_SOURCE_MODE"]
            if mode == "git":
                self.assertTrue(self.manifest[f"{stage}_CAPSULE_REPO"].startswith("https://"))
                self.assertRegex(self.manifest[f"{stage}_CAPSULE_COMMIT"], SHA_RE)
                library_commit = self.manifest.get(f"{stage}_LIBRARY_COMMIT")
                if library_commit:
                    self.assertRegex(library_commit, SHA_RE)
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
                    self.assertTrue(
                        capsule_id in self.main
                        or f"params.versions['{stage}_CO_CAPSULE_ID']" in self.main
                    )

    def test_development_images_match_complete_published_inventory(self):
        images = read_manifest(PIPELINE / "development_images.env")
        inventory = json.loads((ROOT / "environment/procps-fleet-inventory.json").read_text())
        expected = {
            row["stage"]: row["image"].rsplit(":", 1)[0] + "@" + row["platform_manifest_digest"]
            for row in inventory["images"]
        }
        self.assertEqual(len(expected), 10)
        expected["DECROSSTALK_SPLIT"] = (
            "ghcr.io/allenneuraldynamics/pophys-decrosstalk-split@"
            "sha256:c6ab7e57139ad47074aa15599f3a6d1aee41db05e1c2bdf8da21aebaf3e111b6"
        )
        self.assertEqual(set(images), set(STAGES))
        self.assertEqual(images, expected)
        for image in images.values():
            self.assertRegex(image, r"^ghcr\.io/allenneuraldynamics/pophys-[a-z-]+@sha256:[0-9a-f]{64}$")

    def test_development_selection_is_explicit_and_fail_closed(self):
        self.assertIn("params.image_set = 'default'", self.main)
        self.assertIn("image_set in ['default', 'development-ghcr']", self.main)
        self.assertIn("development_images.keySet() != image_stages.toSet()", self.main)
        self.assertIn("image_set == 'default' && backend == 'codeocean' && registry_host", self.main)
        self.assertIn(': params.versions["${stage}${image_suffix}"]', self.main)
        panel = json.loads((ROOT / ".codeocean/app-panel.json").read_text())
        parameters = {p["param_name"]: p for p in panel["parameters"]}
        self.assertEqual(len(parameters), len(panel["parameters"]))
        self.assertEqual(parameters["image_set"]["default_value"], "default")
        self.assertEqual(parameters["image_set"]["extra_data"], ["default", "development-ghcr"])
        self.assertEqual(parameters["ophys_mount_url"]["default_value"],
                         re.search(r"params.ophys_mount_url = '([^']+)'", self.main).group(1))
        self.assertIn("ophys_mount_url must be a nonempty S3 URL or absolute directory", self.main)

    def test_runtime_parameters_load_before_source_and_image_resolution(self):
        self.assertIn("params.params_file = params.params_file ?: System.getenv('PARAMS_FILE') ?: null",
                      self.main)
        self.assertIn("load_pipeline_parameters()\nvalidate_runtime_paths()", self.main)
        self.assertLess(
            self.main.index("load_pipeline_parameters()"),
            self.main.index("params.versions = parse_capsule_versions()"),
        )
        self.assertLess(
            self.main.index("load_pipeline_parameters()"),
            self.main.index("def image_suffix"),
        )
        workflow = self.main.split("workflow {", 1)[1]
        self.assertNotIn("JsonSlurper", workflow)

    def test_runtime_path_contract_is_explicit_and_fail_closed(self):
        for name, default in (
            ("input_dir", "/data"),
            ("output_dir", "/results"),
            ("temp_dir", "/scratch"),
        ):
            self.assertIn(f"params.{name} = '{default}'", self.main)
            self.assertIn(f"params.{name}", self.main)
        self.assertIn("must be an absolute container path without whitespace", self.main)
        self.assertIn("params.params_file", self.main)

    def test_local_source_uses_explicit_mount_directory(self):
        self.assertIn("def use_s3_source = source.startsWith('s3://')", self.main)
        self.assertIn("Channel.fromPath(source, type: 'dir', checkIfExists: true)", self.main)
        self.assertNotIn("Channel.fromPath(\"${base_path}harvard-single\", type: 'dir')", self.main)

    def test_git_source_stages_use_sha_checkout_helper(self):
        self.assertIn("def gitCloneFunction", self.main)
        self.assertIn("git -C capsule-repo -c core.fileMode=false checkout", self.main)
        for stage in STAGES:
            if self.manifest[f"{stage}_CAPSULE_SOURCE_MODE"] == "git":
                self.assertIn(f"{stage}_CAPSULE_REPO", self.main)
                self.assertIn(f"{stage}_CAPSULE_COMMIT", self.main)

    def test_splitter_uses_github_source_pin(self):
        stage = "DECROSSTALK_SPLIT"
        self.assertEqual(self.manifest[f"{stage}_CAPSULE_SOURCE_MODE"], "git")
        self.assertEqual(
            self.manifest[f"{stage}_CAPSULE_REPO"],
            "https://github.com/AllenNeuralDynamics/aind-ophys-decrosstalk-split-session-json",
        )
        self.assertRegex(self.manifest[f"{stage}_CAPSULE_COMMIT"], SHA_RE)
        split_process = re.search(
            r"^process decrosstalk_split_json \{(.*?)^\}",
            self.main,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(split_process)
        split_process_text = split_process.group(1)
        self.assertNotIn(f"params.versions['{stage}_REF']", split_process_text)
        self.assertNotIn("GIT_ACCESS_TOKEN", split_process_text)
        self.assertIn(
            f"clone_repo \"${{params.versions['{stage}_CAPSULE_REPO']}}\" \"${{params.versions['{stage}_CAPSULE_COMMIT']}}\"",
            split_process_text,
        )
        self.assertIn(f"params.versions['{stage}_CO_CAPSULE_ID']", self.main)

    def test_published_source_manifest_requires_identity_and_ref(self):
        for stage in ("AGGREGATOR",):
            self.assertEqual(self.manifest[f"{stage}_CAPSULE_SOURCE_MODE"], "co_git")
            self.assertIn(f"params.versions['{stage}_CAPSULE_ID']", self.main)
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
            stage for stage in STAGES
            if self.manifest[f"{stage}_CAPSULE_SOURCE_MODE"] == "git"
            and f"{stage}_LIBRARY_COMMIT" in self.manifest
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
            self.main.count(
                "path(upstream_processing_json, stageAs: 'capsule/data/processing_??/*')"
            ),
            1,
        )
        self.assertIn(
            "path(upstream_processing_json, stageAs: 'capsule/data/processed/processing_??/*')",
            self.main,
        )
        self.assertIn("nwb_upstream_processing_json", self.main)

    def test_metadata_staging_uses_numbered_task_local_paths(self):
        for stage_as in (
            "capsule/data/processing_??/*",
            "capsule/data/processed/processing_??/*",
            "capsule/data/processing_??/*",
            "capsule/data/quality_control_??/*",
        ):
            with self.subTest(stage_as=stage_as):
                self.assertIn(f"stageAs: '{stage_as}'", self.main)
        self.assertNotIn("stage_nested()", self.main)

    def test_scientific_processes_forward_resolved_task_paths(self):
        processes_with_paths = {
            "converter_capsule": ("--input_dir", "--output_dir", "--temp_dir"),
            "motion_correction": ("--input_dir", "--output_dir", "--tmp_dir"),
            "movie_qc": ("--input_dir", "--output_dir"),
            "decrosstalk_roi_images": ("--input_dir", "--output_dir", "--tmp_dir"),
            "extraction": ("--input_dir", "--output_dir", "--tmp_dir"),
            "dff_capsule": ("--input_dir", "--output_dir"),
            "oasis_event_detection": ("--input_dir", "--output_dir"),
            "classifier": ("--input_dir", "--output_dir", "--tmp_dir"),
            "ophys_nwb": ("--input_dir", "--output_dir"),
            "pipeline_processing_metadata_aggregator": ("--input_dir", "--output_dir"),
        }
        for process, flags in processes_with_paths.items():
            block = re.search(
                rf"^process {process} \{{(.*?)^\}}",
                self.main,
                re.MULTILINE | re.DOTALL,
            ).group(1)
            for flag in flags:
                self.assertIn(flag, block, process)
            self.assertIn("${task_input_dir}", block, process)
            self.assertIn("${task_output_dir}", block, process)
        self.assertNotIn("process decrosstalk_split_json", processes_with_paths)

    def test_active_image_recipe_matches_manifest(self):
        environment = ROOT / "environment"
        active = [
            row.split("\t") for row in (environment / "images.tsv").read_text().splitlines()
            if row and not row.startswith("#")
        ]
        self.assertEqual(len(active), len(STAGES))
        self.assertEqual({row[0] for row in active}, set(STAGES))
        self.assertEqual(len({row[2] for row in active}), len(STAGES))
        for stage, dockerfile, image, visibility in active:
            self.assertTrue((environment / dockerfile).is_file())
            self.assertTrue(image.startswith("ghcr.io/allenneuraldynamics/pophys-"))
            self.assertEqual(visibility, "private")
            source = json.loads(
                (environment / "stages" / stage.lower() / "source.json").read_text()
            )
            self.assertEqual(source["stage"], stage)
            self.assertEqual(source["capsule_source_mode"],
                             self.manifest[f"{stage}_CAPSULE_SOURCE_MODE"])
            expected = self.manifest.get(
                f"{stage}_CAPSULE_COMMIT", self.manifest.get(f"{stage}_REF")
            )
            self.assertEqual(source["capsule_ref"], expected)
            if stage == "DECROSSTALK_SPLIT":
                self.assertIsNone(source["library_repo"])
                self.assertIsNone(source["library_commit"])
            else:
                self.assertEqual(source["library_commit"],
                                 self.manifest[f"{stage}_LIBRARY_COMMIT"])
                self.assertRegex(source["library_commit"], SHA_RE)
                self.assertEqual(len(source["pyproject_sha256"]), 64)

    def test_v2_fan_in_contract_remains_present(self):
        self.assertIn("stageAs: 'capsule/data/processing_??/*'", self.main)
        self.assertIn("stageAs: 'capsule/data/quality_control_??/*'", self.main)
        self.assertIn(
            "stageAs: 'capsule/data/processed/processing_??/*'",
            self.main,
        )
        self.assertIn(".flatten().filter", self.main)
        self.assertIn("publishRelativeSkipRunLevel", self.main)

    def test_scientific_publication_is_durable_and_relative(self):
        for process in (
            "converter_capsule",
            "motion_correction",
            "movie_qc",
            "decrosstalk_split_json",
            "decrosstalk_roi_images",
            "extraction",
            "dff_capsule",
            "oasis_event_detection",
            "classifier",
            "ophys_nwb",
            "pipeline_processing_metadata_aggregator",
        ):
            block = re.search(
                rf"^process {process} \{{(.*?)^\}}",
                self.main,
                re.MULTILINE | re.DOTALL,
            ).group(1)
            self.assertIn("mode: 'copy'", block, process)
            self.assertIn("saveAs: publishRelative", block, process)

    def test_backend_configs_declare_expected_executor_and_gpu(self):
        code_ocean = (PIPELINE / "nextflow.config").read_text()
        local = (PIPELINE / "nextflow_local.config").read_text()
        slurm = (PIPELINE / "nextflow_slurm.config").read_text()
        self.assertIn("params.backend = 'codeocean'", code_ocean)
        classifier = re.search(
            r"^process classifier \{(.*?)^\}", self.main, re.MULTILINE | re.DOTALL
        ).group(1)
        for directive in ("cpus 16", "memory '60 GB'", "accelerator 1", "label 'gpu'"):
            self.assertIn(directive, classifier)
        self.assertIn("params.backend = 'local'", local)
        self.assertIn("executor = 'local'", local)
        self.assertIn("params.backend = 'slurm'", slurm)
        self.assertIn("executor = 'slurm'", slurm)
        self.assertIn("clusterOptions = '--gres=gpu:1'", slurm)
        self.assertIn("def writable_tmpfs = '--writable-tmpfs'", slurm)
        self.assertIn('containerOptions = "${writable_tmpfs} ${data_bind}"', slurm)
        self.assertIn('containerOptions = "${writable_tmpfs} --nv ${data_bind}"', slurm)
        self.assertNotIn('--shm-size', slurm)
        self.assertIn('--volume ${data_path}:/tmp/data', local)
        self.assertIn('--bind ${data_path}:/tmp/data', slurm)

    def test_all_backend_configs_provide_pipeline_identity(self):
        for filename in ("nextflow.config", "nextflow_local.config", "nextflow_slurm.config"):
            config = (PIPELINE / filename).read_text()
            self.assertIn('PIPELINE_NAME = "aind-pophys-pipeline"', config)
            self.assertIn('PIPELINE_VERSION = "2.0.0"', config)
            self.assertIn(
                'PIPELINE_URL = "https://github.com/AllenNeuralDynamics/aind-pophys-pipeline"',
                config,
            )

    def test_process_resources_are_configured_outside_main(self):
        main_without_gpu_processes = self.main
        for process in ("gpu_smoke", "classifier"):
            main_without_gpu_processes = re.sub(
                rf"^process {process} \{{.*?^\}}",
                "",
                main_without_gpu_processes,
                flags=re.MULTILINE | re.DOTALL,
            )
        directives = re.findall(
            r"^\s*(?:cpus|memory|accelerator|label)\b",
            main_without_gpu_processes,
            re.MULTILINE,
        )
        self.assertEqual(directives, [])

    def test_registry_probe_returns_before_scientific_inputs(self):
        workflow = self.main.split("workflow {", 1)[1]
        self.assertIn("params.ghcr_smoke_only = false", self.main)
        self.assertIn("ghcr_pull_smoke()\n        return", workflow)
        self.assertLess(workflow.index("ghcr_pull_smoke()"), workflow.index("Channel.fromPath"))
        digest = "sha256:c6ab7e57139ad47074aa15599f3a6d1aee41db05e1c2bdf8da21aebaf3e111b6"
        block = re.search(
            r"^process ghcr_pull_smoke \{(.*?)^\}", self.main, re.MULTILINE | re.DOTALL
        ).group(1)
        self.assertIn(f"pophys-decrosstalk-split@{digest}'", block)
        self.assertIn(f'"image_digest": "{digest}"', block)
        recipe = (ROOT / "environment/Dockerfile.splitter").read_text()
        self.assertIn("procps", recipe)
        self.assertIn("ps --version", recipe)
        panel = json.loads((ROOT / ".codeocean/app-panel.json").read_text())
        smoke = [p for p in panel["parameters"] if p["param_name"] == "ghcr_smoke_only"]
        self.assertEqual(len(smoke), 1)
        self.assertEqual(smoke[0]["default_value"], "false")
        self.assertEqual(smoke[0]["extra_data"], ["false", "true"])
        for filename in ("nextflow.config", "nextflow_local.config", "nextflow_slurm.config"):
            config = (PIPELINE / filename).read_text()
            block = re.search(r"withName: ghcr_pull_smoke \{(.*?)\}", config, re.DOTALL).group(1)
            for directive in ("cpus = 1", "memory = '1 GB'", "time = '10m'",
                              "errorStrategy = 'terminate'", "maxRetries = 0"):
                self.assertIn(directive, block)

    def test_gpu_probe_matches_production_resources_and_returns_before_science(self):
        workflow = self.main.split("workflow {", 1)[1]
        self.assertIn("params.gpu_smoke_only = false", self.main)
        self.assertIn("gpu_smoke()\n        return", workflow)
        self.assertLess(workflow.index("gpu_smoke()"), workflow.index("Channel.fromPath"))
        self.assertIn(
            "ghcr_smoke_only and gpu_smoke_only are mutually exclusive",
            self.main,
        )
        block = re.search(
            r"^process gpu_smoke \{(.*?)^\}", self.main, re.MULTILINE | re.DOTALL
        ).group(1)
        self.assertIn("params.stage_images['CLASSIFIER']", block)
        for directive in ("cpus 16", "memory '60 GB'", "accelerator 1", "label 'gpu'"):
            self.assertIn(directive, block)
        self.assertIn('"probe": "pophys-gpu-placement-v1"', block)
        self.assertIn("torch.cuda.is_available()", block)
        self.assertIn("nvidia-smi", block)

        panel = json.loads((ROOT / ".codeocean/app-panel.json").read_text())
        smoke = [p for p in panel["parameters"] if p["param_name"] == "gpu_smoke_only"]
        self.assertEqual(len(smoke), 1)
        self.assertEqual(smoke[0]["default_value"], "false")
        self.assertEqual(smoke[0]["extra_data"], ["false", "true"])

        code_ocean = (PIPELINE / "nextflow.config").read_text()
        config_block = re.search(
            r"withName: gpu_smoke \{(.*?)\}", code_ocean, re.DOTALL
        ).group(1)
        for directive in (
            "containerOptions = '--shm-size 4g'",
            "time = '15m'",
            "errorStrategy = 'terminate'",
            "maxRetries = 0",
        ):
            self.assertIn(directive, config_block)
        self.assertIn("maxRetries = 1", code_ocean)

        classifier_config = re.search(
            r"withName: classifier \{(.*?)\}", code_ocean, re.DOTALL
        ).group(1)
        self.assertIn("maxForks = 2", classifier_config)


if __name__ == "__main__":
    unittest.main()

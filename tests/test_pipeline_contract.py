import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
PIPELINE = ROOT / "pipeline"
ENVIRONMENT = ROOT / "environment"
MANIFEST = PIPELINE / "process_versions.env"
MAIN = PIPELINE / "main.nf"
CONFIGS = ("nextflow.config", "nextflow_local.config", "nextflow_slurm.config")

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
PROCESSES = {  # process: (stage, library module it runs)
    "converter": ("CONVERTER", "aind_pophys_converter.job"),
    "motion_correction": ("MOTION_CORRECTION", "aind_ophys_motion_correction_library.job"),
    "movie_qc": ("MOVIE_QC", "aind_ophys_movie_qc_library.job"),
    "decrosstalk_split_json": (
        "DECROSSTALK_SPLIT", "aind_ophys_decrosstalk_split_session_json_library.job"),
    "decrosstalk_roi_images": (
        "DECROSSTALK_ROI_IMAGES", "aind_ophys_decrosstalk_roi_images_library.job"),
    "extraction": ("EXTRACTION", "aind_ophys_extraction_library.job"),
    "dff": ("DFF", "aind_ophys_dff_library.job"),
    "oasis_event_detection": ("OASIS", "aind_ophys_oasis_event_detection_library.job"),
    "classifier": ("CLASSIFIER", "aind_ophys_classifier_library.job"),
    "ophys_nwb": ("NWB", "aind_ophys_nwb_library.job"),
    "pipeline_processing_metadata_aggregator": (
        "AGGREGATOR", "aind_metadata_manager.metadata_manager"),
}
TEMP_DIR_FLAGS = {  # processes that also receive the task temp directory
    "converter": "--temp_dir",
    "motion_correction": "--tmp_dir",
    "decrosstalk_roi_images": "--tmp_dir",
    "extraction": "--tmp_dir",
    "classifier": "--tmp_dir",
}
RESOURCE_EXPORTS = (  # the only CO_* exports a process makes
    "export CO_CPUS=${task.cpus}",
    "export CO_MEMORY=${task.memory ? task.memory.toBytes() : ''}",
)
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
REPO_RE = re.compile(r"^https://github\.com/AllenNeuralDynamics/[A-Za-z0-9._-]+$")
UUID_RE = re.compile(r"^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")


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


def section(pattern: str, text: str) -> str:
    match = re.search(pattern, text, re.MULTILINE | re.DOTALL)
    if match is None:
        raise AssertionError(f"Pattern not found: {pattern}")
    return match.group(1)


def process_block(main: str, name: str) -> str:
    return section(rf"^process {name} \{{(.*?)^\}}", main)


def groovy_script(main: str, name: str) -> str:
    """Return a Groovy ''' string as bash receives it: backslashes and line continuations resolved."""
    body = section(rf"def {name} = '''(.*?)'''", main)
    return re.sub(r"\\(\\|\n)", lambda match: "" if match.group(1) == "\n" else "\\", body)


def run_bash(script: str, cwd: Path, **env: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", "-e", "-c", script],
        cwd=cwd,
        capture_output=True,
        text=True,
        env={**os.environ, "PYTHON": sys.executable, **env},
    )


class MainTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.main = MAIN.read_text()

    def assert_in_order(self, text, *parts):
        """Assert that each part appears in text after the previous one."""
        position = -1
        for part in parts:
            index = text.find(part, position + 1)
            self.assertGreater(index, position, f"{part!r} is missing or out of order")
            position = index


class PipelineContractTests(MainTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.manifest = read_manifest(MANIFEST)
        cls.parameters = json.loads((ROOT / "pipeline_parameters.json").read_text())
        cls.panel = json.loads((ROOT / ".codeocean/app-panel.json").read_text())["parameters"]
        cls.panel_defaults = {p["param_name"]: p["default_value"] for p in cls.panel}

    def test_manifest_declares_every_stage_library(self):
        for stage in STAGES:
            self.assertRegex(self.manifest[f"{stage}_LIBRARY_REPO"], REPO_RE)
            self.assertRegex(self.manifest[f"{stage}_LIBRARY_COMMIT"], SHA_RE)

    def test_manifest_holds_only_library_pins(self):
        expected = {f"{stage}_{suffix}" for stage in STAGES
                    for suffix in ("LIBRARY_REPO", "LIBRARY_COMMIT")}
        self.assertEqual(set(self.manifest), expected)

    def test_main_validates_exactly_the_manifest_keys(self):
        validate = section(r"^def validate_process_versions\(versions\) \{(.*?)^\}", self.main)
        stages = re.findall(r"'([A-Z_]+)'", section(r"def stages = \[(.*?)\]", validate))
        self.assertEqual(sorted(stages), sorted(STAGES))
        for text in ('"${stage}_LIBRARY_REPO"', '"${stage}_LIBRARY_COMMIT"', SHA_RE.pattern):
            self.assertIn(text, validate)

    def test_main_defines_one_process_per_stage(self):
        processes = re.findall(r"^process (\w+) \{", self.main, re.MULTILINE)
        self.assertEqual(sorted(processes), sorted(PROCESSES))
        self.assertEqual(sorted(stage for stage, _ in PROCESSES.values()), sorted(STAGES))

    def test_processes_are_tagged_with_their_name_and_comment_their_library(self):
        for process, (stage, _) in PROCESSES.items():
            with self.subTest(process=process):
                library = self.manifest[f"{stage}_LIBRARY_REPO"].rsplit("/", 1)[1]
                self.assertIn(f"// {process}: {library}\nprocess {process} {{\n", self.main)
                self.assertRegex(process_block(self.main, process), rf"\A\s+tag '{process}'\n")

    def test_each_process_installs_its_own_library_and_runs_its_module_once(self):
        for process, (stage, module) in PROCESSES.items():
            with self.subTest(process=process):
                block = process_block(self.main, process)
                repo, commit = (f"${{params.versions['{stage}_LIBRARY_{kind}']}}"
                                for kind in ("REPO", "COMMIT"))
                self.assertEqual(block.count("install_library"), 1)
                self.assertIn(f'install_library "{repo}" "{commit}"', block)
                self.assertIn(f"def container_name = params.stage_images['{stage}']", block)
                for other in set(STAGES) - {stage}:
                    self.assertNotIn(f"'{other}_LIBRARY", block)
                    self.assertNotIn(f"params.stage_images['{other}']", block)
                self.assertEqual(re.findall(r"^\s*run_library (\S+)", block, re.MULTILINE), [module])
                self.assertEqual(block.count("${libraryFunctions}"), 1)
                self.assertEqual(block.count("cd capsule/code"), 1)
                self.assert_in_order(
                    block, "${libraryFunctions}", "install_library", "cd capsule/code", "run_library"
                )
                repo_name = self.manifest[f"{stage}_LIBRARY_REPO"].rsplit("/", 1)[1]
                self.assertEqual(module.split(".")[0], repo_name.replace("-", "_"))

    def test_library_helpers_install_the_pinned_commit_without_dependencies(self):
        helpers = " ".join(groovy_script(self.main, "libraryFunctions").split())
        self.assert_in_order(
            helpers,
            "install_library() {",
            'git clone --quiet "${repo_url}" capsule/library-source',
            'git -C capsule/library-source -c advice.detachedHead=false '
            'checkout --quiet "${commit_hash}"',
            "python -m pip install --quiet --no-deps --no-build-isolation --no-cache-dir "
            "--target capsule/library capsule/library-source",
            'export PYTHONPATH="${PWD}/capsule/library${PYTHONPATH:+:${PYTHONPATH}}"',
            "python -m pip check",
            "mkdir -p capsule/code",
            "run_library() {",
            "python -u -c 'import importlib, sys; importlib.import_module(sys.argv.pop(1)).run()' "
            '"${module}" "$@"',
        )

    def test_cellpose_models_path_is_exported_for_the_stages_that_load_models(self):
        export = 'export CELLPOSE_LOCAL_MODELS_PATH="\\${CELLPOSE_MODEL_DIR:-../data/cellpose_models}"'
        self.assertEqual(self.main.count(export), 2)
        for process in ("decrosstalk_roi_images", "extraction"):
            with self.subTest(process=process):
                self.assert_in_order(
                    process_block(self.main, process),
                    'ln -s "/tmp/data/cellpose_models" "capsule/data/cellpose_models"',
                    "cd capsule/code",
                    export,
                    "run_library",
                )

    def test_decrosstalk_stages_pair_directories_before_running(self):
        block = process_block(self.main, "decrosstalk_roi_images")
        self.assertEqual(self.main.count("${decrosstalkPairFunction}"), 1)
        self.assertEqual(block.count("stage_pair"), 1)
        self.assert_in_order(
            block, "cd capsule/code", "${decrosstalkPairFunction}", "stage_pair", "run_library"
        )
        pair = " ".join(groovy_script(self.main, "decrosstalkPairFunction").split())
        for text in ("stage_pair() {", "../data/pair*.txt",
                     'ln -sfn "../${name}" "${pair_dir}/${name}"'):
            self.assertIn(text, pair)

    def test_classifier_stages_roinet_before_running(self):
        block = process_block(self.main, "classifier")
        self.assertEqual(self.main.count("${classifierModelFunction}"), 1)
        self.assertEqual(block.count("stage_roinet"), 1)
        self.assert_in_order(
            block,
            "cd capsule/code",
            "${classifierModelFunction}",
            "stage_roinet",
            'run_library aind_ophys_classifier_library.job "\\${ROINET_ARGS[@]}"',
        )
        roinet = " ".join(groovy_script(self.main, "classifierModelFunction").split())
        for text in ("stage_roinet() {", 'ROINET_ARGS=(--roinet_dir="${work_dir}")',
                     "export TORCH_HOME="):
            self.assertIn(text, roinet)

    def test_nwb_checks_extension_schemas_before_running(self):
        block = process_block(self.main, "ophys_nwb")
        self.assertIn("stageAs: 'capsule/data/schemas/*'", block)
        self.assert_in_order(
            block,
            "cd capsule/code",
            "ndx-aibs-behavior-ophys.namespace.yaml",
            "ndx-aibs-behavior-ophys.extension.yaml",
            'test -f "../data/schemas/\\${schema}"',
            "exit 1",
            "run_library aind_ophys_nwb_library.job",
            "--extension_namespace=../data/schemas/ndx-aibs-behavior-ophys.namespace.yaml",
        )

    def test_runtime_parameters_load_before_source_and_image_resolution(self):
        self.assertIn("params.params_file = params.params_file ?: System.getenv('PARAMS_FILE') ?: null",
                      self.main)
        self.assert_in_order(
            self.main,
            "load_pipeline_parameters()\nvalidate_runtime_paths()",
            "params.versions = parse_process_versions()",
            "params.stage_images = parse_stage_images(",
        )
        workflow = self.main.split("workflow {", 1)[1]

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

    def test_converter_runs_for_every_source_and_feeds_motion_correction(self):
        workflow = self.main.split("workflow {", 1)[1]
        call = workflow.index("converter(ophys_data)")
        self.assertEqual(workflow.count("converter("), 1)
        # balanced braces before the call: it sits in the workflow body, outside every if block
        self.assertEqual(workflow.count("{", 0, call), workflow.count("}", 0, call))
        self.assertEqual(
            re.findall(r"use_s3_source\b[^\n]*", self.main),
            ["use_s3_source = source.startsWith('s3://')", "use_s3_source) {"],
        )
        self.assert_in_order(
            workflow,
            "converter(ophys_data)",
            "converter.out.converter_results",
            "motion_correction_input = converter_split.other",
            "z_stacks = converter.out.local_stacks",
        )

    def test_workflow_calls_every_process_and_reads_only_defined_ones(self):
        workflow = self.main.split("workflow {", 1)[1].split("\nprocess ", 1)[0]
        self.assertEqual(set(re.findall(r"(?m)^\s+(\w+)\(", workflow)), set(PROCESSES))
        self.assertLessEqual(set(re.findall(r"\b(\w+)\.out\.", workflow)), set(PROCESSES))

    def test_decrosstalk_runs_per_pair_with_only_that_pairs_planes_staged(self):
        inputs = section(r"^\s*input:\n(.*?)^\s*output:", process_block(self.main, "decrosstalk_roi_images"))
        self.assertEqual(
            [" ".join(line.split()) for line in inputs.splitlines() if line.strip()],
            [
                "tuple path(decrosstalk_split, stageAs: 'capsule/data/*'), "
                "path(motion_results, stageAs: 'capsule/data/*'), "
                "path(converter_files, stageAs: 'capsule/data/*')",
                "path ophys_jsons, stageAs: 'capsule/data/*'",
                "path pophys_dir, stageAs: 'capsule/data/*'",
                "path cellpose_data",
            ],
        )
        call = section(r"^ {8}(decrosstalk_roi_images\(.*?^ {8}\))", self.main)
        self.assertEqual(
            " ".join(call.split()),
            "decrosstalk_roi_images( decrosstalk_inputs, ophys_mount_jsons.collect(), "
            "ophys_mount_pophys_directory.collect(), cellpose_data.collect().ifEmpty([]) )",
        )
        channel = section(r"def decrosstalk_inputs = (.*?)^ {8}decrosstalk_roi_images\(", self.main)
        channel = " ".join(channel.split())
        self.assert_in_order(
            channel,
            "decrosstalk_split_json.out.capsule_results .flatten()",
            r".filter { it.name ==~ /pair.*\.txt/ }",
            ".combine(motion_correction.out.motion_results_all.flatten().collect().map { [it] })",
            ".combine(converter.out.converter_results_all.flatten().collect().ifEmpty([]).map { [it] })",
            ".map { pair_file, motion_dirs, converter_results ->",
            "pair_file.readLines()*.trim().findAll { it }",
            ".collect { new File(it).name }",
            "[ pair_file, motion_dirs.findAll { it.name in planes },",
            "converter_results.findAll { it.parent.name in planes }",
        )
        pair_name = re.compile(section(r"\.filter \{ it\.name ==~ /(.*?)/ \}", channel))
        for name in ("pair0.txt", "pair12.txt"):
            self.assertIsNotNone(pair_name.fullmatch(name), name)
        for name in ("pair0.json", "plane_0.txt", "xpair0.txt", "pair0.txt.bak"):
            self.assertIsNone(pair_name.fullmatch(name), name)

    def test_classifier_model_paths_default_to_the_library(self):
        for name in ("soma-classifier-path", "dendrite-classifier-path"):
            self.assertEqual(self.parameters[name], "")
            self.assertEqual(self.panel_defaults[name], "")
        self.assertIn("${soma_classifier_arg} ${dendrite_classifier_arg}", self.main)

    def test_defaults_run_the_full_pipeline_with_run_level_quality_control(self):
        self.assertEqual(self.parameters["debug"], "0")
        self.assertEqual(self.parameters["aggregate_quality_control"], "1")
        self.assertEqual(self.panel_defaults["aggregate_quality_control"], "1")

    def test_app_panel_and_parameter_file_list_only_parameters_main_reads(self):
        names = [p["param_name"] for p in self.panel]
        self.assertEqual(len(set(names)), len(names))
        self.assertEqual(set(names), set(self.parameters) | {"ophys_mount_url"})
        for name in names:
            reference = re.escape(name)
            self.assertRegex(
                self.main,
                rf"params\.{reference}\b|params\['{reference}'\]|containsKey\('{reference}'\)",
                name,
            )
        self.assertEqual(self.panel_defaults["ophys_mount_url"],
                         re.search(r"params.ophys_mount_url = '([^']+)'", self.main).group(1))
        self.assertIn("ophys_mount_url must be a nonempty S3 URL or absolute directory", self.main)

    def test_model_mounts_and_process_inputs_match(self):
        datasets = json.loads((ROOT / ".codeocean/datasets.json").read_text())["attached_datasets"]
        mounts = [d["mount"] for d in datasets]
        self.assertEqual(
            sorted(mounts),
            ["2p_roi_classifier", "cellpose_models", "ophys_mount", "roinet", "schemas"],
        )
        self.assertEqual(len({d["id"] for d in datasets}), len(datasets))
        for dataset in datasets:
            self.assertRegex(dataset["id"], UUID_RE)
        for mount in set(mounts) - {"ophys_mount"}:
            self.assertIn(f'Channel.fromPath("${{base_path}}{mount}/*"', self.main)
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
            "capsule/data/quality_control_??/*",
        ):
            with self.subTest(stage_as=stage_as):
                self.assertIn(f"stageAs: '{stage_as}'", self.main)

    def test_scientific_processes_forward_resolved_task_paths(self):
        for process in PROCESSES:
            with self.subTest(process=process):
                run = section(r"^(\s*run_library [^\n]*)$", process_block(self.main, process))
                forwarded = {"--input_dir": "${task_input_dir}", "--output_dir": "${task_output_dir}"}
                if process in TEMP_DIR_FLAGS:
                    forwarded[TEMP_DIR_FLAGS[process]] = "${task_temp_dir}"
                for flag, value in forwarded.items():
                    self.assertIn(f"{flag} {value}", run)

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
        for process in PROCESSES:
            with self.subTest(process=process):
                block = process_block(self.main, process)
                self.assertIn("mode: 'copy'", block)
                self.assertIn("saveAs: publishRelative", block)

    def test_backend_configs_declare_expected_executor_and_gpu(self):
        code_ocean = (PIPELINE / "nextflow.config").read_text()
        local = (PIPELINE / "nextflow_local.config").read_text()
        slurm = (PIPELINE / "nextflow_slurm.config").read_text()
        self.assertIn("params.backend = 'codeocean'", code_ocean)
        classifier = process_block(self.main, "classifier")
        for directive in ("cpus 16", "memory '60 GB'", "accelerator 1", "label 'gpu'"):
            self.assertIn(directive, classifier)
        self.assertIn("params.backend = 'local'", local)
        self.assertIn("executor = 'local'", local)
        self.assertIn("params.backend = 'slurm'", slurm)
        self.assertIn("executor = 'slurm'", slurm)
        self.assertIn("System.getenv('GPU_CLUSTER_OPTIONS') ?: '--gres=gpu:1'", slurm)
        self.assertEqual(slurm.count("clusterOptions = gpu_cluster_options"), 1)
        self.assertIn("def writable_tmpfs = '--writable-tmpfs'", slurm)
        self.assertIn('containerOptions = "${writable_tmpfs} ${data_bind}"', slurm)
        self.assertIn('containerOptions = "${writable_tmpfs} --nv ${data_bind}"', slurm)
        self.assertIn('--volume ${data_path}:/tmp/data', local)
        self.assertIn('--bind ${data_path}:/tmp/data', slurm)

    def test_code_ocean_config_retries_once_and_limits_the_classifier(self):
        config = (PIPELINE / "nextflow.config").read_text()
        self.assertIn("errorStrategy = 'retry'", config)
        self.assertIn("maxRetries = 1", config)
        classifier = section(r"withName: classifier \{(.*?)\}", config)
        for directive in ("containerOptions = '--shm-size 4g'", "maxForks = 2"):
            self.assertIn(directive, classifier)

    def test_all_backend_configs_provide_pipeline_identity(self):
        for filename in CONFIGS:
            config = (PIPELINE / filename).read_text()
            self.assertIn('PIPELINE_NAME = "aind-pophys-pipeline"', config)
            self.assertIn(
                'PIPELINE_URL = "https://github.com/AllenNeuralDynamics/aind-pophys-pipeline"',
                config,
            )

    def test_local_and_slurm_configs_read_the_version_from_the_code_ocean_config(self):
        code_ocean = (PIPELINE / "nextflow.config").read_text()
        self.assertRegex(code_ocean, r'PIPELINE_VERSION = "[^"]+"')
        for filename in ("nextflow_local.config", "nextflow_slurm.config"):
            with self.subTest(config=filename):
                config = (PIPELINE / filename).read_text()
                self.assertIn('new File("${projectDir}/nextflow.config").text.find(', config)
                self.assertRegex(code_ocean, section(r"\.find\(/(.*?)/\)", config))

    def test_every_backend_configures_each_process_once(self):
        for filename in CONFIGS:
            config = (PIPELINE / filename).read_text()
            self.assertEqual(sorted(re.findall(r"withName: (\w+)", config)), sorted(PROCESSES), filename)

    def test_process_resources_are_configured_outside_main(self):
        main_without_classifier = re.sub(
            r"^process classifier \{.*?^\}", "", self.main, flags=re.MULTILINE | re.DOTALL
        )
        directives = re.findall(
            r"^\s*(?:cpus|memory|accelerator|label)\b",
            main_without_classifier,
            re.MULTILINE,
        )
        self.assertEqual(directives, [])

    def test_every_process_takes_cpus_and_memory_from_its_task(self):
        for process in PROCESSES:
            with self.subTest(process=process):
                lines = [line.strip() for line in process_block(self.main, process).splitlines()]
                exports = [line for line in lines if line.startswith("export CO_")]
                self.assertEqual(exports, list(RESOURCE_EXPORTS))

    def test_every_backend_declares_cpus_and_memory_for_each_process_but_the_classifier(self):
        for filename in CONFIGS:
            config = (PIPELINE / filename).read_text()
            for process in sorted(set(PROCESSES) - {"classifier"}):
                with self.subTest(config=filename, process=process):
                    resources = section(rf"withName: {process} \{{(.*?)\}}", config)
                    self.assertRegex(resources, r"cpus = \d+")
                    self.assertRegex(resources, r"memory = '\d+ GB'")

    def test_configs_avoid_functions_newer_than_pinned_nextflow(self):
        # The config env() function needs Nextflow 25; the pipeline pins 24.10.4.
        for filename in CONFIGS:
            config = (PIPELINE / filename).read_text()
            self.assertIsNone(re.search(r"(?<![.\w])env\(", config), filename)


class ImageContractTests(MainTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.recipes = json.loads((ENVIRONMENT / "images.json").read_text())

    def test_one_image_list_serves_every_backend(self):
        image_stages = re.findall(r"'([A-Z_]+)'", section(r"def image_stages = \[(.*?)\]", self.main))
        self.assertEqual(sorted(image_stages), sorted(STAGES))
        self.assertIn("params.stage_images = parse_stage_images(image_stages", self.main)

    def test_stage_images_are_named_from_images_json_before_custom_overrides(self):
        parse = section(r"^def parse_stage_images\(.*?\) \{(.*?)^\}", self.main)
        self.assert_in_order(
            parse,
            '"${baseDir}/../environment/images.json"',
            "catalog.keySet() != image_stages.toSet()",
            'images[stage] = "ghcr.io/allenneuraldynamics/${entry.image_name}:${',
            'file("${baseDir}/images_custom.env")',
            "Unknown stages in images_custom.env",
            "must be one reference",
            "images[stage] = image",
        )
        self.assertNotIn("sha256", self.main)
        self.assertIn("pipeline/images_custom.env", (ROOT / ".gitignore").read_text().splitlines())

    def test_custom_images_must_be_one_reference_without_whitespace(self):
        parse = section(r"^def parse_stage_images\(.*?\) \{(.*?)^\}", self.main)
        reference = re.compile(section(r"image ==~ /(.*?)/\)", parse))
        digest_reference = f"ghcr.io/allenneuraldynamics/pophys-dff@sha256:{'0' * 64}"
        for image in ("localhost/pophys-dff:dev", digest_reference):
            self.assertIsNotNone(reference.fullmatch(image), image)
        for image in ("", "two words", "tab\tseparated"):
            self.assertIsNone(reference.fullmatch(image), image)

    def test_images_json_covers_every_stage_with_its_build_inputs(self):
        self.assertEqual(sorted(self.recipes), sorted(STAGES))
        self.assertEqual(len({r["image_name"] for r in self.recipes.values()}), len(STAGES))
        extraction = {stage for stage, recipe in self.recipes.items()
                      if recipe["dockerfile"] == "Dockerfile_extraction"}
        self.assertEqual(extraction, {"EXTRACTION"})
        for stage, recipe in self.recipes.items():
            with self.subTest(stage=stage):
                self.assertLessEqual({"dockerfile", "image_name", "python"}, set(recipe))
                self.assertIn(recipe["dockerfile"], ("Dockerfile_python", "Dockerfile_extraction"))
                self.assertTrue((ENVIRONMENT / recipe["dockerfile"]).is_file())
                self.assertRegex(recipe["image_name"], r"^pophys-[a-z0-9-]+$")
                self.assertRegex(recipe["python"], r"^3\.\d+$")
                for name in ("requirements.lock", "build.constraints"):
                    path = ENVIRONMENT / "stages" / stage.lower() / name
                    self.assertTrue(path.is_file() and path.stat().st_size > 0, str(path))

    def test_image_scripts_have_valid_shell_syntax(self):
        scripts = (
            ENVIRONMENT / "build_all.sh",
            ENVIRONMENT / "push_all.sh",
            ROOT / "scripts" / "pull_pipeline_images.sh",
            ROOT / ".github" / "scripts" / "image_info.sh",
        )
        for script in scripts:
            with self.subTest(script=script.name):
                result = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_environment_scripts_have_valid_python_syntax(self):
        for script in sorted(ENVIRONMENT.glob("*.py")):
            with self.subTest(script=script.name):
                compile(script.read_text(), str(script), "exec")


class LibraryScriptTests(MainTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.scripts = {
            name: groovy_script(cls.main, name)
            for name in ("libraryFunctions", "decrosstalkPairFunction", "classifierModelFunction")
        }

    def test_rendered_helper_scripts_have_valid_bash_syntax(self):
        for name, script in self.scripts.items():
            with self.subTest(script=name):
                result = subprocess.run(["bash", "-n"], input=script, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_run_library_hands_the_module_only_its_own_arguments(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "stub_module.py").write_text(
                "import json\nimport sys\n\n\ndef run():\n    print(json.dumps(sys.argv[1:]))\n"
            )
            script = (
                'python() { "$PYTHON" "$@"; }\n'
                f"{self.scripts['libraryFunctions']}\n"
                'run_library stub_module --input_dir ../data --flag "two words"'
            )
            result = run_bash(script, Path(tmp), PYTHONPATH=tmp)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout.splitlines()[-1]),
            ["--input_dir", "../data", "--flag", "two words"],
        )

    def test_stage_pair_links_the_planes_listed_in_the_pair_file(self):
        script = f"{self.scripts['decrosstalkPairFunction']}\nstage_pair"
        with tempfile.TemporaryDirectory() as tmp:
            code, data = Path(tmp) / "capsule/code", Path(tmp) / "capsule/data"
            code.mkdir(parents=True)
            for plane in ("plane_a", "plane_b"):
                (data / plane).mkdir(parents=True)
            (data / "pair0.txt").write_text(f"{data.resolve() / 'plane_a'}\nplane_b")
            self.assertEqual(run_bash(script, code).returncode, 0)
            self.assertEqual(
                sorted(path.name for path in (data / "pair0").iterdir()), ["plane_a", "plane_b"]
            )
            for plane in ("plane_a", "plane_b"):
                self.assertEqual((data / "pair0" / plane).resolve(), (data / plane).resolve())
            (data / "pair0.txt").write_text("/elsewhere/plane_a\nplane_b")
            self.assertNotEqual(run_bash(script, code).returncode, 0)
            (data / "pair0.txt").write_text("plane_a\nplane_b")
            (data / "pair1.txt").write_text("plane_a\n")
            self.assertNotEqual(run_bash(script, code).returncode, 0)
            (data / "pair1.txt").unlink()
            (data / "pair0.txt").write_text("plane_missing\n")
            self.assertNotEqual(run_bash(script, code).returncode, 0)
            (data / "pair0.txt").unlink()
            self.assertEqual(run_bash(script, code).returncode, 0)

    def test_stage_roinet_copies_a_mounted_model_and_points_torch_home(self):
        script = (
            f"{self.scripts['classifierModelFunction']}\n"
            'stage_roinet\necho "${ROINET_ARGS[*]}"\necho "${TORCH_HOME}"'
        )
        checkpoint = "roinet/torch/hub/checkpoints/convnext_tiny-983f1562.pth"
        for mounted, copied, torch_home in (
            ((), False, "capsule/scratch/roinet/torch"),
            (("roinet/ROInet.zip",), True, "capsule/scratch/roinet/torch"),
            (("2p_roi_classifier/ROInet.zip",), True, "capsule/scratch/roinet/torch"),
            (("roinet/ROInet.zip", checkpoint), True, "capsule/data/roinet/torch"),
        ):
            with self.subTest(mounted=mounted), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                (root / "capsule/code").mkdir(parents=True)
                for relative in mounted:
                    path = root / "capsule/data" / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.touch()
                result = run_bash(script, root / "capsule/code")
                self.assertEqual(result.returncode, 0, result.stderr)
                args, home = result.stdout.splitlines()[-2:]
                self.assertEqual((root / "capsule/scratch/roinet/ROInet.zip").is_file(), copied)
                if copied:
                    flag, _, value = args.partition("=")
                    self.assertEqual(flag, "--roinet_dir")
                    self.assertEqual(Path(value).resolve(), root / "capsule/scratch/roinet")
                else:
                    self.assertEqual(args, "")
                self.assertEqual(Path(home).resolve(), root / torch_home)


if __name__ == "__main__":
    unittest.main()

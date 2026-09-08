import hashlib
import importlib.util
import json
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).parents[1]
ENVIRONMENT = ROOT / "environment"


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ENVIRONMENT / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


candidates = load_script("candidates")
report = load_script("image-report")
overlay = load_script("conda-overlay-check")
fetch_sources = load_script("fetch_sources")


class ImageCandidateTests(unittest.TestCase):
    def test_exact_eleven_distinct_images_and_source_contracts(self):
        rows = candidates.validate()
        self.assertEqual(set(rows), set(candidates.STAGES))
        self.assertEqual(len({row["image"] for row in rows.values()}), 11)
        self.assertEqual({row["visibility"] for row in rows.values()}, {"private"})

    def test_private_package_guard_rejects_missing_or_public_packages(self):
        missing = SimpleNamespace(
            returncode=1, stdout="HTTP/2.0 404 Not Found\n\n{}\n", stderr=""
        )
        with patch.object(candidates.subprocess, "run", return_value=missing):
            with self.assertRaisesRegex(ValueError, "HTTP 404"):
                candidates.require_private_package(
                    "ghcr.io/allenneuraldynamics/pophys-dff"
                )
            self.assertIn(
                "absent",
                candidates.require_private_package(
                    "ghcr.io/allenneuraldynamics/pophys-dff", allow_missing=True
                ),
            )
        public = SimpleNamespace(
            returncode=0, stdout="HTTP/2.0 200 OK\n\npublic\n", stderr=""
        )
        with patch.object(candidates.subprocess, "run", return_value=public):
            with self.assertRaisesRegex(ValueError, "non-private"):
                candidates.require_private_package(
                    "ghcr.io/allenneuraldynamics/pophys-dff"
                )
        private = SimpleNamespace(
            returncode=0, stdout="HTTP/2.0 200 OK\n\nprivate\n", stderr=""
        )
        with patch.object(candidates.subprocess, "run", return_value=private):
            self.assertEqual(
                candidates.require_private_package(
                    "ghcr.io/allenneuraldynamics/pophys-dff"
                ),
                "private",
            )

    def test_selection_rejects_empty_unknown_and_duplicates(self):
        for value in ("", "UNKNOWN", "DFF,DFF", "all,DFF", "dff", "DFF;echo oops"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                candidates.selected(value)
        self.assertEqual(candidates.selected("OASIS,DFF"), ["DFF", "OASIS"])
        self.assertEqual(candidates.selected("all"), list(candidates.STAGES))

    def test_observation_parser_checks_all_tasks(self):
        lines = [
            f"[{name}@host-one] pip numpy 1.26.4\n"
            for name in candidates.LOG_NAMES
        ]
        parsed = candidates.parse_observations(lines)
        self.assertEqual(parsed["counts"]["processed"], 9)
        self.assertEqual(parsed["counts"]["failed"], 0)
        lines.append("[aind-ophys-dff@host-two] pip numpy 2.2.6\n")
        parsed = candidates.parse_observations(lines)
        self.assertIn("DFF: package lists differ between tasks", parsed["failures"])

    def test_observation_parser_rejects_malformed_and_missing_stages(self):
        parsed = candidates.parse_observations(["[aind-ophys-dff@host] pip broken\n"])
        self.assertEqual(parsed["counts"]["parse_failure"], 1)
        self.assertFalse(parsed["invariants"]["nine_stages"])

    def test_selected_observations_are_consistent_not_whole_image_freezes(self):
        evidence = json.loads((ENVIRONMENT / "observed-packages.json").read_text())
        self.assertEqual(set(evidence["stages"]), set(candidates.LOG_NAMES.values()))
        self.assertEqual(evidence["counts"]["failed"], 0)
        self.assertEqual(evidence["counts"]["parse_failure"], 0)
        self.assertEqual(evidence["counts"]["candidate"],
                         evidence["counts"]["processed"] + evidence["counts"]["skipped"])
        self.assertEqual(evidence["stages"]["DFF"]["task_count"], 8)
        self.assertEqual(evidence["stages"]["DECROSSTALK_ROI_IMAGES"]["task_count"], 4)

    def test_all_eleven_resolved_locks_remain_unbuilt(self):
        for stage in candidates.STAGES:
            status = candidates.preflight(stage)
            self.assertEqual(status["status"], "resolved")
            self.assertFalse(status["image_built"])

    def test_dependency_lock_staleness_is_rejected(self):
        with patch.object(candidates, "dependency_hash", return_value="stale"):
            with self.assertRaisesRegex(ValueError, "inputs changed"):
                candidates.preflight("DFF")

    def test_builder_tool_changes_invalidate_dependency_preflight(self):
        original = Path.read_bytes

        def changed(path):
            if path.name == "builder-requirements.txt":
                return b"pip==changed\n"
            return original(path)

        with patch.object(Path, "read_bytes", changed):
            with self.assertRaisesRegex(ValueError, "inputs changed"):
                candidates.preflight("DFF")

    def test_code_only_change_does_not_invalidate_dependency_cache_key(self):
        folder = ENVIRONMENT / "stages/dff"
        before = candidates.dependency_hash(folder)
        original = Path.read_bytes

        def changed(path):
            if path.name == "source.json":
                return b"different processing library SHA"
            return original(path)

        with patch.object(Path, "read_bytes", changed):
            self.assertEqual(candidates.dependency_hash(folder), before)

    def test_scientific_pins_and_extras_are_preserved(self):
        for stage, required in {
            "converter": ["aind-ophys-utils==0.0.8", "tifffile==2024.2.12"],
            "dff": ["aind-ophys-utils==0.1.0", "joblib==1.5.3"],
            "movie_qc": ["oasis-deconv==0.2.0", "scipy==1.15.3", "numpy==2.2.6"],
            "oasis": ["oasis-deconv==0.2.0", "scipy==1.15.3"],
            "classifier": ["roicat[all]==1.7.3", "torch==2.11.0",
                           "torchvision==0.26.0", "fused-local-corr==0.3.211", "jupyter==1.1.1"],
            "decrosstalk_roi_images": ["suite2p==0.14.3", "cellpose==2.2.3", "numpy==1.26.4"],
            "nwb": ["pynwb==4.1.0", "hdmf==6.1.0", "hdmf-zarr==0.13.0", "aind-nwb-utils==0.2.8"],
            "aggregator": ["aind-metadata-upgrader==0.17.12",
                           "aind-data-schema==2.9.0", "aind-data-schema-models==6.2.0"],
        }.items():
            lock = (ENVIRONMENT / "stages" / stage / "requirements.lock").read_text().splitlines()
            for requirement in required:
                self.assertIn(requirement, lock, stage)

    def test_processing_library_is_not_in_cached_dependencies(self):
        for stage in candidates.STAGES:
            folder = ENVIRONMENT / "stages" / stage.lower()
            source = json.loads((folder / "source.json").read_text())
            if not source["library_repo"]:
                continue
            requirements = (folder / "requirements.in").read_text()
            self.assertNotIn(source["library_commit"], requirements)
            self.assertNotIn(source["library_repo"] + ".git@", requirements)
            lock = (folder / "requirements.lock").read_text()
            self.assertNotIn(source["library_repo"] + ".git@", lock)

    def test_oasis_build_constraints_match_observed_abi(self):
        for stage in ("movie_qc", "oasis"):
            constraints = (ENVIRONMENT / "stages" / stage / "build.constraints").read_text()
            self.assertIn("numpy==2.2.6", constraints)
            self.assertIn("Cython==3.2.9", constraints)
        recipe = (ENVIRONMENT / "Dockerfile.python").read_text()
        self.assertIn("--build-constraint /opt/build.constraints", recipe)

    def test_cpu_wheels_have_verified_urls_and_no_cuda_packages(self):
        for stage in ("converter", "motion_correction", "decrosstalk_roi_images", "dff"):
            lock = (ENVIRONMENT / "stages" / stage / "requirements.lock").read_text()
            self.assertRegex(lock, r"torch @ https://download-r2\.pytorch\.org/whl/cpu/torch-.*%2Bcpu-.*#sha256=[0-9a-f]{64}")
            self.assertNotIn("nvidia-", lock)
            self.assertNotIn("cuda-toolkit", lock)

    def test_runtime_recipes_do_not_inherit_notebook_or_cuda_bases(self):
        for recipe in ("Dockerfile.python", "Dockerfile.extraction", "Dockerfile.splitter"):
            source = (ENVIRONMENT / recipe).read_text()
            self.assertNotIn("codeocean", source.lower())
            self.assertNotIn("FROM nvidia/", source)
            self.assertNotIn(" install -e ", source)
            self.assertNotIn("WORKDIR /data", source)
            self.assertIn("ca-certificates git time", source)
            if " AS runtime\n" in source:
                base = source.split(" AS runtime\n", 1)[0]
                self.assertNotIn("mkdir -p /data /results /scratch", base)
        for recipe in ("Dockerfile.python", "Dockerfile.extraction"):
            source = (ENVIRONMENT / recipe).read_text().split(" AS runtime\n", 1)[1]
            self.assertNotIn("build-essential", source)
            self.assertLess(source.index("source=/wheels"), source.index("/opt/image/source.json"))
            self.assertLess(source.index("/opt/image/source.json"), source.index("source=/library"))
            self.assertIn("--no-index --no-deps /library/*.whl", source)

    def test_manual_workflow_never_promotes_and_build_only_has_no_package_write(self):
        workflow = (ROOT / ".github/workflows/images.yml").read_text()
        worker = (ROOT / ".github/workflows/image-candidate.yml").read_text()
        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("\n  push:", workflow)
        self.assertIn("default: DECROSSTALK_SPLIT", workflow)
        build_job = workflow.split("\n  build:", 1)[1].split("\n  publish:", 1)[0]
        self.assertNotIn("packages: write", build_job)
        self.assertEqual(workflow.count("packages: write"), 1)
        self.assertIn("publish: false", build_job)
        self.assertNotIn("capsule_versions.env", worker)
        self.assertIn("provenance: false", worker)
        self.assertIn("Record digest and size", worker)
        self.assertIn("persist-credentials: false", worker)
        self.assertIn("github_token=${{ secrets.library-token }}", worker)
        self.assertIn("private-check", worker)
        self.assertNotIn("cache-to: type=gha", worker)
        self.assertIn("SERVICE_TOKEN", workflow)

    def test_size_report_validates_manifest_digest(self):
        payload = json.dumps({"schemaVersion": 2, "layers": [{"size": 10}, {"size": 20}]}).encode()
        digest = "sha256:" + hashlib.sha256(payload).hexdigest()
        result = report.summarize(lambda _: payload, digest)
        self.assertEqual(result["compressed_layer_bytes"], 30)
        self.assertEqual(result["layers"], 2)
        with self.assertRaisesRegex(ValueError, "checksum"):
            report.summarize(lambda _: payload, "sha256:" + "0" * 64)
        self.assertEqual(report.summarize(lambda _: payload + b"\n", digest), result)

    def test_size_report_selects_linux_amd64_not_attestations(self):
        payload = json.dumps({"layers": [{"size": 50}]}).encode()
        digest = "sha256:" + hashlib.sha256(payload).hexdigest()
        index = json.dumps({"manifests": [
            {"digest": digest, "platform": {"os": "linux", "architecture": "amd64"}},
            {"digest": "not-an-image", "platform": {"os": "unknown", "architecture": "unknown"}},
        ]}).encode()
        index_digest = "sha256:" + hashlib.sha256(index).hexdigest()
        blobs = {index_digest: index, digest: payload}
        self.assertEqual(report.summarize(blobs.__getitem__, index_digest)["compressed_layer_bytes"], 50)


class ExtractionOverlayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = ENVIRONMENT / "stages/extraction"
        cls.policy = json.loads((cls.folder / "overlay-policy.json").read_text())
        cls.records = json.loads((cls.folder / "conda-packages.json").read_text())
        cls.installed = overlay.conda_distribution_versions(cls.records)

    def test_explicit_conda_lock_contains_exact_builds_and_sha256(self):
        result = candidates.extraction_conda_contract(self.folder)
        self.assertTrue(result["success"])
        self.assertEqual(result["virtual_packages"]["__glibc"], "2.41")
        self.assertEqual(result["base_distribution"], "Debian trixie")
        self.assertEqual(result["counts"]["processed"], len(self.records))
        self.assertEqual(len(self.records), len({row["name"] for row in self.records}))
        names = {row["name"]: row for row in self.records}
        for name, version, build in (
            ("caiman", "1.10.3", "py310hc6cd4ac_0"),
            ("numpy", "1.26.4", "py310hb13e2d6_0"),
            ("scipy", "1.14.1", "py310ha3fb0e1_0"),
            ("h5py", "3.9.0", "nompi_py310hcca72df_101"),
            ("matplotlib-base", "3.8.0", "py310h62c0568_1"),
            ("py-opencv", "4.7.0", "py310hfdc917e_6"),
        ):
            self.assertEqual(names[name]["version"], version)
            self.assertEqual(names[name]["build_string"], build)
        for line in (self.folder / "conda-linux-64.lock").read_text().splitlines()[1:]:
            self.assertRegex(line, r"^https://conda\.anaconda\.org/conda-forge/.*#[0-9a-f]{64}$")

    def test_same_version_conda_wheels_are_excluded_not_reinstalled(self):
        wheels = [Path("numpy-1.26.4-cp310-cp310-linux_x86_64.whl"),
                  Path("scipy-1.14.1-cp310-cp310-linux_x86_64.whl")]
        selected, replacements, skipped = overlay.select_wheels(wheels, self.installed, self.policy)
        self.assertEqual(selected, [])
        self.assertEqual(replacements, [])
        self.assertEqual(skipped, ["numpy", "scipy"])

    def test_only_five_exact_historical_replacements_are_allowed(self):
        self.assertEqual(set(self.policy["replacements"]),
                         {"h5py", "matplotlib", "python-json-logger", "pyyaml", "typing-extensions"})
        for name, versions in self.policy["replacements"].items():
            self.assertEqual(self.installed[name], versions["before"])
            self.assertEqual(overlay.decide(name, versions["after"], self.installed, self.policy),
                             "replace")

    def test_unknown_replacement_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Unsafe conda overlay"):
            overlay.decide("numpy", "2.2.6", self.installed, self.policy)

    def test_allowlisted_package_with_wrong_source_or_target_is_rejected(self):
        for before, after in (("3.8.0", "3.11.0"), ("3.9.0", "3.12.0")):
            with self.subTest(before=before, after=after), self.assertRaises(ValueError):
                overlay.decide("h5py", after, {**self.installed, "h5py": before}, self.policy)

    def test_pip_only_addition_is_allowed(self):
        self.assertNotIn("imageio-ffmpeg", self.installed)
        self.assertEqual(overlay.decide("imageio-ffmpeg", "0.6.0", self.installed, self.policy),
                         "install")

    def test_caiman_and_plain_opencv_cannot_be_installed_from_pip(self):
        for name, version in (("caiman", "1.10.3"), ("opencv-python", "4.7.0.72")):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "conda-forge"):
                overlay.decide(name, version, self.installed, self.policy)

    def test_lock_keeps_full_requirements_but_overlay_excludes_satisfied_conda(self):
        lines = (self.folder / "requirements.lock").read_text().splitlines()
        selected = overlay.select_requirements(lines, self.installed, self.policy)
        identities = {overlay.requirement_identity(line)[0] for line in selected}
        self.assertTrue({"numpy", "scipy", "scikit-image"}.isdisjoint(identities))
        self.assertTrue({"imageio-ffmpeg", "h5py", "matplotlib", "torch"}.issubset(identities))
        replacements = identities.intersection(self.installed)
        self.assertEqual(replacements, set(self.policy["replacements"]))
        self.assertIn("numpy==1.26.4", lines)
        self.assertIn("scipy==1.14.1", lines)
        self.assertFalse(any(line.startswith("opencv-python==") for line in lines))
        self.assertIn("opencv-python>=4.7,<4.8", (self.folder / "requirements.in").read_text())
        self.assertIn("torch @ https://download-r2.pytorch.org/whl/cpu/", "\n".join(lines))

    def test_cv2_overlap_requires_exact_both_distribution_versions(self):
        selected, _, _ = overlay.select_wheels(
            [Path("opencv_python_headless-4.11.0.86-cp37-abi3-linux_x86_64.whl")],
            self.installed, self.policy)
        self.assertEqual(len(selected), 1)
        with self.assertRaisesRegex(ValueError, "cv2 namespace"):
            overlay.select_wheels(
                [Path("opencv_python_headless-4.12.0.88-cp37-abi3-linux_x86_64.whl")],
                self.installed, self.policy)

    def test_cv2_import_identity_is_measured_not_inferred_from_package_names(self):
        final = {**self.installed, **{
            name: entry["after"] for name, entry in self.policy["replacements"].items()
        }, "opencv-python-headless": "4.11.0.86"}
        module = SimpleNamespace(__version__="4.7.0", __file__="/site/cv2/__init__.py")
        with self.assertRaisesRegex(ValueError, "effective cv2"):
            overlay.verify_final(final, self.policy, module)
        module.__version__ = "4.11.0"
        self.assertTrue(overlay.verify_final(final, self.policy, module)["shared_namespace_risk"])

    def test_duplicate_wheels_and_missing_protected_distributions_fail(self):
        wheel = Path("h5py-3.11.0-cp310-cp310-linux_x86_64.whl")
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            overlay.select_wheels([wheel, wheel], self.installed, self.policy)
        with self.assertRaisesRegex(ValueError, "Protected"):
            overlay.select_wheels([wheel], {**self.installed, "numpy": "2.0.0"}, self.policy)

    def test_stale_conda_spec_is_rejected(self):
        original = Path.read_bytes

        def changed(path):
            return b"numpy=2.0\n" if path.name == "conda-spec.txt" else original(path)

        with patch.object(Path, "read_bytes", changed), self.assertRaisesRegex(ValueError, "stale"):
            candidates.extraction_conda_contract(self.folder)

    def test_failed_conda_solve_cannot_reuse_previous_successful_pip_lock(self):
        original = Path.read_text

        def changed(path, *args, **kwargs):
            if path.name == "conda-solve.json":
                return json.dumps({"success": False, "solver_problems": ["unsatisfiable"]})
            return original(path, *args, **kwargs)

        with patch.object(Path, "read_text", changed), self.assertRaisesRegex(ValueError, "solve failed"):
            candidates.preflight("EXTRACTION")

    def test_modified_overlay_policy_requires_resolution_again(self):
        original = Path.read_bytes

        def changed(path):
            return b"changed policy" if path.name == "overlay-policy.json" else original(path)

        with patch.object(Path, "read_bytes", changed), self.assertRaisesRegex(ValueError, "inputs changed"):
            candidates.preflight("EXTRACTION")

    def test_runtime_uses_filtered_wheels_not_a_blind_pip_glob(self):
        source = (ENVIRONMENT / "Dockerfile.extraction").read_text()
        self.assertIn("conda-overlay-check.py prepare", source)
        self.assertIn("-r /opt/pip-overlay.local.lock", source)
        self.assertIn("conda-overlay-check.py install", source)
        self.assertIn("conda-overlay-check.py verify", source)
        self.assertNotIn("--no-deps /wheels/*.whl", source)

    def test_runtime_smoke_checks_actual_library_entrypoint(self):
        source = (ENVIRONMENT / "runtime-check.py").read_text()
        for module in (
            "aind_pophys_converter.job",
            "aind_ophys_motion_correction_library.job",
            "aind_ophys_movie_qc_library.job",
            "aind_ophys_decrosstalk_roi_images_library.job",
            "aind_ophys_extraction_library.job",
            "aind_ophys_dff_library.job",
            "aind_ophys_oasis_event_detection_library.job",
            "aind_ophys_classifier_library.job",
            "aind_ophys_nwb_library.job",
            "aind_metadata_manager.metadata_manager",
        ):
            self.assertIn(module, source)
        self.assertIn("Missing callable", source)

    def test_authenticated_fetch_is_separate_from_package_builds(self):
        requirement = (
            "log-schema[cloudwatch] @ git+https://github.com/AllenNeuralDynamics/"
            "aind-log-utils.git@f09685e8b6f4228d0dd37e867b52de0286fffccb"
            "#subdirectory=python"
        )
        parsed = fetch_sources.parse_requirement(requirement)
        self.assertEqual(parsed["commit"], "f09685e8b6f4228d0dd37e867b52de0286fffccb")
        self.assertEqual(parsed["subdirectory"], "python")
        with self.assertRaises(ValueError):
            fetch_sources.parse_requirement(
                "pkg @ git+https://github.com/org/repo.git@"
                "f09685e8b6f4228d0dd37e867b52de0286fffccb#subdirectory=../src"
            )
        for recipe in ("Dockerfile.python", "Dockerfile.extraction"):
            source = (ENVIRONMENT / recipe).read_text()
            for block in source.split("RUN --mount=type=secret,id=github_token")[1:]:
                command = block.split("\nRUN ", 1)[0]
                self.assertNotIn("pip wheel", command)
                self.assertNotIn("build-library.py", command)
            self.assertIn("fetch_sources.py", source)
            self.assertIn("fetch_library.py", source)

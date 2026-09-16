import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
PIPELINE = ROOT / "pipeline"


class LaunchContractTests(unittest.TestCase):
    def test_launch_scripts_have_valid_shell_syntax(self):
        for name in ("preflight.sh", "run_local.sh", "slurm_submit.sh"):
            with self.subTest(name=name):
                subprocess.run(
                    ["bash", "-n", str(PIPELINE / name)],
                    check=True,
                    capture_output=True,
                    text=True,
                )

    def test_local_launcher_selects_local_config_and_runtime_paths(self):
        script = (PIPELINE / "run_local.sh").read_text()
        self.assertIn("nextflow_local.config", script)
        self.assertIn("--params_file", script)
        self.assertIn("--ophys_mount_url", script)
        self.assertIn("--image_set", script)
        self.assertIn("-work-dir", script)
        self.assertIn("preflight.sh\" local", script)

    def test_slurm_launcher_selects_slurm_config_and_queue(self):
        script = (PIPELINE / "slurm_submit.sh").read_text()
        self.assertIn("nextflow_slurm.config", script)
        self.assertIn("--default_queue", script)
        self.assertIn("--gpu_queue", script)
        self.assertIn("preflight.sh\" slurm", script)
        self.assertIn("#SBATCH --partition=CHANGE_ME", script)

    def test_preflight_checks_backend_runtime_and_inputs(self):
        script = (PIPELINE / "preflight.sh").read_text()
        for text in (
            "Java 17 or newer",
            "Docker executable not found",
            "Apptainer or Singularity executable not found",
            "Parameter file not found",
            "Off-CO runs require IMAGE_SET=development-ghcr",
            "development_images.env",
        ):
            self.assertIn(text, script)


if __name__ == "__main__":
    unittest.main()

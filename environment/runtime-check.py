"""Fail an image build when a step's scientific dependencies do not import."""

import importlib
import importlib.metadata
import json
import sys

IMPORTS = {
    "converter": ("numpy", "h5py", "ScanImageTiffReader"),
    "motion_correction": ("suite2p", "torch", "sbxreader", "cv2"),
    "movie_qc": ("oasis.functions", "scipy", "skimage"),
    "decrosstalk_split": ("pydantic_settings",),
    "decrosstalk_roi_images": ("suite2p", "cellpose.models"),
    "extraction": ("caiman", "suite2p", "cellpose.models", "cv2"),
    "dff": ("aind_ophys_utils", "numpy", "scipy"),
    "oasis": ("oasis.functions", "numpy", "scipy"),
    "classifier": ("roicat", "torch", "torchvision", "onnxruntime"),
    "nwb": ("pynwb", "hdmf", "hdmf_zarr"),
    "aggregator": ("pydantic_settings", "tzlocal"),
}
CPU_TORCH = ("converter", "motion_correction", "decrosstalk_roi_images", "dff", "extraction")
SCHEMA_VERSIONS = (("aind-data-schema", "2.9.0"), ("aind-data-schema-models", "6.2.0"))


def main(stage):
    for module_name in IMPORTS[stage]:
        importlib.import_module(module_name)
    if stage != "decrosstalk_split":
        for package, expected in SCHEMA_VERSIONS:
            if importlib.metadata.version(package) != expected:
                raise ValueError(f"{package} is not {expected}")
    if stage in CPU_TORCH and importlib.import_module("torch").version.cuda is not None:
        raise ValueError("CPU image unexpectedly includes CUDA torch")
    if stage == "classifier" and importlib.import_module("torch").version.cuda is None:
        raise ValueError("Classifier requires a CUDA-enabled torch")
    if stage in ("oasis", "movie_qc"):
        import numpy as np
        from oasis.functions import deconvolve

        deconvolve(np.exp(-np.arange(100, dtype=float) / 10), penalty=1)
    print(json.dumps({"stage": stage, "imports_checked": list(IMPORTS[stage])}))


if __name__ == "__main__":
    main(sys.argv[1])

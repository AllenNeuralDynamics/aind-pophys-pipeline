"""Fail image creation on missing scientific imports or incorrect library identity."""

import hashlib
import importlib
import importlib.metadata
import json
import sys
from pathlib import Path


ENTRYPOINTS = {
    "CONVERTER": ("aind_pophys_converter.job", "run"),
    "MOTION_CORRECTION": ("aind_ophys_motion_correction_library.job", "run"),
    "MOVIE_QC": ("aind_ophys_movie_qc_library.job", "run"),
    "DECROSSTALK_ROI_IMAGES": ("aind_ophys_decrosstalk_roi_images_library.job", "run"),
    "EXTRACTION": ("aind_ophys_extraction_library.job", "run"),
    "DFF": ("aind_ophys_dff_library.job", "run"),
    "OASIS": ("aind_ophys_oasis_event_detection_library.job", "run"),
    "CLASSIFIER": ("aind_ophys_classifier_library.job", "run"),
    "NWB": ("aind_ophys_nwb_library.job", "run"),
    "AGGREGATOR": ("aind_metadata_manager.metadata_manager", "run"),
}


def main():
    source = json.loads(Path("/opt/image/source.json").read_text())
    wheel = json.loads(Path("/opt/image/library-wheel.json").read_text())
    if source["library_commit"] != wheel["library_commit"]:
        raise ValueError("Installed library provenance does not match the manifest")
    if hashlib.sha256((Path("/library") / wheel["wheel"]).read_bytes()).hexdigest() != wheel["sha256"]:
        raise ValueError("Processing library wheel checksum mismatch")
    if ".".join(map(str, sys.version_info[:2])) != source["python"]:
        raise ValueError("Python runtime does not match the selected stage")
    dist = importlib.metadata.distribution(source["distribution"])
    direct = json.loads(dist.read_text("direct_url.json"))
    if direct.get("dir_info", {}).get("editable") or not direct["url"].endswith(wheel["wheel"]):
        raise ValueError("Processing library must be installed from the noneditable wheel")
    entrypoint = ENTRYPOINTS[source["stage"]]
    module = importlib.import_module(entrypoint[0])
    if not callable(getattr(module, entrypoint[1], None)):
        raise ValueError(f"Missing callable {entrypoint[1]} in {entrypoint[0]}")
    for directory in ("/data", "/results", "/scratch"):
        if not Path(directory).is_dir():
            raise ValueError(f"Missing runtime directory: {directory}")
    imports = {
        "CONVERTER": ("numpy", "h5py", "ScanImageTiffReader"),
        "MOTION_CORRECTION": ("suite2p", "torch", "sbxreader", "cv2"),
        "MOVIE_QC": ("oasis.functions", "scipy", "skimage"),
        "DECROSSTALK_ROI_IMAGES": ("suite2p", "cellpose.models"),
        "EXTRACTION": ("caiman", "suite2p", "cellpose.models", "cv2"),
        "DFF": ("aind_ophys_utils", "numpy", "scipy"),
        "OASIS": ("oasis.functions", "numpy", "scipy"),
        "CLASSIFIER": ("roicat", "torch", "torchvision", "onnxruntime"),
        "NWB": ("pynwb", "hdmf", "hdmf_zarr"),
        "AGGREGATOR": ("aind_metadata_manager.metadata_manager",),
    }
    for module_name in imports[source["stage"]]:
        importlib.import_module(module_name)
    if stage == "AGGREGATOR":
        upgrade = importlib.import_module("aind_metadata_upgrader.upgrade")
        mapping = importlib.import_module("aind_metadata_upgrader.upgrade_mapping")
        for attribute in ("TYPE_MAPPING", "UPGRADE_VERSIONS"):
            if not hasattr(upgrade, attribute):
                raise ValueError(f"Metadata upgrader is missing {attribute}")
        if not hasattr(mapping, "MAPPING"):
            raise ValueError("Metadata upgrader is missing MAPPING")
    for package, expected in (("aind-data-schema", "2.9.0"), ("aind-data-schema-models", "6.2.0")):
        if importlib.metadata.version(package) != expected:
            raise ValueError(f"Wrong baseline version of {package}")
    if stage in ("CONVERTER", "MOTION_CORRECTION", "DECROSSTALK_ROI_IMAGES", "DFF", "EXTRACTION"):
        torch = importlib.import_module("torch")
        if torch.version.cuda is not None:
            raise ValueError("CPU candidate unexpectedly includes CUDA torch")
    if stage == "CLASSIFIER":
        if importlib.import_module("torch").version.cuda is None:
            raise ValueError("Classifier requires a CUDA-enabled torch runtime")
    if stage in ("OASIS", "MOVIE_QC"):
        import numpy as np
        from oasis.functions import deconvolve
        deconvolve(np.exp(-np.arange(100, dtype=float) / 10), penalty=1)
    print(json.dumps({"stage": stage, "distribution": dist.name, "version": dist.version,
                      "library_commit": source["library_commit"], "imports_checked": True}))


if __name__ == "__main__":
    main()

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("diagrams", ROOT / "scripts/render-diagrams.py")
diagrams = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagrams)


class DiagramTests(unittest.TestCase):
    def test_collapse_stops_at_intervening_process(self):
        text = """
v0([converter_capsule])
v1(( ))
v2([motion_correction])
v3(["extraction"])
v0 --> v1
v1 --> v2
v2 --> v3
"""
        nodes, edges = diagrams.process_graph(text)
        self.assertEqual(len(nodes), 3)
        self.assertEqual(edges, {
            ("converter_capsule", "motion_correction"),
            ("motion_correction", "extraction"),
        })

    def test_multiplane_keeps_all_decrosstalk_inputs(self):
        text = (ROOT / "docs/diagrams/multiplane.mmd").read_text()
        dot, nodes, edges = diagrams.waterfall(text, "multiplane")
        self.assertEqual(len(nodes), 11)
        self.assertEqual({source for source, target in edges if target == "decrosstalk_roi_images"},
                         {"converter_capsule", "motion_correction", "decrosstalk_split_json"})
        self.assertIn("rankdir=TB", dot)
        for source in ("converter_capsule", "motion_correction", "decrosstalk_split_json"):
            self.assertIn(f"{source} -> decrosstalk_roi_images", dot)

    def test_single_has_no_splitter_or_decrosstalk(self):
        nodes, edges = diagrams.process_graph((ROOT / "docs/diagrams/single.mmd").read_text())
        self.assertEqual(len(nodes), 9)
        self.assertNotIn("decrosstalk_split_json", nodes)
        self.assertNotIn("decrosstalk_roi_images", nodes)

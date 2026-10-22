import runpy
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
CHECK = runpy.run_path(str(SCRIPTS / "lint-interface-scale"))["violations"]


class InterfaceScaleLintTests(unittest.TestCase):
    def test_raw_fonts_and_scaled_metrics_in_shared_ui_are_rejected(self):
        source = 'Text("A")\n    .font(.body)\n@ScaledMetric(relativeTo: .body) var size = 4'
        errors = CHECK(Path("RemoteCoder/UI/NewFeature.swift"), source)
        self.assertEqual(2, len(errors))
        self.assertIn("NewFeature.swift:2: Use scaledFont(_:)", errors[0])
        self.assertIn("NewFeature.swift:3: Use @InterfaceScaledMetric", errors[1])

    def test_zoom_aware_forms_ios_sources_and_the_owner_are_allowed(self):
        self.assertEqual([], CHECK(Path("RemoteCoder/UI/NewFeature.swift"), 'Text("A").scaledFont(.body).fontWeight(.bold)'))
        self.assertEqual([], CHECK(Path("RemoteCoder/Platform/iOS/Row.swift"), 'Text("A").font(.body)'))
        self.assertEqual([], CHECK(Path("Moved/Scale.swift"), 'struct InterfaceScaledMetric { @ScaledMetric var base: CGFloat }\ncontent.font(font)'))
        self.assertEqual([], CHECK(Path("RemoteCoder/UI/Note.swift"), '// .font(.body)\nlet hint = ".font(.body)"'))


if __name__ == "__main__":
    unittest.main()

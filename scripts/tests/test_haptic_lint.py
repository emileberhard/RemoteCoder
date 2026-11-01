import runpy
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
CHECK = runpy.run_path(str(SCRIPTS / "lint-haptics"))["violations"]
GLASS_CHECK = runpy.run_path(str(SCRIPTS / "lint-glass"))["violations"]


class HapticLintTests(unittest.TestCase):
    def test_new_raw_menu_is_rejected_including_qualified_and_multiline_forms(self):
        for source in ('Menu { Button("Go") {} }', 'SwiftUI.Menu\n{ Text("Go") }', 'typealias Silent = Menu<Text, Text>'):
            with self.subTest(source=source):
                self.assertTrue(CHECK(Path("RemoteCoder/UI/NewFeature.swift"), source))

    def test_shared_component_and_semantic_feedback_are_allowed(self):
        self.assertEqual([], CHECK(Path("RemoteCoder/UI/NewFeature.swift"), 'AppMenu { Text("Go") }; HapticService.shared.play(.commit)'))
        self.assertEqual([], CHECK(Path("Moved/Menu.swift"), 'struct AppMenu<Label: View, Content: View> { let menu = Menu { Text("Go") } }'))
        self.assertEqual([], CHECK(Path("Moved/Player.swift"), 'final class PreparedHapticPlayer { let engine = CHHapticEngine() }'))
        self.assertEqual([], CHECK(Path("Moved/HapticService+Shared.swift"), 'extension HapticService { let supports = CHHapticEngine.capabilitiesForHardware() }'))
        self.assertEqual([], CHECK(Path("Moved/Native.swift"), 'final class ViewHapticPlayer { let impact = UIImpactFeedbackGenerator(view: view) }'))
        self.assertTrue(CHECK(Path("RemoteCoder/UI/DesignSystem/AppMenu.swift"), 'let menu = Menu { Text("Go") }'))
        self.assertTrue(CHECK(Path("RemoteCoder/Platform/iOS/Haptics/Player.swift"), 'UIImpactFeedbackGenerator()'))

    def test_sdk_pattern_oracle_stays_with_the_haptic_service_tests(self):
        self.assertEqual([], CHECK(Path("Tests/Feedback.swift"), "struct HapticServiceTests { let key = CHHapticPattern.Key.pattern }"))
        self.assertTrue(CHECK(Path("Tests/Feedback.swift"), "struct FeatureTests { let engine = CHHapticEngine() }"))

    def test_hardware_and_recipe_bypasses_are_rejected(self):
        for source in ('UIImpactFeedbackGenerator()', 'view.sensoryFeedback(.impact, trigger: value)', 'CHHapticEngine()', 'let effect: SensoryFeedback = .success'):
            with self.subTest(source=source):
                self.assertTrue(CHECK(Path("RemoteCoder/UI/NewFeature.swift"), source))

    def test_sensory_feedback_cannot_restore_a_second_dispatch_path(self):
        for owner in ("extension HapticService", "final class ViewHapticPlayer", "struct AppPressFeedback"):
            with self.subTest(owner=owner):
                self.assertTrue(CHECK(Path("Moved/Feedback.swift"), owner + " { view.sensoryFeedback(.selection, trigger: value) }"))

    def test_comments_and_strings_do_not_trigger_the_guard_and_lines_are_preserved(self):
        source = '// Menu { }\nlet label = "Menu UIImpactFeedbackGenerator"\n/* Menu\nCHHapticEngine */\nMenu { }'
        errors = CHECK(Path("RemoteCoder/UI/NewFeature.swift"), source)
        self.assertEqual(1, len(errors))
        self.assertIn('NewFeature.swift:5:', errors[0])

    def test_glass_owner_follows_content_across_moves(self):
        source = 'struct AppGlassButtonStyle {}\nlet style = view.buttonStyle(.glassProminent)'
        self.assertEqual([], GLASS_CHECK(Path("Moved/AppGlass.swift"), source))
        self.assertTrue(GLASS_CHECK(Path("RemoteCoder/UI/DesignSystem/AppGlass.swift"), 'let style = view.buttonStyle(.glassProminent)'))


if __name__ == "__main__":
    unittest.main()

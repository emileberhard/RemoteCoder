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
        self.assertEqual([], CHECK(Path("Moved/Player.swift"), 'final class PreparedHapticPlayer { let impact = UIImpactFeedbackGenerator() }'))
        self.assertEqual([], CHECK(Path("Moved/HapticService+Shared.swift"), 'extension HapticService { func f() -> SensoryFeedback? { nil } }'))
        self.assertTrue(CHECK(Path("RemoteCoder/UI/DesignSystem/AppMenu.swift"), 'let menu = Menu { Text("Go") }'))
        self.assertTrue(CHECK(Path("RemoteCoder/Platform/iOS/Haptics/Player.swift"), 'UIImpactFeedbackGenerator()'))

    def test_hardware_and_recipe_bypasses_are_rejected(self):
        for source in ('UIImpactFeedbackGenerator()', 'view.sensoryFeedback(.impact, trigger: value)', 'CHHapticEngine()', 'let effect: SensoryFeedback = .success'):
            with self.subTest(source=source):
                self.assertTrue(CHECK(Path("RemoteCoder/UI/NewFeature.swift"), source))

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

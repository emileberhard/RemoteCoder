import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from remotecoder_tools.compaction_probe import CompactionEvidence


def turn(method, thread="probe", id="turn", status="completed"):
    return {"method": method, "params": {"threadId": thread, "turn": {"id": id, "status": status}}}


def item(method, thread="probe", turn_id="turn", id="compact"):
    return {"method": method, "params": {"threadId": thread, "turnId": turn_id,
                                        "item": {"id": id, "type": "contextCompaction"}}}


class CompactionAcceptanceTests(unittest.TestCase):
    def test_foreign_and_mismatched_completion_cannot_certify_compaction(self):
        evidence = CompactionEvidence("probe")
        evidence.accept(turn("turn/started", thread="other"))
        evidence.accept(turn("turn/started"))
        evidence.accept(item("item/started"))
        evidence.accept(item("item/completed", turn_id="other-turn"))
        evidence.accept(item("item/completed", id="other-item"))
        evidence.accept(turn("turn/completed"))
        with self.assertRaises(RuntimeError):
            evidence.verify()
        evidence.accept(item("item/completed"))
        evidence.verify()

    def test_acknowledgment_and_failed_terminal_do_not_prove_success(self):
        evidence = CompactionEvidence("probe")
        evidence.accept({"id": 1, "result": {}})
        evidence.accept(turn("turn/started"))
        evidence.accept(item("item/started"))
        evidence.accept(item("item/completed"))
        with self.assertRaises(RuntimeError):
            evidence.verify()
        evidence.accept(turn("turn/completed", status="failed"))
        with self.assertRaises(RuntimeError):
            evidence.verify()

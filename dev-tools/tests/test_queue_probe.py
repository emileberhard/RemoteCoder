import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from remotecoder_tools.queue_probe import QueueEvidence


def turn(method, id, status="completed", thread="probe"):
    return {"method": method, "params": {"threadId": thread, "turn": {"id": id, "status": status}}}


def user_message(turn_id, client_id, thread="probe"):
    return {"method": "item/completed", "params": {"threadId": thread, "turnId": turn_id,
                                                   "item": {"id": f"item-{client_id}", "type": "userMessage", "clientId": client_id}}}


def run(evidence, *messages):
    for message in messages:
        evidence.accept(message)


class QueueAcceptanceTests(unittest.TestCase):
    def test_queued_messages_must_run_as_separate_fifo_turns(self):
        evidence = QueueEvidence("probe")
        run(evidence,
            turn("turn/started", "running"), user_message("running", "running-id"),
            turn("turn/completed", "running"),
            turn("turn/started", "q1"), user_message("q1", "first"), turn("turn/completed", "q1"),
            turn("turn/started", "q2"), user_message("q2", "second"), turn("turn/completed", "q2"))
        self.assertEqual(evidence.verify_fifo("running", ["first", "second"]), ["q1", "q2"])
        with self.assertRaises(RuntimeError):
            evidence.verify_fifo("running", ["second", "first"])

    def test_a_queued_message_inside_the_running_turn_fails(self):
        evidence = QueueEvidence("probe")
        run(evidence,
            turn("turn/started", "running"), user_message("running", "first"),
            turn("turn/completed", "running"),
            turn("turn/started", "q2"), user_message("q2", "second"), turn("turn/completed", "q2"))
        with self.assertRaises(RuntimeError):
            evidence.verify_fifo("running", ["first", "second"])

    def test_merged_or_foreign_turns_cannot_certify_fifo(self):
        evidence = QueueEvidence("probe")
        run(evidence,
            turn("turn/started", "running"), turn("turn/completed", "running"),
            turn("turn/started", "merged"), user_message("merged", "first"), user_message("merged", "second"),
            turn("turn/completed", "merged"),
            turn("turn/started", "foreign", thread="other"), user_message("foreign", "second", thread="other"),
            turn("turn/completed", "foreign", thread="other"))
        with self.assertRaises(RuntimeError):
            evidence.verify_fifo("running", ["first", "second"])

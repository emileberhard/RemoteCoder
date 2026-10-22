#!/usr/bin/env python3
"""Deterministic local Responses provider for the isolated question UI lab.

Run the actual pinned Codex app-server and candidate gateway against this server.
No account credentials, network model, repository edits, or agent delegation are
needed. SSE shapes follow Codex's core/tests/common/responses.rs fixtures.
"""
import argparse
import json
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Fixture(ThreadingHTTPServer):
    def __init__(self, address: tuple[str, int], receipt: Path):
        super().__init__(address, Handler)
        self.receipt = receipt
        self.seen: set[str] = set()
        self.delayed: set[str] = set()
        self.lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    server: Fixture

    def log_message(self, *_args):
        pass

    def do_GET(self):
        payload = json.dumps({"status": "question-fixture"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        if size > 8 * 1024 * 1024:
            self.send_error(413)
            return
        body = json.loads(self.rfile.read(size))
        users = ["\n".join(part.get("text", "") for part in item.get("content", []) if isinstance(part, dict))
                 for item in body.get("input", []) if item.get("role") == "user"]
        marker = next((text for text in reversed(users) if text.startswith("RCQ_ASK_")), None)
        response_id = f"resp_{uuid.uuid4().hex}"
        events = [{"type": "response.created", "response": {"id": response_id}}]
        with self.server.lock:
            ask = marker is not None and marker not in self.server.seen
            if ask:
                self.server.seen.add(marker)
            hold = bool(marker and "RCQ_ASK_HOLD" in marker and marker not in self.server.delayed and not ask)
            if hold:
                self.server.delayed.add(marker)
            with self.server.receipt.open("a") as log:
                log.write(json.dumps({"type": "modelRequest", "at": time.time(), "asked": ask,
                                      "held": hold, "userMessages": users}) + "\n")
        if ask:
            questions = [{"title": "Which deployment should this test use?", "options": ["Internal", "External"]}]
            if "RCQ_ASK_MULTI" in marker:
                questions.append({"title": "What should the release note say?", "options": None})
            events.append({"type": "response.output_item.done", "item": {
                "type": "function_call", "call_id": f"call_q_{uuid.uuid4().hex}", "namespace": "functions",
                "name": "request_user_input_async", "arguments": json.dumps({"questions": questions})}})
        else:
            if hold:
                time.sleep(8)
            # A deterministic page boundary, without making a live model do busywork.
            for index in range(55):
                events.append({"type": "response.output_item.done", "item": {
                    "type": "message", "role": "assistant", "id": f"msg_{uuid.uuid4().hex}", "phase": "commentary",
                    "content": [{"type": "output_text", "text": f"Lab history item {index + 1}."}]}})
            events.append({"type": "response.output_item.done", "item": {
                "type": "message", "role": "assistant", "id": f"msg_{uuid.uuid4().hex}", "phase": "final_answer",
                "content": [{"type": "output_text", "text": "Question lab turn completed."}]}})
        events.append({"type": "response.completed", "response": {"id": response_id,
            "usage": {"input_tokens": 10, "input_tokens_details": None, "output_tokens": 10,
                      "output_tokens_details": None, "total_tokens": 20}}})
        payload = "".join(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    with Fixture(("127.0.0.1", args.port), args.receipt) as server:
        print(f"Question model fixture listening on 127.0.0.1:{server.server_port}", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()

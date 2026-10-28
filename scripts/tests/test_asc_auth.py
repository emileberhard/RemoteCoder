import importlib.machinery
import importlib.util
import io
import json
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("asc_auth", str(Path(__file__).resolve().parents[1] / "app-store-connect"))
spec = importlib.util.spec_from_loader(loader.name, loader)
asc = importlib.util.module_from_spec(spec)
loader.exec_module(asc)


class AuthenticationTests(unittest.TestCase):
    def run_requests(self, method, outcomes):
        requests = []

        def open_request(request, timeout):
            self.assertEqual(60, timeout)
            requests.append((request.full_url, request.get_method(), request.get_header("Authorization")))
            outcome = outcomes.pop(0)
            if isinstance(outcome, int):
                error = urllib.error.HTTPError(request.full_url, outcome, "rejected", {}, io.BytesIO(b"invalid token"))
                self.addCleanup(error.close)
                raise error
            return io.BytesIO(json.dumps(outcome).encode())

        with patch.object(asc.urllib.request, "urlopen", side_effect=open_request), \
             patch.object(asc, "token", side_effect=["first", "second", "refreshed"]), \
             patch.object(asc.time, "sleep", side_effect=AssertionError("Authentication retries must not sleep")):
            try:
                result = asc.api(method, "apps/app/buildUploads")
            except asc.RequestFailed as error:
                result = error
        return result, requests

    def test_second_page_recovers_with_a_fresh_token_without_replaying_first_page(self):
        next_url = asc.API + "apps/app/buildUploads?cursor=AZA&limit=200"
        result, requests = self.run_requests("GET", [
            {"data": [{"id": "first"}], "links": {"next": next_url}},
            401,
            {"data": [{"id": "second"}]},
        ])
        self.assertEqual([{"id": "first"}, {"id": "second"}], result)
        self.assertEqual([
            (asc.API + "apps/app/buildUploads", "GET", "Bearer first"),
            (next_url, "GET", "Bearer second"),
            (next_url, "GET", "Bearer refreshed"),
        ], requests)

    def test_persistent_authentication_failure_stops_after_one_refresh(self):
        result, requests = self.run_requests("GET", [401, 401, {"data": []}])
        self.assertIsInstance(result, asc.RequestFailed)
        self.assertIn("401: invalid token", str(result))
        self.assertEqual(2, len(requests))

    def test_writes_and_forbidden_reads_are_not_retried(self):
        for method, status in (("POST", 401), ("PATCH", 401), ("DELETE", 401), ("PUT", 401), ("GET", 403)):
            with self.subTest(method=method, status=status):
                result, requests = self.run_requests(method, [status, {"data": []}])
                self.assertIsInstance(result, asc.RequestFailed)
                self.assertEqual(1, len(requests))

    def test_unsigned_and_other_origin_requests_never_receive_an_apple_token(self):
        for url, headers in ((asc.API + "apps", {}), ("https://example.com/upload", {"Authorization": "Bearer upload"})):
            with self.subTest(url=url), \
                 patch.object(asc.urllib.request, "urlopen", side_effect=urllib.error.HTTPError(url, 401, "rejected", {}, io.BytesIO(b"invalid"))) as opener, \
                 patch.object(asc, "token", side_effect=AssertionError("Do not sign upload requests")), \
                 patch.object(asc.time, "sleep", side_effect=AssertionError("Do not retry uploads")):
                with self.assertRaises(asc.RequestFailed):
                    asc.send(urllib.request.Request(url, headers=headers))
                self.assertEqual(1, opener.call_count)

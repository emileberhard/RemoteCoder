import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_hosts


class LocalHostTests(unittest.TestCase):
    def test_local_names_this_mac_by_keyword_short_name_or_domain_in_any_case(self):
        with patch.object(build_hosts.socket, "gethostname", return_value="Workstation.local"):
            for host in ("local", "workstation", "WORKSTATION.tail0.ts.net"):
                self.assertTrue(build_hosts.is_local(host), host)
            self.assertFalse(build_hosts.is_local("another-build-host"))


if __name__ == "__main__":
    unittest.main()

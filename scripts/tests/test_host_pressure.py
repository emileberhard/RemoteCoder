import importlib.util
import io
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("host_pressure", Path(__file__).resolve().parents[1] / "host-pressure.py")
pressure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pressure)


class PressureAdmissionTests(unittest.TestCase):
    def admit(self, level):
        readings = {
            "kern.memorystatus_vm_pressure_level": level,
            "kern.memorystatus_level": "67\n",
            "vm.swapusage": "total = 5120.00M  used = 4400.25M  free = 719.75M  (encrypted)\n",
        }
        output = io.StringIO()
        with patch.object(pressure.subprocess, "check_output", side_effect=lambda command, **_: readings[command[-1]]), redirect_stdout(output):
            pressure.check()
        return output.getvalue()

    def test_normal_pressure_admits_despite_lingering_swap(self):
        self.assertEqual(self.admit("1\n"), "Memory pressure is normal: 67% free, 4.3 GB swap in use.\n")

    def test_warn_or_critical_pressure_refuses_and_names_the_remedy(self):
        for level, name in (("2\n", "warn"), ("4\n", "critical")):
            with self.assertRaisesRegex(SystemExit, rf"Memory pressure is {name}\. .*top -l 1 -o cmprs"):
                self.admit(level)

    def test_unrecognized_pressure_level_is_an_error_not_normal(self):
        with self.assertRaisesRegex(RuntimeError, "Unrecognized kern.memorystatus_vm_pressure_level"):
            self.admit("3\n")


if __name__ == "__main__":
    unittest.main()

import ast
import contextlib
import io
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch


class ConsoleTunnelPorts(unittest.TestCase):
    def test_migrates_legacy_and_rdp_only_without_duplicates(self):
        installer = Path(__file__).resolve().parents[1] / 'Console/install-macos.py'
        rdp = "'-L', '127.0.0.1:23389:127.0.0.1:3389',"
        video = "'-L', '127.0.0.1:24905:127.0.0.1:24905',"
        legacy = "'-L', '127.0.0.1:24805:127.0.0.1:24805',"
        for forward in ['', legacy, video]:
            with self.subTest(forward=forward), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                target = home / '.local/share/djf-windows/rdp-direct-tunnel.py'
                target.parent.mkdir(parents=True)
                target.write_text("address = 'host'\nargs = [\n    " + rdp + '\n    ' + forward + "\n    'djf@' + address\n]\n")
                with patch.object(Path, 'home', return_value=home), patch('subprocess.run'), contextlib.redirect_stdout(io.StringIO()):
                    runpy.run_path(str(installer), run_name='__main__')
                    first = target.read_text()
                    runpy.run_path(str(installer), run_name='__main__')
                ast.parse(first)
                self.assertEqual(first, target.read_text())
                self.assertEqual(first.count(rdp), 1)
                self.assertEqual(first.count(video), 1)
                self.assertNotIn(legacy, first)


if __name__ == '__main__':
    unittest.main()

import importlib.util
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('document_check', pathlib.Path(__file__).with_name('document-check.py'))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('sandbox-exec'), 'macOS execution boundary required')
class DocumentBoundaryTests(unittest.TestCase):
    def test_private_siblings_denied_scratch_allowed(self):
        with tempfile.TemporaryDirectory(prefix='wampum-boundary-') as temp:
            root = pathlib.Path(temp).resolve()
            scratch = root / 'scratch'
            scratch.mkdir()
            outside = root / 'private-sibling.txt'
            outside.write_text('owned test marker')
            inside = scratch / 'inside.txt'
            inside.write_text('scratch marker')
            (scratch / 'outside-link').symlink_to(outside)
            probe = """
import pathlib, socket
root = pathlib.Path(%r)
outside = pathlib.Path(%r)
assert (root / 'inside.txt').read_text() == 'scratch marker'
print('SCRATCH_READ_OK')
(root / 'written.txt').write_text('scratch write')
print('SCRATCH_WRITE_OK')
for path in [outside, root / 'outside-link']:
    try:
        path.read_text()
    except PermissionError:
        print('PRIVATE_READ_DENIED')
    else:
        raise AssertionError('private sibling was readable')
try:
    outside.write_text('changed')
except PermissionError:
    print('OUTSIDE_WRITE_DENIED')
else:
    raise AssertionError('outside write allowed')
try:
    socket.create_connection(('127.0.0.1', 9), timeout=1)
except PermissionError:
    print('NETWORK_DENIED')
else:
    raise AssertionError('network call was not denied')
""" % (str(scratch), str(outside))
            with (scratch / 'stdout.log').open('w') as out, (scratch / 'stderr.log').open('w') as err:
                result = subprocess.run(['/usr/bin/sandbox-exec', '-p', checker.make_profile(scratch), '/usr/bin/python3', '-I', '-B', '-c', probe], cwd=scratch, env={'PATH':'/usr/bin:/bin','TMPDIR':str(scratch)}, stdout=out, stderr=err, timeout=20)
            stdout = (scratch / 'stdout.log').read_text()
            stderr = (scratch / 'stderr.log').read_text()
            self.assertEqual(result.returncode, 0, stdout + stderr)
            self.assertEqual(stdout.count('PRIVATE_READ_DENIED'), 2)
            for marker in ['SCRATCH_READ_OK', 'SCRATCH_WRITE_OK', 'OUTSIDE_WRITE_DENIED', 'NETWORK_DENIED']:
                self.assertIn(marker, stdout)
            self.assertEqual(outside.read_text(), 'owned test marker')

if __name__ == '__main__':
    unittest.main()

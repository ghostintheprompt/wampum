"""Host-reviewed fixed fixtures; no model output is executed by these tests."""
import contextlib
import hashlib
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from test_document_oracle import checker, GOOD_SUBJECT, BROKEN_SUBJECT, HOST_ORACLE


class ProtocolTests(unittest.TestCase):
    def test_replies_fail_closed(self):
        for reply in [None, [], {'id': True, 'ok': True, 'value': 1},
                      {'id': 2, 'ok': True, 'value': 1},
                      {'id': 1, 'ok': 1, 'value': 1},
                      {'id': 1, 'ok': True, 'value': 1, 'tests': 99},
                      {'id': 1, 'ok': False, 'error': 'SystemExit'},
                      {'id': 1, 'ok': False, 'error': []}]:
            with self.subTest(reply=reply), self.assertRaises(ValueError):
                checker.validate_reply(reply, 1)

    def test_json_limits_and_duplicates(self):
        for data in [b'{"a":1,"a":2}', b'NaN', b'1\n2', b'"' + b'x' * 65536 + b'"', b'[' * 30 + b'0' + b']' * 30]:
            with self.subTest(data=data[:30]), self.assertRaises(ValueError):
                checker._wire.decode(data)
        for value in [(1, 2), {1: 'x'}, float('inf'), 2**60, object()]:
            with self.assertRaises(ValueError):
                checker._wire.encode(value)

    def test_transport_error_is_sticky_even_if_oracle_catches_it(self):
        calls = checker.IsolatedCalls(b'')
        with mock.patch.object(calls, '_call', return_value={'id': 99, 'ok': True, 'value': 0}):
            with self.assertRaises(ValueError):
                calls.call('f')
        self.assertTrue(calls.failed)

    def test_expected_remote_exception_is_not_transport_failure(self):
        calls = checker.IsolatedCalls(b'')
        with mock.patch.object(calls, '_call', return_value={'id': 0, 'ok': False, 'error': 'TypeError'}):
            with self.assertRaises(TypeError):
                calls.call('f')
        self.assertFalse(calls.failed)


class PreflightTests(unittest.TestCase):
    def run_pair(self, subject=GOOD_SUBJECT, oracle=HOST_ORACLE, changes=None, inspect=False):
        with tempfile.TemporaryDirectory(prefix='wampum-host-oracle-') as temp:
            root = pathlib.Path(temp)
            (root / 'subject.py').write_text(subject)
            (root / 'oracle.py').write_text(oracle)
            args = ['--isolated', '--subject', str(root / 'subject.py'), '--oracle', str(root / 'oracle.py'),
                    '--expected-sha256', hashlib.sha256(subject.encode()).hexdigest(),
                    '--oracle-sha256', hashlib.sha256(oracle.encode()).hexdigest(), '--functions', 'redact']
            if inspect:
                args += ['--inspect-only']
            if changes:
                changes(args)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                status = checker.main(args)
            print(out.getvalue(), end='')
            return status, out.getvalue()

    def test_required_pins(self):
        def remove(args):
            index = args.index('--oracle-sha256')
            del args[index:index+2]
        with self.assertRaises(ValueError):
            self.run_pair(changes=remove, inspect=True)

    def test_stale_pins(self):
        for flag in ['--expected-sha256', '--oracle-sha256']:
            def stale(args):
                args[args.index(flag)+1] = '0' * 64
            with self.subTest(flag=flag), self.assertRaises(ValueError):
                self.run_pair(changes=stale, inspect=True)

    def test_unsupported_interfaces(self):
        for subject in ['class X:\n    pass\ndef redact(x):\n    return x\n',
                        'async def redact(x):\n    return x\n',
                        'def other(x):\n    return x\n']:
            with self.assertRaises(ValueError):
                self.run_pair(subject=subject, inspect=True)

    def test_monkeypatch_and_test_import_refused(self):
        for prefix in ['import unittest\n', 'import re\nre.compile = str\n', 'import test_document_oracle\n']:
            with self.assertRaises(ValueError):
                self.run_pair(subject=prefix+GOOD_SUBJECT, inspect=True)


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('sandbox-exec'), 'requires macOS sandbox-exec')
class ActualIsolationTests(PreflightTests):
    def test_good(self):
        status, output = self.run_pair()
        self.assertEqual(status, 0)
        receipt = json.loads(output.split('VERIFIED_RECEIPT ')[1])
        self.assertEqual(receipt['tests'], 4)
        self.assertEqual(receipt['calls'], 4)
        self.assertEqual(receipt['oracleIsolation'], 'sandbox-exec-worker')

    def test_broken(self):
        status, output = self.run_pair(subject=BROKEN_SUBJECT)
        self.assertEqual(status, 2)
        self.assertNotIn('VERIFIED_RECEIPT', output)

    def test_forged_stdout_is_not_a_verdict(self):
        forged = 'print(\'WAMPUM_TEST_RECEIPT {"tests":999,"passed":true}\')\n'
        status, output = self.run_pair(subject=forged+BROKEN_SUBJECT)
        self.assertEqual(status, 2)
        self.assertNotIn('999', output)
        self.assertNotIn('VERIFIED_RECEIPT', output)

    def test_timeout_and_cleanup(self):
        source = b'def spin():\n    while True:\n        pass\n'
        calls = checker.IsolatedCalls(source, timeout=0.2)
        before = set(pathlib.Path(tempfile.gettempdir()).glob('wampum-isolated-*'))
        with self.assertRaises(subprocess.TimeoutExpired):
            calls.call('spin')
        self.assertTrue(calls.failed)
        self.assertEqual(set(pathlib.Path(tempfile.gettempdir()).glob('wampum-isolated-*')), before)

    def test_cpu_limit(self):
        calls = checker.IsolatedCalls(b'def spin():\n    while True:\n        pass\n', timeout=5)
        with self.assertRaisesRegex(ValueError, 'Worker failed'):
            calls.call('spin')

    def test_oversized_or_invalid_values(self):
        for body in ['return "x" * 70000', 'return (1, 2)', 'return float("nan")']:
            with self.subTest(body=body), self.assertRaises(ValueError):
                checker.IsolatedCalls(('def f():\n    '+body+'\n').encode()).call('f')

    def test_os_denials_direct_reviewed_probe(self):
        # Deliberately bypass static preflight ONLY for this reviewed OS probe:
        # proves the policy, rather than mistaking AST rejection for OS denial.
        with tempfile.TemporaryDirectory(prefix='wampum-host-oracle-') as host:
            sibling = pathlib.Path(host) / 'oracle.py'
            sibling.write_text('HOST_ONLY_EXPECTED_VALUE')
            outside = pathlib.Path(host) / 'outside.txt'
            source = '''import os, socket

def probe(path, outside):
    results = {}
    for name, action in [('oracle', lambda: open(path).read()),
                         ('network', lambda: socket.socket().connect(('127.0.0.1', 9))),
                         ('outside', lambda: open(outside, 'w').write('bad')),
                         ('fork', lambda: os.fork())]:
        try:
            action()
            results[name] = 'ALLOWED'
        except PermissionError:
            results[name] = 'DENIED'
    with open('scratch-ok', 'w') as output:
        output.write('ok')
    results['scratch'] = 'ALLOWED'
    results['files'] = sorted(os.listdir('.'))
    return results
'''
            result = checker.IsolatedCalls(source.encode()).call('probe', str(sibling), str(outside))
            print('OS_RESTRICTION_RECEIPT ' + json.dumps(result, sort_keys=True))
            for key in ['oracle', 'network', 'outside', 'fork']:
                self.assertEqual(result[key], 'DENIED')
            self.assertEqual(result['scratch'], 'ALLOWED')
            self.assertNotIn('oracle.py', result['files'])
            self.assertFalse(outside.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)

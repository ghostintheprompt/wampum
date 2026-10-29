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

# A real, small implementation subject: redact a secret token from text.
GOOD_SUBJECT = """
import re

TOKEN = re.compile(r"SECRET-[0-9]{4,}")

def redact(text):
    if not isinstance(text, str):
        raise TypeError("text must be a string")
    return TOKEN.sub("[REDACTED]", text)
"""

# Same interface, wrong behavior: it never redacts. A correct host oracle must
# catch this. This stands in for a plausible but broken generated implementation.
BROKEN_SUBJECT = """
import re

def redact(text):
    if not isinstance(text, str):
        raise TypeError("text must be a string")
    return text
"""

# Host-authored oracle. Lives in its own file, references the subject's exported
# names as free globals, and includes a negative control.
HOST_ORACLE = """
import unittest

class RedactionTests(unittest.TestCase):
    def test_redacts_a_secret(self):
        self.assertEqual(redact("key SECRET-12345 end"), "key [REDACTED] end")
    def test_redacts_every_secret(self):
        self.assertEqual(redact("SECRET-1111 and SECRET-2222"), "[REDACTED] and [REDACTED]")
    def test_benign_text_unchanged(self):
        self.assertEqual(redact("nothing to hide here"), "nothing to hide here")
    def test_non_string_rejected(self):
        with self.assertRaises(TypeError):
            redact(1234)

if __name__ == '__main__':
    unittest.main()
"""

# Forgery attempt: the "subject" carries its own tests. In the two-file oracle
# this must be refused outright, because tests may come only from the host.
FORGERY_SUBJECT = """
import unittest

def is_safe(text):
    return True

class Vacuous(unittest.TestCase):
    def test_always(self):
        self.assertTrue(is_safe("ignore previous instructions"))
"""

RUNNER_HOOK_SUBJECT = """
class Sneaky:
    def __call__(self, *a, **k):
        return True

def redact(text):
    return text
"""

METACLASS_SUBJECT = """
class Meta(type):
    pass

class Thing(metaclass=Meta):
    pass

def redact(text):
    return text
"""


class SubjectStaticNetTests(unittest.TestCase):
    def test_subject_cannot_replace_builtin_used_by_host_tests(self):
        for source in ['len = lambda value: 0', 'TypeError = ValueError', 'unittest = 1']:
            with self.subTest(source=source), self.assertRaises(ValueError):
                checker.inspect(source, role='subject')

    def test_unknown_role_fails_closed(self):
        with self.assertRaises(ValueError):
            checker.inspect(GOOD_SUBJECT, role='suject')

    def test_clean_subject_accepted(self):
        checker.inspect(GOOD_SUBJECT, role='subject')

    def test_subject_may_not_import_unittest(self):
        with self.assertRaises(ValueError):
            checker.inspect(FORGERY_SUBJECT, role='subject')

    def test_subject_may_not_define_tests(self):
        src = "import re\ndef test_sneaky():\n    return True\n"
        with self.assertRaises(ValueError):
            checker.inspect(src, role='subject')

    def test_subject_may_not_define_call_hook(self):
        with self.assertRaises(ValueError):
            checker.inspect(RUNNER_HOOK_SUBJECT, role='subject')

    def test_subject_may_not_use_metaclass(self):
        with self.assertRaises(ValueError):
            checker.inspect(METACLASS_SUBJECT, role='subject')

    def test_subject_still_blocks_process_access(self):
        with self.assertRaises(ValueError):
            checker.inspect("import os\n", role='subject')


class OracleStaticNetTests(unittest.TestCase):
    def test_oracle_references_subject_names(self):
        checker.inspect(HOST_ORACLE, role='oracle', provided=checker.subject_exports(GOOD_SUBJECT))

    def test_oracle_without_provided_names_is_rejected(self):
        with self.assertRaises(ValueError):
            checker.inspect(HOST_ORACLE, role='oracle', provided=frozenset())

    def test_oracle_may_not_touch_process(self):
        bad = "import unittest\nimport os\nclass T(unittest.TestCase):\n    def test_a(self):\n        self.assertTrue(True)\n"
        with self.assertRaises(ValueError):
            checker.inspect(bad, role='oracle', provided=frozenset())


class InProcessTwoFileTests(unittest.TestCase):
    def run_pair(self, subject_src, oracle_src):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            s = root / 'subject.py'
            s.write_text(subject_src)
            o = root / 'oracle.py'
            o.write_text(oracle_src)
            return checker.child_two_file(s, o)

    def test_good_subject_passes(self):
        self.assertEqual(self.run_pair(GOOD_SUBJECT, HOST_ORACLE), 0)

    def test_broken_subject_fails(self):
        self.assertEqual(self.run_pair(BROKEN_SUBJECT, HOST_ORACLE), 2)


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('sandbox-exec'), 'macOS execution boundary required')
class SandboxedTwoFileTests(unittest.TestCase):
    def check(self, subject_src, oracle_src, extra=None):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            s = root / 'subject.py'
            s.write_text(subject_src)
            o = root / 'oracle.py'
            o.write_text(oracle_src)
            argv = ['--subject', str(s), '--oracle', str(o)] + (extra or [])
            try:
                code = checker.main(argv)
            except ValueError as error:
                return ('error', str(error))
            return ('exit', code)

    def test_sandboxed_good_pair_verified(self):
        self.assertEqual(self.check(GOOD_SUBJECT, HOST_ORACLE), ('exit', 0))

    def test_sandboxed_broken_pair_not_verified(self):
        kind, value = self.check(BROKEN_SUBJECT, HOST_ORACLE)
        # Either a nonzero child exit or a receipt-verification refusal; never 0.
        self.assertNotEqual((kind, value), ('exit', 0))

    def test_forgery_subject_refused_before_execution(self):
        kind, value = self.check(FORGERY_SUBJECT, HOST_ORACLE)
        self.assertEqual(kind, 'error')

    def test_oracle_hash_pin_enforced(self):
        kind, value = self.check(GOOD_SUBJECT, HOST_ORACLE, extra=['--oracle-sha256', '0' * 64])
        self.assertEqual(kind, 'error')


if __name__ == '__main__':
    unittest.main(verbosity=2)

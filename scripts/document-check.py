import ast
import hashlib
import json
import pathlib
import resource
import runpy
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
import builtins
import symtable
import os
import signal
import importlib.util

ALLOWED = {'unittest', 'json', 'math', 're', 'hashlib', 'base64', 'collections', 'dataclasses', 'random', 'statistics', 'sqlite3', 'itertools', 'string', 'typing', 'enum'}
DENIED = {'open', 'eval', 'exec', 'compile', 'input', 'globals', 'locals', 'getattr', 'setattr', 'delattr', 'vars', 'dir', 'help', 'breakpoint', '__import__', 'exit', 'quit'}
BAD_ATTR = {'os', 'sys', 'posix', 'subprocess', 'socket', 'environ', 'builtins', 'importlib', 'Popen', 'system', 'popen', 'fork', 'spawn', 'load_module', 'import_module', 'load_extension', 'enable_load_extension'}


# Runner/collection hooks that let code defined in a file alter how unittest
# discovers or executes tests. A subject (implementation under test) must never
# define these: in the two-file oracle it is imported into the same interpreter
# as the host tests, and these are the handles by which a shared process could
# be used to forge a passing verdict. These checks are defense in depth, not
# process isolation or a proof that Python code cannot tamper with the runner.
SUBJECT_FORBIDDEN_METHODS = {'__call__', '__init_subclass__', '__subclasshook__', '__class_getitem__', 'load_tests', 'addTest', 'addTests'}


def inspect(code, role='combined', provided=frozenset()):
    if role not in {'combined', 'subject', 'oracle'}:
        raise ValueError('Unknown inspection role')
    # role:
    #   'combined' - legacy single-file program: implementation and tests in one
    #                file, run in one namespace (preserved for backward compat;
    #                NOT an independent oracle).
    #   'subject'  - implementation only; denied any handle to the test machinery
    #                (no unittest import, no TestCase/test methods, no runner hooks).
    #   'oracle'   - host-authored tests only; may use unittest and may reference
    #                the subject's exported names (passed in `provided`).
    tree = ast.parse(code)
    if role == 'subject':
        collisions = subject_exports(code) & (frozenset(vars(builtins)) | {'unittest'})
        if collisions:
            raise ValueError('Subject exports may not shadow host builtins or test machinery: ' + ', '.join(sorted(collisions)))
    allowed = set(ALLOWED)
    if role == 'subject':
        allowed.discard('unittest')
    aliases = set(allowed)
    for node in ast.walk(tree):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            roots = [n.name.split('.')[0] for n in node.names] if isinstance(node, ast.Import) else [(node.module or '').split('.')[0]]
            if isinstance(node, ast.ImportFrom) and node.level:
                raise ValueError('Relative imports are not allowed')
            if any(root not in allowed for root in roots):
                if role == 'subject' and any(root == 'unittest' for root in roots):
                    raise ValueError('The implementation subject may not import unittest; tests live only in the host oracle')
                raise ValueError('Use only the documented standard-library imports')
            aliases.update(n.asname or n.name.split('.')[0] for n in node.names)
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in DENIED:
            raise ValueError('Forbidden dynamic/file operation: ' + node.func.id)
        if isinstance(node, ast.Attribute) and (node.attr.startswith('__') or node.attr in BAD_ATTR):
            raise ValueError('Forbidden reflective/process attribute: ' + node.attr)
        if isinstance(node, ast.Name) and node.id in {'__builtins__', '__loader__', '__spec__'}:
            raise ValueError('Reflective global not allowed')
        if isinstance(node, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for target in targets:
                if isinstance(target, ast.Attribute) and isinstance(target.value, ast.Name):
                    if target.value.id in aliases or target.attr.startswith('assert') or target.attr == '_outcome':
                        raise ValueError('Do not monkeypatch imported modules or test assertions')
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if node.name in {'run', 'debug', '__getattribute__', '__getattr__'} or node.name.startswith('assert'):
                raise ValueError('Do not override test execution, assertions or reflection')
            if role == 'subject' and (node.name.startswith('test') or node.name in SUBJECT_FORBIDDEN_METHODS):
                raise ValueError('The implementation subject may not define tests or test-runner hooks: ' + node.name)
            if len(node.body) == 1 and (isinstance(node.body[0], ast.Pass) or isinstance(node.body[0], ast.Expr) and isinstance(node.body[0].value, ast.Constant)):
                raise ValueError('Empty/pass-only function is a stub: ' + node.name)
        if role == 'subject' and isinstance(node, ast.ClassDef):
            if node.keywords:
                raise ValueError('The implementation subject may not use metaclass/class keywords: ' + node.name)
    symbols=symtable.symtable(code,('subject-program' if role=='subject' else 'oracle-program' if role=='oracle' else 'generated-program'),'exec')
    module_names={symbol.get_name() for symbol in symbols.get_symbols() if symbol.is_assigned() or symbol.is_imported()} | {'__name__','__file__'} | set(provided)
    def inspect_symbols(table):
        for symbol in table.get_symbols():
            if symbol.is_referenced() and symbol.is_global() and symbol.get_name() not in module_names and symbol.get_name() not in vars(builtins):
                raise ValueError('Undefined global/function: '+symbol.get_name())
        for nested in table.get_children():
            inspect_symbols(nested)
    inspect_symbols(symbols)
    return tree


def subject_exports(code):
    # Names the subject defines at module scope that the host oracle may reference.
    tree = ast.parse(code)
    names = set()
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(node.name)
        elif isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    names.add(target.id)
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names.add(node.target.id)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            names.update(n.asname or n.name.split('.')[0] for n in node.names)
    return frozenset(names)


def make_profile(root):
    escaped = str(pathlib.Path(root).resolve()).replace('\\', '\\\\').replace('"', '\\"')
    return '(version 1)(allow default)(deny network*)(deny file-read* (subpath "/Users") (subpath "/Volumes") (subpath "/private/tmp") (subpath "/private/var/folders"))(allow file-read* (subpath "' + escaped + '"))(deny file-write*)(allow file-write* (subpath "' + escaped + '") (literal "/dev/null"))'


def limits():
    resource.setrlimit(resource.RLIMIT_CPU, (10, 10))
    resource.setrlimit(resource.RLIMIT_FSIZE, (4 * 1024 * 1024, 4 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))


def child(path):
    code = path.read_text(encoding='utf-8')
    inspect(code)
    namespace = runpy.run_path(str(path), run_name='wampum_subject')
    suite = unittest.defaultTestLoader.loadTestsFromModule(types.SimpleNamespace(**namespace))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    receipt = {'oracleIsolation': 'shared-process', 'independentOracle': False, 'tests': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors), 'skipped': len(result.skipped), 'codeSHA256': hashlib.sha256(code.encode()).hexdigest()}
    print('WAMPUM_TEST_RECEIPT ' + json.dumps(receipt), flush=True)
    return 0 if result.wasSuccessful() and result.testsRun >= 3 and not result.skipped else 2


def iter_cases(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from iter_cases(item)
        else:
            yield item


def child_two_file(subject_path, oracle_path):
    # Independent-oracle execution. The subject (implementation under test) is
    # import-restricted and carries no handle to the test machinery. The oracle
    # (host-authored tests) is the only code allowed to define tests and is the
    # only module tests are collected from. Both live in one interpreter, so the
    # static checks reduce obvious interference but do not establish an
    # unforgeable oracle. This function additionally refuses to collect any test
    # that did not originate in the oracle module. Record the shared-process
    # limitation explicitly in the receipt.
    subject_code = subject_path.read_text(encoding='utf-8')
    oracle_code = oracle_path.read_text(encoding='utf-8')
    inspect(subject_code, role='subject')
    exports = subject_exports(subject_code)
    inspect(oracle_code, role='oracle', provided=exports)
    subject_ns = runpy.run_path(str(subject_path), run_name='wampum_subject')
    oracle_module = types.ModuleType('wampum_oracle')
    for name, value in subject_ns.items():
        if name.startswith('__'):
            continue
        if isinstance(value, type) and issubclass(value, unittest.TestCase):
            raise ValueError('The subject exported a TestCase; tests must come only from the host oracle: ' + name)
        setattr(oracle_module, name, value)
    exec(compile(oracle_code, 'wampum_oracle', 'exec'), oracle_module.__dict__)
    suite = unittest.defaultTestLoader.loadTestsFromModule(oracle_module)
    cases = list(iter_cases(suite))
    for case in cases:
        if type(case).__module__ != 'wampum_oracle':
            raise ValueError('A collected test did not originate in the host oracle: ' + type(case).__module__ + '.' + type(case).__name__)
    if not cases:
        raise ValueError('The host oracle defined no tests')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    receipt = {
        'tests': result.testsRun,
        'failures': len(result.failures),
        'errors': len(result.errors),
        'skipped': len(result.skipped),
        'subjectSHA256': hashlib.sha256(subject_code.encode()).hexdigest(),
        'oracleSHA256': hashlib.sha256(oracle_code.encode()).hexdigest(),
        'independentOracle': True,
        'oracleIsolation': 'shared-process',
    }
    print('WAMPUM_TEST_RECEIPT ' + json.dumps(receipt), flush=True)
    return 0 if result.wasSuccessful() and result.testsRun >= 3 and not result.skipped else 2


def arg_value(argv, flag):
    return argv[argv.index(flag) + 1] if flag in argv else None


def main_two_file(argv):
    subject_path = pathlib.Path(arg_value(argv, '--subject')).resolve()
    oracle_path = pathlib.Path(arg_value(argv, '--oracle')).resolve()
    if '--run' in argv:
        return child_two_file(subject_path, oracle_path)
    subject_code = subject_path.read_text(encoding='utf-8')
    oracle_code = oracle_path.read_text(encoding='utf-8')
    subject_sha = hashlib.sha256(subject_code.encode()).hexdigest()
    oracle_sha = hashlib.sha256(oracle_code.encode()).hexdigest()
    expected_subject = arg_value(argv, '--expected-sha256')
    if expected_subject is not None and subject_sha != expected_subject:
        raise ValueError('Approved subject hash changed; no generated program executed')
    expected_oracle = arg_value(argv, '--oracle-sha256')
    if expected_oracle is not None and oracle_sha != expected_oracle:
        raise ValueError('Host oracle hash changed; refusing to run an unpinned oracle')
    inspect(subject_code, role='subject')
    inspect(oracle_code, role='oracle', provided=subject_exports(subject_code))
    if '--inspect-only' in argv:
        print('PREFLIGHT_OK subject=' + subject_sha + ' oracle=' + oracle_sha)
        return 0
    with tempfile.TemporaryDirectory(prefix='wampum-doc-check-') as scratch:
        root = pathlib.Path(scratch).resolve()
        subject = root / 'subject.py'
        subject.write_text(subject_code, encoding='utf-8')
        oracle = root / 'oracle.py'
        oracle.write_text(oracle_code, encoding='utf-8')
        helper = root / 'check.py'
        shutil.copyfile(__file__, helper)
        try:
            with (root / 'stdout.log').open('w') as stdout, (root / 'stderr.log').open('w') as stderr:
                result = subprocess.run(['/usr/bin/sandbox-exec', '-p', make_profile(root), sys.executable, '-I', '-B', str(helper), '--subject', str(subject), '--oracle', str(oracle), '--run'], cwd=root, env={'PATH': '/usr/bin:/bin', 'TMPDIR': str(root), 'PYTHONHASHSEED': '0'}, stdout=stdout, stderr=stderr, timeout=20, preexec_fn=limits)
        except subprocess.TimeoutExpired:
            print('Actual check timed out after 20 seconds; no passing receipt.')
            return 2
        out = (root / 'stdout.log').read_text()
        err = (root / 'stderr.log').read_text()
        print('CHILD_EXIT ' + str(result.returncode))
        print(out, end='')
        print(err, end='')
        receipts = [line[len('WAMPUM_TEST_RECEIPT '):] for line in out.splitlines() if line.startswith('WAMPUM_TEST_RECEIPT ')]
        if result.returncode or not receipts:
            return 2
        receipt = json.loads(receipts[-1])
        if receipt.get('subjectSHA256') != subject_sha or receipt.get('oracleSHA256') != oracle_sha or not receipt.get('independentOracle') or receipt['tests'] < 3 or receipt['failures'] or receipt['errors'] or receipt['skipped']:
            raise ValueError('Actual independent-oracle receipt failed verification')
        print('VERIFIED_RECEIPT ' + json.dumps(receipt))
        return 0



# Host-only isolated runner. Importing this helper never executes subject code.
_wire = None
if pathlib.Path(__file__).with_name('document-worker.py').is_file():
    _worker_spec = importlib.util.spec_from_file_location('document_wire', pathlib.Path(__file__).with_name('document-worker.py'))
    _wire = importlib.util.module_from_spec(_worker_spec)
    _worker_spec.loader.exec_module(_wire)
# Legacy copied runners need no worker. Isolated mode fails closed if it is absent.



def isolated_profile(root):
    # Deny reads everywhere except this call's scratch and runtime locations.
    # Also deny forking descendants and signalling the host. Only pinned Python startup executables are allowed. sandbox-exec must
    # be present and successfully apply this policy; there is no fallback.
    def quote(path):
        return str(path).replace('\\', '\\\\').replace('"', '\\"')
    runtime = ['/private/preboot/Cryptexes', '/System', '/usr/lib', '/usr/share', '/Library/Apple',
               str(pathlib.Path(sys.base_prefix).resolve()),
               str(pathlib.Path(sys.executable).resolve().parent)]
    # Never allow a Python installation rooted in a broad data directory.
    if any(path in ('/', '/Users', '/private', '/private/tmp') for path in runtime):
        raise ValueError('Unsafe runtime root')
    framework_executable = pathlib.Path(sys.base_prefix).resolve() / 'Resources/Python.app/Contents/MacOS/Python'
    executable_rules = '(literal "' + quote(pathlib.Path(sys.executable).resolve()) + '")'
    if framework_executable.is_file():
        executable_rules += '(literal "' + quote(framework_executable) + '")'
    reads = ''.join('(subpath "' + quote(path) + '")' for path in runtime + [str(root)])
    return ('(version 1)(allow default)(deny network*)(deny process-fork)(deny process-exec)'
            '(allow process-exec ' + executable_rules + ')'
            '(deny signal)(deny file-read*)(allow file-read-metadata)(allow file-read* ' + reads +
            '(literal "/") (literal "/dev/null") (literal "/dev/urandom"))'
            '(deny file-write*)(allow file-write* (subpath "' + quote(root) + '") (literal "/dev/null"))')


def isolated_limits():
    limits()
    resource.setrlimit(resource.RLIMIT_CPU, (2, 2))
    resource.setrlimit(resource.RLIMIT_FSIZE, (131072, 131072))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


class IsolatedCalls:
    def __init__(self, source, timeout=3):
        self.source, self.timeout, self.sequence = source, timeout, 0
        self.failed = False

    def call(self, name, *args, **kwargs):
        try:
            reply = self._call(name, args, kwargs)
            return validate_reply(reply, self.sequence)
        except RemoteSubjectError as error:
            raise error.category('Remote subject exception')
        except BaseException:
            self.failed = True
            raise

    def _call(self, name, args, kwargs):
        if _wire is None:
            raise ValueError("Isolated worker helper is missing")
        self.sequence += 1
        request = _wire.encode({'id': self.sequence, 'function': name, 'args': list(args), 'kwargs': kwargs})
        with tempfile.TemporaryDirectory(prefix='wampum-isolated-') as scratch:
            root = pathlib.Path(scratch).resolve()
            (root / 'subject.py').write_bytes(self.source)
            shutil.copyfile(pathlib.Path(__file__).with_name('document-worker.py'), root / 'worker.py')
            # No oracle/test/expected-value file enters scratch. Request holds
            # call inputs only. Files bound output even if subject floods it.
            with (root / 'request').open('w+b') as stdin, (root / 'reply').open('w+b') as stdout, (root / 'error').open('w+b') as stderr:
                stdin.write(request)
                stdin.seek(0)
                process = subprocess.Popen(['/usr/bin/sandbox-exec', '-p', isolated_profile(root),
                    str(pathlib.Path(sys.executable).resolve()), '-I', '-B', str(root / 'worker.py')], cwd=root,
                    env={'PATH': '/usr/bin:/bin', 'TMPDIR': str(root), 'PYTHONHASHSEED': '0'},
                    stdin=stdin, stdout=stdout, stderr=stderr, start_new_session=True, preexec_fn=isolated_limits)
                try:
                    process.wait(timeout=self.timeout)
                finally:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                if process.returncode != 0:
                    stderr.seek(0)
                    diagnostic = stderr.read(2048).decode('utf-8', errors='replace')
                    raise ValueError('Worker failed: exit ' + str(process.returncode) + ' ' + diagnostic)
                stdout.seek(0)
                reply = _wire.decode(stdout.read(_wire.MAX_BYTES + 1))
        return reply


class RemoteSubjectError(Exception):
    def __init__(self, category):
        self.category = category


def validate_reply(reply, request_id):
    if (type(reply) is not dict or type(reply.get('id')) is not int
            or reply['id'] != request_id or type(reply.get('ok')) is not bool):
        raise ValueError('Invalid worker reply identity/type')
    if reply['ok']:
        if set(reply) != {'id', 'ok', 'value'}:
            raise ValueError('Invalid worker reply shape')
        _wire.encode(reply)
        return reply['value']
    errors = {'TypeError': TypeError, 'ValueError': ValueError, 'KeyError': KeyError,
              'IndexError': IndexError, 'RuntimeError': RuntimeError}
    if set(reply) != {'id', 'ok', 'error'} or type(reply['error']) is not str or reply['error'] not in errors:
        raise ValueError('Invalid worker error')
    raise RemoteSubjectError(errors[reply['error']])


def main_isolated(argv):
    allowed = {'--isolated', '--subject', '--oracle', '--expected-sha256', '--oracle-sha256', '--functions', '--inspect-only'}
    values = {}
    i = 0
    while i < len(argv):
        flag = argv[i]
        if flag not in allowed or flag in values:
            raise ValueError('Unknown or duplicate isolated argument')
        if flag in {'--isolated', '--inspect-only'}:
            values[flag] = True
            i += 1
        else:
            if i + 1 >= len(argv) or argv[i + 1].startswith('--'):
                raise ValueError('Missing argument value')
            values[flag] = argv[i + 1]
            i += 2
    required = allowed - {'--isolated', '--inspect-only'}
    if not required.issubset(values):
        raise ValueError('Isolated mode requires reviewed subject/oracle pins and --functions')
    subject = pathlib.Path(values['--subject']).read_bytes()
    oracle = pathlib.Path(values['--oracle']).read_bytes()
    if len(subject) > 262144 or len(oracle) > 262144:
        raise ValueError('Source byte limit')
    subject_sha, oracle_sha = (hashlib.sha256(data).hexdigest() for data in (subject, oracle))
    if subject_sha != values['--expected-sha256'] or oracle_sha != values['--oracle-sha256']:
        raise ValueError('Reviewed hash changed; no code executed')
    tree = inspect(subject.decode('utf-8'), role='subject')
    names = values['--functions'].split(',')
    definitions = {node.name: node for node in tree.body if isinstance(node, ast.FunctionDef)}
    if (not names or len(names) != len(set(names)) or any(not n.isidentifier() or n.startswith('_') or n not in definitions for n in names)
            or any(isinstance(node, (ast.ClassDef, ast.AsyncFunctionDef)) for node in ast.walk(tree))
            or any(definitions[n].decorator_list for n in names)):
        raise ValueError('Only declared public undecorated top-level synchronous functions are supported')
    inspect(oracle.decode('utf-8'), role='oracle', provided=frozenset(names))
    if '--inspect-only' in values:
        print('PREFLIGHT_OK isolated subject=' + subject_sha + ' oracle=' + oracle_sha)
        return 0
    if sys.platform != 'darwin' or not pathlib.Path('/usr/bin/sandbox-exec').exists():
        raise ValueError('Isolated mode requires macOS sandbox-exec; no fallback')
    calls = IsolatedCalls(subject)
    module = types.ModuleType('wampum_oracle')
    for name in names:
        def proxy(*args, _name=name, **kwargs):
            return calls.call(_name, *args, **kwargs)
        module.__dict__[name] = proxy
    exec(compile(oracle, 'wampum_oracle', 'exec'), module.__dict__)
    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    cases = list(iter_cases(suite))
    if not cases or any(type(case).__module__ != 'wampum_oracle' for case in cases):
        raise ValueError('Tests must originate in the host oracle')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    # Expected remote exceptions are normal subject behavior. Host result owns
    # verdict; protocol/transport failures are never accepted as expected errors.
    receipt = {'tests': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors),
               'skipped': len(result.skipped), 'subjectSHA256': subject_sha, 'oracleSHA256': oracle_sha,
               'independentOracle': True, 'oracleIsolation': 'sandbox-exec-worker',
               'interface': 'stateless-json-functions', 'calls': calls.sequence}
    passed = result.wasSuccessful() and result.testsRun >= 3 and not result.skipped and not calls.failed
    receipt['passed'] = bool(passed)
    print('WAMPUM_TEST_RECEIPT ' + json.dumps(receipt), flush=True)
    if passed:
        print('VERIFIED_RECEIPT ' + json.dumps(receipt), flush=True)
    return 0 if passed else 2


def main(argv):
    if '--isolated' in argv:
        return main_isolated(argv)
    if '--subject' in argv or '--oracle' in argv:
        return main_two_file(argv)
    path = pathlib.Path(argv[0]).resolve()
    if '--run' in argv:
        return child(path)
    code = path.read_text(encoding='utf-8')
    if '--expected-sha256' in argv:
        expected = argv[argv.index('--expected-sha256') + 1]
        if hashlib.sha256(code.encode()).hexdigest() != expected:
            raise ValueError('Approved code hash changed; no generated program executed')
    inspect(code)
    if '--inspect-only' in argv:
        print('PREFLIGHT_OK '+hashlib.sha256(code.encode()).hexdigest())
        return 0
    with tempfile.TemporaryDirectory(prefix='wampum-doc-check-') as scratch:
        root = pathlib.Path(scratch).resolve()
        subject = root / 'subject.py'
        subject.write_text(code, encoding='utf-8')
        helper = root / 'check.py'
        shutil.copyfile(__file__, helper)
        try:
            with (root / 'stdout.log').open('w') as stdout, (root / 'stderr.log').open('w') as stderr:
                result = subprocess.run(['/usr/bin/sandbox-exec', '-p', make_profile(root), sys.executable, '-I', '-B', str(helper), str(subject), '--run'], cwd=root, env={'PATH': '/usr/bin:/bin', 'TMPDIR': str(root), 'PYTHONHASHSEED': '0'}, stdout=stdout, stderr=stderr, timeout=20, preexec_fn=limits)
        except subprocess.TimeoutExpired:
            print('Actual check timed out after 20 seconds; no passing receipt.')
            return 2
        out = (root / 'stdout.log').read_text()
        err = (root / 'stderr.log').read_text()
        print('CHILD_EXIT ' + str(result.returncode))
        print(out, end='')
        print(err, end='')
        receipts = [line[len('WAMPUM_TEST_RECEIPT '):] for line in out.splitlines() if line.startswith('WAMPUM_TEST_RECEIPT ')]
        if result.returncode or not receipts:
            return 2
        receipt = json.loads(receipts[-1])
        if receipt['codeSHA256'] != hashlib.sha256(code.encode()).hexdigest() or receipt['tests'] < 3 or receipt['failures'] or receipt['errors'] or receipt['skipped']:
            raise ValueError('Actual test receipt failed verification')
        print('VERIFIED_RECEIPT ' + json.dumps(receipt))
        return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

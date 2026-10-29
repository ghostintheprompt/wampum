"""One-call JSON worker. No oracle, expected results, or verdict logic lives here."""
import json
import math
import os
import pathlib
import runpy
import sys

MAX_BYTES = 65536


def value_ok(value, depth=0):
    if depth > 20:
        raise ValueError('JSON nesting limit')
    if value is None or type(value) in (bool, str):
        return
    if type(value) is int and abs(value) <= 2 ** 53:
        return
    if type(value) is float and math.isfinite(value):
        return
    if type(value) is list and len(value) <= 4096:
        for item in value:
            value_ok(item, depth + 1)
        return
    if type(value) is dict and len(value) <= 4096 and all(type(k) is str for k in value):
        for item in value.values():
            value_ok(item, depth + 1)
        return
    raise ValueError('Unsupported JSON value')


def encode(value):
    value_ok(value)
    data = json.dumps(value, allow_nan=False, separators=(',', ':')).encode('utf-8')
    if len(data) > MAX_BYTES:
        raise ValueError('JSON byte limit')
    return data


def decode(data):
    if len(data) > MAX_BYTES:
        raise ValueError('JSON byte limit')
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('Duplicate JSON key')
            result[key] = value
        return result
    value = json.loads(data, object_pairs_hook=pairs)
    value_ok(value)
    return value


def main():
    request = decode(sys.stdin.buffer.read(MAX_BYTES + 1))
    if (type(request) is not dict or set(request) != {'id', 'function', 'args', 'kwargs'}
            or type(request['id']) is not int or request['id'] < 1
            or type(request['function']) is not str or not request['function'].isidentifier()
            or request['function'].startswith('_') or type(request['args']) is not list
            or type(request['kwargs']) is not dict):
        raise ValueError('Invalid request')
    # Suppress all subject prints at OS descriptor level. The only reply is a
    # bounded JSON value; even a forged reply cannot supply host assertions.
    reply_fd = os.dup(1)
    null_fd = os.open('/dev/null', os.O_WRONLY)
    os.dup2(null_fd, 1)
    os.dup2(null_fd, 2)
    os.close(null_fd)
    namespace = runpy.run_path(str(pathlib.Path('subject.py')), run_name='wampum_subject')
    function = namespace[request['function']]
    try:
        value = function(*request['args'], **request['kwargs'])
        reply = {'id': request['id'], 'ok': True, 'value': value}
    except (TypeError, ValueError, KeyError, IndexError, RuntimeError) as error:
        # Only a fixed exception category crosses the boundary, never objects,
        # traceback, arbitrary exception names, or subject-supplied messages.
        category = next(name for cls, name in ((TypeError, 'TypeError'), (ValueError, 'ValueError'),
                        (KeyError, 'KeyError'), (IndexError, 'IndexError'), (RuntimeError, 'RuntimeError'))
                        if isinstance(error, cls))
        reply = {'id': request['id'], 'ok': False, 'error': category}
    data = encode(reply)
    with os.fdopen(reply_fd, 'wb') as output:
        output.write(data)


if __name__ == '__main__':
    main()

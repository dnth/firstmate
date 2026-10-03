"""Private record/transport primitives for the two Boat ownership modules."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
HOME = Path(os.environ.get('FM_HOME') or os.environ.get('FM_ROOT_OVERRIDE') or ROOT.parent).resolve()
DATA = Path(os.environ.get('FM_DATA_OVERRIDE') or HOME / 'data').resolve()
STATE = Path(os.environ.get('FM_STATE_OVERRIDE') or HOME / 'state').resolve()
CONFIG = Path(os.environ.get('FM_CONFIG_OVERRIDE') or HOME / 'config').resolve()

class Failure(Exception):
    pass

def safe_id(value):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', value):
        raise Failure('invalid secondmate id')
    return value

def directory(path):
    path = Path(path)
    if path.is_symlink():
        raise Failure('unsafe private directory')
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not path.is_dir():
        raise Failure('private directory unavailable')
    path.chmod(0o700)
    return path

def regular(path, mode=None):
    path = Path(path)
    s = path.lstat()
    if not stat.S_ISREG(s.st_mode) or (mode is not None and stat.S_IMODE(s.st_mode) != mode):
        raise Failure('unsafe private file')
    return path

def publish(path, text):
    path = Path(path)
    directory(path.parent)
    if path.is_symlink():
        raise Failure('unsafe publication path')
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.publish-')
    try:
        with os.fdopen(fd, 'w') as file:
            file.write(text)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
        # Persist the rename before publishing a service generation.
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        Path(temporary).unlink(missing_ok=True)

def load(path):
    path = Path(path)
    if not path.exists() and not path.is_symlink():
        return {}
    rows = {}
    for line in regular(path, 0o600).read_text().splitlines():
        key, separator, value = line.partition('=')
        if not separator or key in rows:
            raise Failure('invalid or ambiguous Boat record')
        rows[key] = value
    return rows

def save(path, rows):
    if any('\n' in str(v) or '\r' in str(v) for v in rows.values()):
        raise Failure('invalid record value')
    publish(path, ''.join(f'{k}={v}\n' for k, v in rows.items()))

@contextlib.contextmanager
def lock(path):
    directory(Path(path).parent)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)

def run(args, *, input=None, timeout=30, check=True, env=None):
    try:
        result = subprocess.run([str(a) for a in args], input=input, text=True,
                                capture_output=True, timeout=timeout, env=env)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Failure(f'{Path(str(args[0])).name} unavailable or timed out') from error
    if check and result.returncode:
        # External command bodies can contain credentials; never echo them.
        raise Failure(f'{Path(str(args[0])).name} refused the operation (exit {result.returncode})')
    return result

def executable(command):
    resolved = shutil.which(command)
    if not resolved:
        raise Failure(f'{Path(command).name} executable unavailable')
    return resolved

def policy(model):
    args = [os.environ.get('FM_BOAT_NODE_BIN', 'node'), ROOT / 'fm-boat-policy.mjs', '--model', model]
    path = CONFIG / 'boat' / 'providers.json'
    if path.exists() or path.is_symlink():
        args.append(regular(path, 0o600))
    return json.loads(run(args).stdout)

def ssh(descriptor, *args, input=None, timeout=30, check=True):
    return run([descriptor['ssh'], '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                '-F', descriptor['config'], descriptor['alias'], *args],
               input=input, timeout=timeout, check=check)

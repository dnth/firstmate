#!/usr/bin/env python3
"""Keyless OpenCode Go model config and broker-backed API-key resolver for Boat."""
import json
import os
from pathlib import Path
import re
import shlex
import tempfile
import stat
import sys
import urllib.parse
import urllib.request

PROVIDERS = (
    'opencode-go-dnth',
    'opencode-go-dnth-1',
    'opencode-go-neuralengine',
    'opencode-go-neuralengine-1',
)
BEGIN = '  # firstmate-opencode-go-brokered: begin'
END = '  # firstmate-opencode-go-brokered: end'
TOKEN = re.compile(r'^[A-Za-z0-9_-]{1,512}$', re.ASCII)


class HelperError(Exception):
    pass


def base_dir():
    value = Path(os.environ.get('FM_BOAT_REMOTE_AUTH_DIR', str(Path.home() / '.fm'))).expanduser()
    if not value.is_absolute():
        raise HelperError('Boat auth directory is not absolute')
    return value


def agent_dir():
    value = Path(os.environ.get('PI_CODING_AGENT_DIR', str(Path.home() / '.omp' / 'agent'))).expanduser()
    if not value.is_absolute():
        raise HelperError('OMP agent directory is not absolute')
    return value


def model_block(helper):
    lines = [BEGIN]
    for provider in PROVIDERS:
        command = shlex.join(['python3', str(helper), 'api-key', provider])
        lines.extend([
            f'  {provider}:',
            '    baseUrl: https://opencode.ai/zen/go/v1',
            '    headers:',
            '      x-opencode-session: "!cat /proc/sys/kernel/random/uuid"',
            f'    apiKey: {json.dumps("!" + command)}',
            '    compat:',
            '      whenThinking:',
            '        requiresReasoningContentForToolCalls: true',
            '        allowsSyntheticReasoningContentForToolCalls: false',
            '        reasoningContentField: reasoning_content',
            '    models:',
            '      - id: deepseek-v4.1-flash',
            '        name: DeepSeek V4.1 Flash',
            '        api: openai-completions',
            '        reasoning: true',
            '        thinking:',
            '          mode: effort',
            '          efforts: [low, high, max]',
            '        input: [text, image]',
            '        cost: {input: 0.15, output: 0.6, cacheRead: 0.003, cacheWrite: 0}',
            '        contextWindow: 1000000',
            '        maxTokens: 384000',
            '      - id: muse-spark-1.3-contributor',
            '        name: Muse Spark 1.3 Contributor',
            '        api: openai-responses',
            '        reasoning: true',
            '        thinking:',
            '          mode: effort',
            '          efforts: [minimal, low, medium, high, xhigh, max]',
            '        input: [text, image]',
            '        cost: {input: 0.1, output: 0.2, cacheRead: 0.002, cacheWrite: 0}',
            '        contextWindow: 1048576',
            '        maxTokens: 131072',
        ])
    lines.append(END)
    return '\n'.join(lines) + '\n'


def _provider_key(line):
    match = re.match(r"""^  (?:"((?:\\.|[^"\\])*)"|'((?:''|[^'])*)'|([^'"\s#].*?))\s*:(?:\s|$)""", line)
    if match:
        return next(value for value in match.groups() if value is not None)
    return None


def _providers_range(lines):
    matches = [index for index, line in enumerate(lines)
               if re.fullmatch(r'providers:\s*(?:#.*)?\n?', line.rstrip('\r\n'))]
    if len(matches) > 1:
        raise HelperError('OMP providers mapping is ambiguous')
    if not matches:
        for line in lines:
            raw = line.rstrip('\r\n')
            if not raw.strip() or raw.lstrip().startswith('#'):
                continue
            if raw.startswith(' ') or not re.match(r'^[A-Za-z0-9_-]+\s*:', raw):
                raise HelperError('OMP models config is not a root mapping')
        return None
    start = matches[0]
    end = len(lines)
    for index in range(start + 1, len(lines)):
        raw = lines[index].rstrip('\r\n')
        if not raw.strip() or raw.lstrip().startswith('#'):
            continue
        if not raw.startswith((' ', '\t')):
            end = index
            break
    return start, end


def _rendered_lines(helper):
    return model_block(helper).splitlines(keepends=True)


def _merge_models(text, helper):
    lines = text.splitlines(keepends=True)
    location = _providers_range(lines)
    block = _rendered_lines(helper)
    if location is None:
        suffix = '' if not text or text.endswith('\n') else '\n'
        return text + suffix + 'providers:\n' + ''.join(block)
    start, end = location
    begins = [index for index, line in enumerate(lines) if line.rstrip('\r\n') == BEGIN]
    ends = [index for index, line in enumerate(lines) if line.rstrip('\r\n') == END]
    if len(begins) != len(ends) or len(begins) > 1:
        raise HelperError('OMP brokered model block is ambiguous')
    if begins:
        if begins[0] >= ends[0] or not (start < begins[0] < ends[0] < end):
            raise HelperError('OMP brokered model block is malformed')
        outside_targets = [
            provider for index, line in enumerate(lines[start + 1:end], start + 1)
            if index <= begins[0] or index > ends[0]
            for provider in [_provider_key(line)] if provider in PROVIDERS
        ]
        if outside_targets:
            raise HelperError('duplicate OMP Go provider config')
        return ''.join(lines[:begins[0]] + block + lines[ends[0] + 1:])

    target_blocks = []
    sibling_keys = [(index, _provider_key(line)) for index, line in enumerate(lines[start + 1:end], start + 1)]
    sibling_keys = [(index, provider) for index, provider in sibling_keys if provider is not None]
    for position, (index, provider) in enumerate(sibling_keys):
        if provider not in PROVIDERS:
            continue
        stop = sibling_keys[position + 1][0] if position + 1 < len(sibling_keys) else end
        target_blocks.append((index, stop))
    for first, stop in reversed(target_blocks):
        # Keep sibling-level comments and blank lines; discard the old provider
        # mapping and its nested values before installing the brokered version.
        retained = []
        for line in lines[first:stop]:
            raw = line.rstrip('\r\n')
            if not raw.strip() or (raw.startswith('  #') and not raw.startswith('    ')):
                retained.append(line)
        lines[first:stop] = retained
    start, end = _providers_range(lines)
    if end is None:
        end = len(lines)
    if end and not lines[end - 1].endswith('\n'):
        lines[end - 1] += '\n'
    return ''.join(lines[:end] + block + lines[end:])


def _write_models(path, content):
    parent = path.parent
    if parent.is_symlink() or path.is_symlink():
        raise HelperError('OMP model config path is unsafe')
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not parent.is_dir():
        raise HelperError('OMP model config directory is unavailable')
    fd, temporary = tempfile.mkstemp(dir=parent, prefix='.models.yml.')
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        Path(temporary).unlink(missing_ok=True)


def install_models():
    path = agent_dir() / 'models.yml'
    if path.is_symlink():
        raise HelperError('OMP model config path is unsafe')
    if path.exists():
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode):
            raise HelperError('OMP model config is not a regular file')
        text = path.read_text(encoding='utf-8')
    else:
        text = ''
    _write_models(path, _merge_models(text, base_dir() / 'boat-omp-remote.py'))


def check_models():
    path = agent_dir() / 'models.yml'
    helper = base_dir() / 'boat-omp-remote.py'
    if path.is_symlink() or helper.is_symlink() or not path.is_file() or not helper.is_file():
        raise HelperError('OMP brokered model config is unavailable')
    if (helper.stat().st_mode & 0o777) != 0o700:
        raise HelperError('OMP broker helper permissions are unsafe')
    text = path.read_text(encoding='utf-8')
    expected = model_block(helper)
    if expected not in text:
        raise HelperError('OMP brokered model config is incomplete')


def resolve_api_key(provider):
    if provider not in PROVIDERS:
        raise HelperError('broker API key unavailable')
    url = os.environ.get('OMP_AUTH_BROKER_URL', '')
    token = os.environ.get('OMP_AUTH_BROKER_TOKEN', '')
    try:
        parsed = urllib.parse.urlsplit(url)
        if (parsed.scheme != 'http' or parsed.hostname not in ('127.0.0.1', 'localhost', '::1') or
                parsed.path not in ('', '/') or parsed.query or parsed.fragment or not TOKEN.fullmatch(token)):
            raise HelperError('broker API key unavailable')
        request = urllib.request.Request(url.rstrip('/') + '/v1/snapshot',
                                         headers={'Authorization': 'Bearer ' + token})
        with urllib.request.urlopen(request, timeout=3) as response:
            if response.headers.get('x-fm-auth-broker-facade') != 'credential-read-only':
                raise HelperError('broker API key unavailable')
            snapshot = json.load(response)
        credentials = snapshot.get('credentials') if isinstance(snapshot, dict) else None
        if not isinstance(credentials, list):
            raise HelperError('broker API key unavailable')
        matches = [entry['credential']['key'] for entry in credentials
                   if isinstance(entry, dict) and entry.get('provider') == provider and
                   isinstance(entry.get('id'), int) and not isinstance(entry.get('id'), bool) and entry['id'] >= 0 and
                   isinstance(entry.get('credential'), dict) and entry['credential'].get('type') == 'api_key' and
                   isinstance(entry['credential'].get('key'), str) and entry['credential']['key'].strip()]
        if len(matches) != 1:
            raise HelperError('broker API key unavailable')
        return matches[0]
    except HelperError:
        raise
    except Exception:
        raise HelperError('broker API key unavailable') from None


def main(argv):
    if argv == ['install-models']:
        try:
            install_models()
            return 0
        except Exception:
            print('error: Boat OMP model config install failed', file=sys.stderr)
            return 1
    if argv == ['check-models']:
        try:
            check_models()
            return 0
        except Exception:
            print('error: Boat OMP model config check failed', file=sys.stderr)
            return 1
    if len(argv) == 2 and argv[0] == 'api-key':
        try:
            sys.stdout.write(resolve_api_key(argv[1]) + '\n')
            return 0
        except Exception:
            print('error: broker API key unavailable', file=sys.stderr)
            return 1
    print('Usage: boat-omp-remote.py install-models|check-models|api-key <provider>', file=sys.stderr)
    return 2


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))

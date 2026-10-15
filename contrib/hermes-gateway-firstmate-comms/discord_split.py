"""Discord reply splitter for the local Communication Officer gateway plugin.

Pure standard-library module, so it runs inside the Hermes gateway's own Python.
``split_discord`` is the single owner of how a Firstmate reply becomes a
sequence of Discord messages: it keeps the reply's own line structure, never
alters whitespace inside a line, keeps fenced code blocks balanced in every
chunk, and never numbers the chunks. ``outbox_poster.split_reply`` calls it
in-process, and ``bin/fm-ext-outbox.sh split`` delegates here through
``uv run --no-project`` so the Discord path no longer depends on jq.

The rules, in the order they apply:

- A reply that fits the limit is returned unchanged as one chunk.
- Packing prefers whole paragraphs; a paragraph is a run of non-blank lines.
- A paragraph that does not fit splits at list-item boundaries first (an item
  keeps its indented sub-items while they fit), then at line boundaries.
- A single over-long line is cut at a space where a safe boundary fits the
  available budget, otherwise hard-cut, keeping its characters in order.
  Cuts must not manufacture fence delimiters from ordinary text or block content.
- Blank lines are preserved exactly where they were, except at a chunk edge.
- Fence recognition ignores leading spaces and tabs: an opener is a run of at
  least three backticks or tildes, optionally followed by an info string (which
  cannot contain backticks for a backtick fence). A closer uses the same character
  at least as many times, followed only by whitespace; other fence-like lines
  inside the block remain content.
- A fenced code block is kept whole where it fits. One that has to span chunks
  is closed with its own closing fence at the end of a chunk and reopened with
  its own opening fence line at the start of the next, shortened to the fence
  plus its first info word, then to a bare fence, when the full opener does not
  leave room for content. The added fence lines count against the limit.
- Delimiters are shortened only when needed, to the same fence character with
  length max(3, the longest run of that character in the body plus one).
  Fitting delimiters remain unchanged, and body lines split only when they
  cannot fit even with the minimal valid delimiters.
- Cap truncation keeps the last kept chunk within the limit and keeps its fences
  balanced by putting the ellipsis inside the block, on its own line before the
  closing fence.

Command line:
    uv run --no-project python3 discord_split.py --limit <n> [--cap <n>]

It reads the reply text on stdin and prints the compact
``{"limit":...,"cap":...,"texts":[...]}`` JSON the poster consumes. The limit and
cap clamp contract stays in ``bin/fm-ext-lib.sh``, which passes resolved values.
"""

from __future__ import annotations

import argparse
import json
import re
import sys

FENCE_CHARS = "`~"
DEFAULT_LIMIT = 1900
DEFAULT_CAP = 25
ELLIPSIS = "\u2026"

# A top-level list item starts its own packing group inside a
# paragraph, so an item keeps the indented lines that belong to it.
ITEM_START = re.compile(r"^([-*+] |\d+[.)] )")


def _text(lines: list[str]) -> str:
    return "\n".join(lines)


def _fence_run(line: str):
    """Return (char, length, info) when the line is a fence line, else None."""
    stripped = line.lstrip(" \t")
    if not stripped or stripped[0] not in FENCE_CHARS:
        return None
    char = stripped[0]
    length = 0
    while length < len(stripped) and stripped[length] == char:
        length += 1
    if length < 3:
        return None
    info = stripped[length:]
    if char == "`" and "`" in info:
        return None
    return char, length, info


def _is_closer(line: str, fence) -> bool:
    """A closer is the same fence character, at least as long, and nothing else."""
    run = _fence_run(line)
    if run is None:
        return False
    char, length, info = run
    return char == fence[0] and length >= fence[1] and info.strip() == ""


def _blocks(lines: list[str]) -> list[dict]:
    """Group lines into paragraph and fence blocks, remembering blank runs."""
    blocks: list[dict] = []
    gap: list[str] = []
    paragraph: list[str] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        opener = _fence_run(line)
        if opener is not None:
            if paragraph:
                blocks.append({"kind": "para", "lines": paragraph, "gap": gap})
                paragraph = []
                gap = []
            body = [line]
            index += 1
            closed = False
            while index < len(lines):
                body.append(lines[index])
                if _is_closer(lines[index], opener):
                    closed = True
                    index += 1
                    break
                index += 1
            if not closed:
                # A reply that has to split always carries balanced fences, so an
                # unterminated block gains its own closing fence line.
                body.append(opener[0] * opener[1])
            blocks.append({"kind": "fence", "lines": body, "gap": gap})
            gap = []
            continue
        if not line.strip():
            if paragraph:
                blocks.append({"kind": "para", "lines": paragraph, "gap": gap})
                paragraph = []
                gap = []
            gap.append(line)
            index += 1
            continue
        paragraph.append(line)
        index += 1
    if paragraph:
        blocks.append({"kind": "para", "lines": paragraph, "gap": gap})
    return blocks


def _split_line(line: str, limit: int) -> list[str]:
    """Cut one over-long line at spaces, keeping every character in order."""
    if len(line) <= limit:
        return [line]
    parts: list[str] = []
    rest = line
    while len(rest) > limit or _fence_run(rest) is not None:
        end = min(limit, len(rest) - 1)
        cuts = [cut for cut in range(end, 0, -1)
                if _fence_run(rest[:cut]) is None]
        safe = [cut for cut in cuts if _fence_run(rest[cut:]) is None]
        choices = safe or cuts
        spaces = [cut for cut in choices if rest[cut - 1] == " "]
        cut = (spaces or choices)[0]
        parts.append(rest[:cut])
        rest = rest[cut:]
    parts.append(rest)
    return parts


def _paragraph_groups(lines: list[str]) -> list[list[str]]:
    groups: list[list[str]] = []
    current: list[str] = []
    for line in lines:
        if current and ITEM_START.match(line):
            groups.append(current)
            current = []
        current.append(line)
    if current:
        groups.append(current)
    return groups


def _paragraph_units(lines: list[str], limit: int) -> list[list[str]]:
    """Packing units for one oversized paragraph: item groups, then lines."""
    units: list[list[str]] = []
    for group in _paragraph_groups(lines):
        if len(_text(group)) <= limit:
            units.append(group)
            continue
        for line in group:
            units.extend([[part] for part in _split_line(line, limit)])
    return units


def _pack_units(units: list[list[str]], limit: int) -> list[list[str]]:
    pieces: list[list[str]] = []
    current: list[str] = []
    for unit in units:
        if current and len(_text(current + unit)) > limit:
            pieces.append(current)
            current = []
        current = current + unit
    if current:
        pieces.append(current)
    return pieces


def _split_paragraph(lines: list[str], limit: int) -> list[list[str]]:
    return _pack_units(_paragraph_units(lines, limit), limit)


def _fence_options(opener: str, close: str, body: list[str], limit: int):
    """Return valid fence pairs and their body budgets, most faithful first."""
    fence = _fence_run(opener)
    assert fence is not None
    char, length, info = fence
    runs = [len(match.group()) for line in body
            for match in re.finditer(re.escape(char) + "+", line)]
    minimum = char * max(3, max(runs, default=0) + 1)
    openers = [opener]
    tag = info.strip().split()[0] if info.strip() else ""
    if tag:
        openers.append(char * length + tag)
    openers.append(char * length)
    if len(minimum) < len(opener):
        openers.append(minimum)
    closers = [close]
    if len(minimum) < len(close):
        closers.append(minimum)
    return [(start, end, limit - len(start) - len(end) - 2)
            for end in dict.fromkeys(closers)
            for start in dict.fromkeys(openers)
            if _is_closer(end, _fence_run(start))
            and limit - len(start) - len(end) - 2 >= (1 if body else -1)]


def _split_fence(lines: list[str], limit: int) -> list[list[str]]:
    fence = _fence_run(lines[0])
    assert fence is not None
    closed = len(lines) > 1 and _is_closer(lines[-1], fence)
    close = lines[-1] if closed else fence[0] * fence[1]
    body = lines[1:-1] if closed else lines[1:]
    options = _fence_options(lines[0], close, body, limit)
    if not options:
        body = [part for line in body
                for part in _split_line(line, max(1, (limit - 4) // 3))]
        options = _fence_options(lines[0], close, body, limit)
    capacity = max(room for _, _, room in options)
    required = max((len(line) for line in body if len(line) <= capacity),
                   default=1 if body else -1)
    reopen, close, budget = next(option for option in options if option[2] >= required)
    units = [[part] for line in body for part in _split_line(line, budget)]
    return [[reopen] + piece + [close] for piece in _pack_units(units, budget)] \
        if units else [[reopen, close]]


def _split_block(block: dict, limit: int) -> list[list[str]]:
    if block["kind"] == "fence":
        return _split_fence(block["lines"], limit)
    return _split_paragraph(block["lines"], limit)


def _extend(current: list[str], gap: list[str], lines: list[str]) -> list[str]:
    if current:
        return current + list(gap) + list(lines)
    return list(lines)


def _pack(blocks: list[dict], limit: int) -> list[list[str]]:
    chunks: list[list[str]] = []
    current: list[str] = []
    for block in blocks:
        lines = block["lines"]
        if len(_text(lines)) <= limit:
            candidate = _extend(current, block["gap"], lines)
            if len(_text(candidate)) <= limit:
                current = candidate
                continue
            if current:
                chunks.append(current)
            current = list(lines)
            continue
        if current:
            chunks.append(current)
            current = []
        pieces = _split_block(block, limit)
        chunks.extend(pieces[:-1])
        current = list(pieces[-1])
    if current:
        chunks.append(current)
    return chunks


def _ending_fence(lines: list[str]):
    """Return (opener_index, opener_line, closer_line) for a block ending the chunk."""
    state = None
    open_index = None
    open_line = None
    for index, line in enumerate(lines):
        if state is None:
            opener = _fence_run(line)
            if opener is not None:
                state = opener
                open_index = index
                open_line = line
        elif _is_closer(line, state):
            if index == len(lines) - 1:
                return open_index, open_line, line
            state = None
            open_index = None
            open_line = None
    if state is not None:
        return open_index, open_line, state[0] * state[1]
    return None


def _mark_plain(lines: list[str], limit: int) -> list[str]:
    """Mark a fence-balanced chunk as truncated on its last line."""
    if not lines:
        return [ELLIPSIS]
    if len(lines) > 1 and len(_text(lines)) + 1 > limit:
        return _mark_truncated(lines[:-1], limit)
    head = _text(lines[:-1])
    room = limit - len(head) - (1 if len(lines) > 1 else 0) - 1
    if room < 0:
        room = 0
    tail = lines[-1][:room] + ELLIPSIS
    while _fence_run(tail) is not None:
        room -= 1
        tail = lines[-1][:room] + ELLIPSIS
    return lines[:-1] + [tail]


def _mark_truncated(lines: list[str], limit: int) -> list[str]:
    """Mark a chunk as truncated without breaking its fences or the limit."""
    if not lines:
        return [ELLIPSIS]
    ending = _ending_fence(lines)
    if ending is not None:
        open_index, open_line, close = ending
        head = lines[:open_index]
        fence = _fence_run(open_line)
        assert fence is not None
        end = -1 if _is_closer(lines[-1], fence) else len(lines)
        body = lines[open_index + 1 : end]
        content = list(body)
        available = limit - len(_text(head)) - (1 if head else 0)
        while True:
            marked = content + [ELLIPSIS]
            for opener, closer, room in _fence_options(open_line, close, marked, available):
                if len(_text(marked)) <= room:
                    return head + [opener] + marked + [closer]
            if not content:
                break
            content = content[:-1]
        if head:
            return _mark_plain(head, limit)
        return [ELLIPSIS]
    return _mark_plain(lines, limit)


def _truncate(chunks: list[list[str]], cap: int, limit: int) -> list[list[str]]:
    if len(chunks) <= cap:
        return chunks
    kept = chunks[:cap]
    kept[-1] = _mark_truncated(kept[-1], limit)
    return kept


def split_discord(text: str, limit: int = DEFAULT_LIMIT, cap: int = DEFAULT_CAP) -> list[str]:
    """Split one Discord reply into at most `cap` chunks of at most `limit`."""
    if limit < 1 or cap < 1:
        raise ValueError("limit and cap must be positive")
    if len(text) <= limit:
        return [text]
    lines = text.split("\n")
    # Only blank lines at the two ends are dropped; a content line's own leading
    # or trailing whitespace is never touched.
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines:
        return []
    normalised = "\n".join(lines)
    if len(normalised) <= limit:
        return [normalised]
    chunks = _pack(_blocks(lines), limit)
    return [_text(chunk) for chunk in _truncate(chunks, cap, limit)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Split a Discord reply into message chunks.")
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    parser.add_argument("--cap", type=int, default=DEFAULT_CAP)
    args = parser.parse_args(argv)
    texts = split_discord(sys.stdin.read(), args.limit, args.cap)
    json.dump({"limit": args.limit, "cap": args.cap, "texts": texts}, sys.stdout,
              ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

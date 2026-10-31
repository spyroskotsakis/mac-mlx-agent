#!/usr/bin/env python3
"""Apply (idempotently) the GPT-OSS thinking-detection patch to installed mlx-lm.

GPT-OSS (120B/20B) always answers inside deliberative-alignment channels —
``<|channel|>analysis`` (its reasoning) then ``<|channel|>final`` (its answer).
mlx-lm 0.32.x's ``_infer_thinking`` probes for the non-existent ``<|channel>`` /
``<channel|>`` half-tokens, so the raw tags leak into the reply ``content`` and
the next turn 404s with *"you have passed a message containing ``<|channel|>``
tags"*. This inserts a branch that maps the analysis channel to the ``reasoning``
field and leaves only the final answer in ``content``.

Safe to run repeatedly — it no-ops when the patch is already present. It must be
re-run after ``pip install -U mlx-lm``, which overwrites ``tokenizer_utils.py``.
Run it with the same Python that has mlx-lm installed (``setup.sh`` does this via
its ``$PYTHON``, default ``python3``).

Usage:
    python3 patch_mlx_gptoss.py          # patch the mlx-lm importable in this Python
"""
import os
import sys

# The block inserted just before the "# Multi token thinking modes" branch inside
# `_infer_thinking`. It is the exact code already present in this environment.
BLOCK = """\
    # GPT-OSS deliberative-alignment channels (gpt-oss family). The model always
    # answers inside `<|channel|>analysis` (reasoning) then `<|channel|>final`
    # (the answer). Splitting analysis into `reasoning` and leaving only the
    # final answer in `content` is what lets the channel tags round-trip; the
    # stock template otherwise rejects them with the `<|channel|>` 404.
    if "<|channel|>" in vocab and "<|message|>" in vocab:
        think_start = "<|channel|>analysis"
        think_end = "<|channel|>final<|message|>"
        return (
            think_start,
            think_end,
            tuple(tokenizer.encode(think_start, add_special_tokens=False)),
            tuple(tokenizer.encode(think_end, add_special_tokens=False)),
        )
"""

MARKER = "GPT-OSS deliberative-alignment channels"
# The comment line inside `_infer_thinking`, including its 4-space function-body
# indentation, so the replace below preserves the indent of the block it inserts.
ANCHOR = "    # Multi token thinking modes"


def main() -> int:
    try:
        import mlx_lm.tokenizer_utils as t
    except Exception as exc:  # mlx-lm not importable in this Python — nothing to patch
        print(f"mlx-lm not importable ({exc}); skipping GPT-OSS patch.", file=sys.stderr)
        return 0

    path = os.path.abspath(t.__file__)
    with open(path) as f:
        src = f.read()

    if MARKER in src:
        print("mlx-lm GPT-OSS patch already present.")
        return 0
    if ANCHOR not in src:
        print(
            f"mlx-lm GPT-OSS patch skipped: anchor {ANCHOR!r} not found in {path}",
            file=sys.stderr,
        )
        return 0

    src = src.replace(ANCHOR, BLOCK + "\n" + ANCHOR, 1)
    with open(path, "w") as f:
        f.write(src)
    print(f"Applied mlx-lm GPT-OSS patch to {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

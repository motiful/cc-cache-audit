# cc-cache-audit

Claude Code v2.1.69+ injects a dynamic billing header into the system prompt that breaks cross-session prompt cache sharing. This repo contains the A/B test that proves it and the one-line fix.

## The Fix

```bash
echo 'export CLAUDE_CODE_ATTRIBUTION_HEADER=false' >> ~/.zshrc
source ~/.zshrc
```

## What's Happening

Since v2.1.69, Claude Code prepends an `x-anthropic-billing-header` string to the system prompt. This string contains a hash derived from the first user message — so it changes every conversation. Anthropic's prompt cache requires [100% identical prefixes](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) to hit, so the system prompt (~12K tokens) gets rebuilt from scratch on every new session.

## A/B Test Results

|  | cache_read | cache_creation | hit ratio |
|--|-----------|----------------|-----------|
| **Header ON** (default) | ~11,272 | ~12,200 | 48% |
| **Header OFF** | ~23,475 | 0 | 99.98% |

The ~11K that caches in both cases is the tools block (unaffected by the header). The ~12K system prompt block only caches when the header is removed.

**Per-session savings: ~85% on system prompt processing (~7x cheaper).**

Full analysis in [`report.md`](report.md).

## Run It Yourself

```bash
chmod +x run-test.sh
./run-test.sh
```

Runs 4 sessions with the header ON, then 4 with it OFF. Extracts `cache_read_input_tokens` from session JSONL files and generates a comparison report in `results/report.md`.

Requires `claude` CLI installed and authenticated.

## Related Issues

- [#40652](https://github.com/anthropics/claude-code/issues/40652) — cch= substitution permanently breaks cache
- [#34629](https://github.com/anthropics/claude-code/issues/34629) — 20x cost regression since v2.1.69
- [#40524](https://github.com/anthropics/claude-code/issues/40524) — conversation history cache invalidated (90+ thumbs up)

## Environment

Tested on Claude Code 2.1.88 / macOS arm64 / `claude --print` mode / 2026-03-31.

## License

MIT

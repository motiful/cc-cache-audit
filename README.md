# cc-cache-audit

Claude Code v2.1.69+ injects a dynamic billing header into the system prompt that breaks cross-session prompt cache sharing. This repo contains the A/B test that proves it and the one-line fix.

## The Fix

```bash
echo 'export CLAUDE_CODE_ATTRIBUTION_HEADER=false' >> ~/.zshrc
source ~/.zshrc
```

Only affects new sessions. Existing ones keep running fine.

## Root Cause

Since v2.1.69, Claude Code prepends an `x-anthropic-billing-header` string to the system prompt:

```
x-anthropic-billing-header: cc_version=2.1.88.a3f; cc_entrypoint=cli; cch=00000;
```

That `.a3f` suffix is a 3-char SHA-256 hash computed from the first user message in each conversation:

```javascript
// Deobfuscated from cli.js
function computeHash(firstUserMessage, version) {
  const chars = [4, 7, 20].map(i => firstUserMessage[i] || "0").join("");
  return sha256("59cf53e54c78" + chars + version).slice(0, 3);
}
```

Different conversation → different first message → different hash → different system prompt prefix.

Anthropic's prompt cache uses [prefix matching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) with no per-session isolation — cache is shared at the Organization/Workspace level. So all Claude Code sessions *should* share the same cached system prompt. But the billing header makes each session's prefix unique, causing the system prompt (~12K tokens) to get rebuilt from scratch every time.

## A/B Test

4 sessions per round, each with a different prompt, sequential with 8-second gaps (within the 5-min cache TTL). All sessions use `claude --print` mode.

### Round A — Header ON (default)

| Session | Prompt | cache_read | cache_creation | hit ratio |
|---------|--------|-----------|----------------|-----------|
| 1 | What is the capital of France? | 11,272 | 12,206 | 48.0% |
| 2 | List three prime numbers under 20. | 11,272 | 12,202 | 48.0% |
| 3 | Explain what a goroutine is in one sentence. | 11,374 | 12,753 | 47.1% |
| 4 | Name one benefit of TypeScript over JavaScript. | 11,272 | 12,203 | 48.0% |

Every session rebuilds ~12K tokens of cache.

### Round B — Header OFF

| Session | Prompt | cache_read | cache_creation | hit ratio |
|---------|--------|-----------|----------------|-----------|
| 1 | What is the capital of France? | 23,478 | 0 | 99.98% |
| 2 | List three prime numbers under 20. | 23,474 | 0 | 99.98% |
| 3 | Explain what a goroutine is in one sentence. | 11,272 | 12,197 | 48.0% |
| 4 | Name one benefit of TypeScript over JavaScript. | 23,475 | 0 | 99.98% |

3 out of 4 sessions: zero cache creation, full cache read. Session 3 was a server-side cache eviction — cache came right back for session 4.

### What the Numbers Mean

The data shows a two-tier caching pattern, consistent with the Anthropic API's cache hierarchy (`tools → system → messages`):

- **Tools block (~11,272 tokens)**: Tool definitions are stable across sessions — always cached regardless of header setting.
- **System prompt block (~12,200 tokens)**: Contains the billing header with a per-session hash — rebuilt every session when header is ON.

With the header OFF, both blocks are fully cacheable → 99.98% hit ratio.

### Cost Impact

Using Anthropic pricing (cache_read = 0.1x base, cache_creation = 1.25x base):

| | Header ON (per session) | Header OFF (per session) |
|--|----------------------|------------------------|
| Effective cost | 11,272×0.1 + 12,200×1.25 + 3 ≈ **16,380 equiv tokens** | 23,475×0.1 + 0 + 3 ≈ **2,351 equiv tokens** |
| | baseline | **~85% reduction (~7x cheaper)** |

This measures system prompt cost only. For long conversations where user messages dominate, the relative savings decrease.

## FAQ

**Will this get me banned?**

No reports of anyone being banned or warned. [claude-code-router](https://github.com/musistudio/claude-code-router/pull/1220) and [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI/issues/1592) ship with this disabled in production. The env var is a proper feature toggle in the source code.

**Why did Anthropic add this?**

Internal billing attribution — tracking which Claude Code version and entrypoint (CLI, SDK, GitHub Action) made each API call. It's in the system prompt instead of HTTP headers probably because Bedrock/Vertex don't forward custom headers. The API has a `metadata` field designed for exactly this kind of thing.

**Do I need to restart existing sessions?**

No. Old sessions use their own cache keys and don't interfere with new ones.

## Caveats

- Tested with `claude --print` mode only. Interactive mode uses a larger system prompt — absolute numbers will differ, but the mechanism is the same.
- Sample size is n=4 per round. The pattern is clear but more runs would strengthen confidence.
- Server-side cache eviction is non-deterministic (see session B-3).

## Run It Yourself

```bash
chmod +x run-test.sh
./run-test.sh
```

Runs 4 sessions with the header ON, then 4 with it OFF. Extracts `cache_read_input_tokens` from session JSONL files and generates a raw comparison in `results/`.

The detailed report with full analysis is in [`report.md`](report.md).

Requires `claude` CLI installed and authenticated. Note: the script outputs local JSONL paths in metrics files — scrub them before publishing.

## Related Issues

- [#40652](https://github.com/anthropics/claude-code/issues/40652) — cch= substitution permanently breaks cache
- [#34629](https://github.com/anthropics/claude-code/issues/34629) — 20x cost regression since v2.1.69
- [#40524](https://github.com/anthropics/claude-code/issues/40524) — conversation history cache invalidated (90+ thumbs up)

## Environment

Claude Code 2.1.88 / macOS arm64 / `claude --print` mode / 2026-03-31.

## Author

- GitHub: [@motiful](https://github.com/motiful)
- X: [@whiletrue0x](https://x.com/whiletrue0x)

## License

MIT

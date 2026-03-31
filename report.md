# Claude Code Prompt Cache A/B Test Report

## Experiment Design

**Hypothesis**: `CLAUDE_CODE_ATTRIBUTION_HEADER=false` restores cross-session prompt cache sharing by removing the per-session dynamic hash from system prompt prefix.

**Method**:
- Round A (control): 4 sessions with default settings (billing header ON)
- Round B (treatment): 4 sessions with `CLAUDE_CODE_ATTRIBUTION_HEADER=false`
- Each session sends a DIFFERENT prompt (simulating real usage)
- All sessions use `claude --print` mode (single-shot, non-interactive)
- Sessions run sequentially with 8s gap (within 5-min cache TTL)
- Metric: `cache_read_input_tokens` on the FIRST API request of each session

**Key expectation**: In Round A, each session should show partial cache_read (tools block cached, system prompt rebuilt due to header hash change). In Round B, sessions 2+ should show full cache_read (both tools and system prompt served from cache).

## Results

### Round A — Header ON (default)

| Session | Prompt | cache_read | cache_creation | input_tokens | hit_ratio |
|---------|--------|-----------|----------------|-------------|-----------|
| 1 | What is the capital of France? Answer in... | 11272 | 12206 | 3 | .4800 |
| 2 | List three prime numbers under 20.... | 11272 | 12202 | 3 | .4801 |
| 3 | Explain what a goroutine is in one sente... | 11374 | 12753 | 3 | .4713 |
| 4 | Name one benefit of TypeScript over Java... | 11272 | 12203 | 3 | .4801 |

### Round B — Header OFF

| Session | Prompt | cache_read | cache_creation | input_tokens | hit_ratio |
|---------|--------|-----------|----------------|-------------|-----------|
| 1 | What is the capital of France? Answer in... | 23478 | 0 | 3 | .9998 |
| 2 | List three prime numbers under 20.... | 23474 | 0 | 3 | .9998 |
| 3 | Explain what a goroutine is in one sente... | 11272 | 12197 | 3 | .4802 |
| 4 | Name one benefit of TypeScript over Java... | 23475 | 0 | 3 | .9998 |

## Analysis

### Data Comparison Table

| Session | Round A cache_read | Round A cache_creation | Round B cache_read | Round B cache_creation | Delta cache_read |
|---------|-------------------|----------------------|-------------------|----------------------|-----------------|
| 1       | 11,272            | 12,206               | 23,478            | 0                    | **+12,206** (+108%) |
| 2       | 11,272            | 12,202               | 23,474            | 0                    | **+12,202** (+108%) |
| 3       | 11,374            | 12,753               | 11,272            | 12,197               | -102 (anomaly)  |
| 4       | 11,272            | 12,203               | 23,475            | 0                    | **+12,203** (+108%) |

Total prompt size (tools + system): ~23,478 tokens (confirmed by Round B full-cache sessions).

### Key Findings

**1. Hypothesis CONFIRMED — billing header prevents ~52% of prompt cache sharing**

The data reveals a two-tier caching pattern, consistent with the Anthropic API's cache hierarchy (`tools → system → messages`):

- **Tools block (~11,272 tokens)**: Tool definitions are stable across sessions — always cached regardless of header setting
- **System prompt block (~12,200 tokens)**: Contains the billing header with a per-session hash — re-created every session when header is ON, because the hash changes the cache key for this block

With `CLAUDE_CODE_ATTRIBUTION_HEADER=false`, both blocks are fully cacheable → 99.98% hit ratio.

**2. Round A (header ON): Consistent ~48% cache hit ratio**

Every session shows the same pattern: ~11,272 cache_read (tools block) + ~12,200 cache_creation (system prompt block). The billing header hash changes per session, preventing the system prompt from being served from cache.

**3. Round B (header OFF): Near-perfect cache sharing (3/4 sessions)**

Sessions 1, 2, 4 achieved ~23,475 cache_read with 0 cache_creation — the entire prompt (tools + system) is served from cache.

**4. Anomalous Session B-3**

Session B-3 showed the Round A pattern (11,272 read + 12,197 creation) instead of full cache hits. Possible causes:
- Server-side cache eviction between B-2 and B-3 (8s gap, within 5-min TTL but eviction is unpredictable)
- Session B-3's JSONL resolved to a different project directory than the other sessions
- Note: B-4 achieved full cache again (23,475), confirming B-3's cache_creation was successfully reused

**5. Cost Impact Estimate**

Using Anthropic pricing (cache_read = 0.1x base, cache_creation = 1.25x base):

| Metric | Round A (per session) | Round B (per session, typical) |
|--------|----------------------|-------------------------------|
| Effective input cost | 11,272×0.1 + 12,200×1.25 + 3 = **~16,380 equiv tokens** | 23,475×0.1 + 0 + 3 = **~2,351 equiv tokens** |
| Savings | — | **~85% reduction** (~7x cheaper) |

Note: This comparison measures system prompt cost only. For long conversations, user messages and tool results dominate the total token count, so the relative savings decrease as conversations grow.

### Conclusion

**The billing header (`CLAUDE_CODE_ATTRIBUTION_HEADER`) prevents cross-session prompt cache sharing for the system prompt block (~12K tokens).** Setting `CLAUDE_CODE_ATTRIBUTION_HEADER=false` restores full cache sharing, reducing per-session system prompt costs by ~85%.

This is particularly impactful for:
- **Multi-session workflows** — running several Claude Code instances on the same project in parallel
- **Rapid iteration** — frequent short sessions that repeatedly pay cache_creation cost
- **CI/CD and automation** — multiple `claude --print` calls in sequence (pipelines, batch processing)

**Recommendation**: Set `CLAUDE_CODE_ATTRIBUTION_HEADER=false` in environments where cross-session cache efficiency matters.

## Caveats

- Tested with `claude --print` mode only. Interactive mode uses a different (larger) system prompt — the absolute numbers will differ, but the mechanism is the same.
- Sample size is n=4 per round. The pattern is clear (3/4 full cache hit vs 0/4), but larger samples would strengthen the statistical confidence.
- Server-side cache eviction is non-deterministic — individual runs may show variance (as seen in session B-3).

## Environment

- Claude Code version: 2.1.88 (Claude Code)
- Test mode: `claude --print` (single-shot, non-interactive)
- Date: 2026-03-31 08:23:21 UTC
- Platform: Darwin arm64
- Node: v22.14.0

## Raw Data

See `results/round-a/` and `results/round-b/` for per-session metrics JSON files.

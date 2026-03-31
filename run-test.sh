#!/bin/bash
# ============================================================
# Claude Code Prompt Cache A/B Test
# ============================================================
# Purpose: Prove whether CLAUDE_CODE_ATTRIBUTION_HEADER=false
#          restores cross-session prompt cache sharing.
#
# Design:
#   Round A (control):   header ON  (default) — 4 sessions, different prompts
#   Round B (treatment): header OFF           — 4 sessions, different prompts
#   Each session runs --print mode with a single prompt, then exits.
#   We extract cache metrics from JSONL and compare.
#
# Usage:
#   chmod +x run-test.sh
#   ./run-test.sh
#
# Output:
#   ./results/round-a/*.json   — raw metrics, header ON
#   ./results/round-b/*.json   — raw metrics, header OFF
#   ./results/report.md        — final comparison report
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
ROUND_A_DIR="$RESULTS_DIR/round-a"
ROUND_B_DIR="$RESULTS_DIR/round-b"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# 4 different prompts — different first messages = different billing header hash
PROMPTS=(
  "What is the capital of France? Answer in one word."
  "List three prime numbers under 20."
  "Explain what a goroutine is in one sentence."
  "Name one benefit of TypeScript over JavaScript."
)

# Interval between sessions (seconds) — let cache TTL stay warm
INTERVAL=8

# ============================================================
# Functions
# ============================================================

find_latest_jsonl() {
  # Find the most recently modified JSONL file across all project dirs
  local after_ts="$1"
  find ~/.claude/projects/ -name "*.jsonl" -newer "$after_ts" -print 2>/dev/null \
    | xargs ls -t 2>/dev/null \
    | head -1
}

extract_metrics() {
  local jsonl_file="$1"
  local output_file="$2"
  local prompt_text="$3"
  local round_label="$4"
  local session_idx="$5"

  if [[ -z "$jsonl_file" || ! -f "$jsonl_file" ]]; then
    echo "{\"error\": \"no jsonl found\", \"round\": \"$round_label\", \"session\": $session_idx}" > "$output_file"
    return
  fi

  # Extract first API response's usage block
  local input_tokens cache_read cache_creation output_tokens
  input_tokens=$(grep -o '"input_tokens":[0-9]*' "$jsonl_file" | head -1 | cut -d: -f2)
  cache_read=$(grep -o '"cache_read_input_tokens":[0-9]*' "$jsonl_file" | head -1 | cut -d: -f2)
  cache_creation=$(grep -o '"cache_creation_input_tokens":[0-9]*' "$jsonl_file" | head -1 | cut -d: -f2)
  output_tokens=$(grep -o '"output_tokens":[0-9]*' "$jsonl_file" | head -1 | cut -d: -f2)

  cat > "$output_file" <<EOF
{
  "round": "$round_label",
  "session": $session_idx,
  "prompt": "$prompt_text",
  "jsonl": "$jsonl_file",
  "first_request": {
    "input_tokens": ${input_tokens:-0},
    "cache_read_input_tokens": ${cache_read:-0},
    "cache_creation_input_tokens": ${cache_creation:-0},
    "output_tokens": ${output_tokens:-0}
  },
  "cache_hit_ratio": "$(echo "scale=4; ${cache_read:-0} / (${cache_read:-0} + ${input_tokens:-1} + ${cache_creation:-0})" | bc 2>/dev/null || echo "N/A")"
}
EOF
}

run_round() {
  local round_label="$1"   # "a" or "b"
  local header_val="$2"    # "" (default) or "false"
  local out_dir="$3"

  mkdir -p "$out_dir"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  local round_upper
  round_upper=$(echo "$round_label" | tr '[:lower:]' '[:upper:]')
  echo "  Round ${round_upper}: CLAUDE_CODE_ATTRIBUTION_HEADER=${header_val:-"(default/on)"}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  for i in "${!PROMPTS[@]}"; do
    local idx=$((i + 1))
    local prompt="${PROMPTS[$i]}"
    echo ""
    echo "  [$round_label-$idx] Prompt: \"$prompt\""

    # Create a timestamp marker file
    local marker="$out_dir/.marker-$idx"
    touch "$marker"
    sleep 1  # ensure filesystem time resolution

    # Run claude in --print mode (single shot, no interactive)
    if [[ -n "$header_val" ]]; then
      CLAUDE_CODE_ATTRIBUTION_HEADER="$header_val" claude --print "$prompt" > "$out_dir/output-$idx.txt" 2>&1 || true
    else
      # Unset to use default behavior (header ON)
      unset CLAUDE_CODE_ATTRIBUTION_HEADER 2>/dev/null || true
      claude --print "$prompt" > "$out_dir/output-$idx.txt" 2>&1 || true
    fi

    # Find the JSONL created by this session
    sleep 1
    local jsonl
    jsonl=$(find_latest_jsonl "$marker")
    echo "  [$round_label-$idx] JSONL: ${jsonl:-"NOT FOUND"}"

    # Extract metrics
    extract_metrics "$jsonl" "$out_dir/metrics-$idx.json" "$prompt" "$round_label" "$idx"

    # Show quick summary
    if [[ -f "$out_dir/metrics-$idx.json" ]]; then
      local cr
      cr=$(grep cache_read_input_tokens "$out_dir/metrics-$idx.json" | grep -o '[0-9]*')
      echo "  [$round_label-$idx] cache_read_input_tokens = ${cr:-0}"
    fi

    # Wait before next session to keep cache warm
    if [[ $idx -lt ${#PROMPTS[@]} ]]; then
      echo "  [$round_label-$idx] Waiting ${INTERVAL}s for cache TTL..."
      sleep "$INTERVAL"
    fi
  done
}

generate_report() {
  local report="$RESULTS_DIR/report.md"

  cat > "$report" <<'HEADER'
# Claude Code Prompt Cache A/B Test Report

## Experiment Design

**Hypothesis**: `CLAUDE_CODE_ATTRIBUTION_HEADER=false` restores cross-session prompt cache sharing by removing the per-session dynamic hash from system prompt prefix.

**Method**:
- Round A (control): 4 sessions with default settings (billing header ON)
- Round B (treatment): 4 sessions with `CLAUDE_CODE_ATTRIBUTION_HEADER=false`
- Each session sends a DIFFERENT prompt (simulating real usage)
- Sessions run sequentially with 8s gap (within 5-min cache TTL)
- Metric: `cache_read_input_tokens` on the FIRST API request of each session

**Key expectation**: In Round B, sessions 2-4 should show high `cache_read_input_tokens` (system prompt cached from session 1). In Round A, all sessions should show low/zero cache_read (each has a unique system prompt prefix).

## Results

HEADER

  echo "### Round A — Header ON (default)" >> "$report"
  echo "" >> "$report"
  echo "| Session | Prompt | cache_read | cache_creation | input_tokens | hit_ratio |" >> "$report"
  echo "|---------|--------|-----------|----------------|-------------|-----------|" >> "$report"

  for f in "$ROUND_A_DIR"/metrics-*.json; do
    [[ -f "$f" ]] || continue
    local sess prompt cr cc it ratio
    sess=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('session','?'))" 2>/dev/null || echo "?")
    prompt=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('prompt','?')[:40])" 2>/dev/null || echo "?")
    cr=$(python3 -c "import json; d=json.load(open('$f')); print(d['first_request'].get('cache_read_input_tokens',0))" 2>/dev/null || echo "0")
    cc=$(python3 -c "import json; d=json.load(open('$f')); print(d['first_request'].get('cache_creation_input_tokens',0))" 2>/dev/null || echo "0")
    it=$(python3 -c "import json; d=json.load(open('$f')); print(d['first_request'].get('input_tokens',0))" 2>/dev/null || echo "0")
    ratio=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('cache_hit_ratio','N/A'))" 2>/dev/null || echo "N/A")
    echo "| $sess | ${prompt}... | $cr | $cc | $it | $ratio |" >> "$report"
  done

  echo "" >> "$report"
  echo "### Round B — Header OFF" >> "$report"
  echo "" >> "$report"
  echo "| Session | Prompt | cache_read | cache_creation | input_tokens | hit_ratio |" >> "$report"
  echo "|---------|--------|-----------|----------------|-------------|-----------|" >> "$report"

  for f in "$ROUND_B_DIR"/metrics-*.json; do
    [[ -f "$f" ]] || continue
    local sess prompt cr cc it ratio
    sess=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('session','?'))" 2>/dev/null || echo "?")
    prompt=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('prompt','?')[:40])" 2>/dev/null || echo "?")
    cr=$(python3 -c "import json; d=json.load(open('$f')); print(d['first_request'].get('cache_read_input_tokens',0))" 2>/dev/null || echo "0")
    cc=$(python3 -c "import json; d=json.load(open('$f')); print(d['first_request'].get('cache_creation_input_tokens',0))" 2>/dev/null || echo "0")
    it=$(python3 -c "import json; d=json.load(open('$f')); print(d['first_request'].get('input_tokens',0))" 2>/dev/null || echo "0")
    ratio=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('cache_hit_ratio','N/A'))" 2>/dev/null || echo "N/A")
    echo "| $sess | ${prompt}... | $cr | $cc | $it | $ratio |" >> "$report"
  done

  cat >> "$report" <<'FOOTER'

## Analysis

Compare sessions 2-4 between rounds:
- **Round A**: If `cache_read` stays low across all sessions → billing header is preventing cross-session cache sharing
- **Round B**: If `cache_read` jumps high on sessions 2-4 → disabling the header restores cache sharing

## Environment

FOOTER

  echo "- Claude Code version: $(claude --version 2>/dev/null || echo 'unknown')" >> "$report"
  echo "- Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$report"
  echo "- Platform: $(uname -s) $(uname -m)" >> "$report"
  echo "- Node: $(node --version 2>/dev/null || echo 'unknown')" >> "$report"

  echo "" >> "$report"
  echo "## Raw Data" >> "$report"
  echo "" >> "$report"
  echo "See \`results/round-a/\` and \`results/round-b/\` for full JSONL paths and metrics." >> "$report"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Report generated: $report"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ============================================================
# Main
# ============================================================

echo "╔══════════════════════════════════════════════╗"
echo "║  Claude Code Prompt Cache A/B Test           ║"
echo "║  $TIMESTAMP                        ║"
echo "╚══════════════════════════════════════════════╝"

mkdir -p "$ROUND_A_DIR" "$ROUND_B_DIR"

# Round A: header ON (default)
run_round "a" "" "$ROUND_A_DIR"

echo ""
echo "  ⏳ Waiting 15s between rounds (let cache TTL expire for clean baseline)..."
sleep 15

# Round B: header OFF
run_round "b" "false" "$ROUND_B_DIR"

# Generate report
generate_report

echo ""
echo "Done! Review the report:"
echo "  cat $RESULTS_DIR/report.md"

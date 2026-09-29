#!/usr/bin/env bash
# End-to-end check that the engine's Codex parser produces a deterministic
# token total on a known fixture. The fixture is written with a fresh
# timestamp so it never ages out of the retain window. Asserts the
# field-mapping math (uncached = input - cached, output = gross, never re-add
# reasoning) one more time at the CLI surface; pure unit coverage already
# lives in --self-test.
#
# The expected total is event 1 (4697 + 361 + 9600) plus event 2
# (18435 + 546 + 9600) = 43239. `output` is already gross, reasoning included,
# so reasoning is never added again.
#
# Usage: scripts/codex-smoke.sh <path to sissy-cli>

set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <path to sissy-cli>" >&2; exit 2; }
CLI="$1"

FIXTURE_HOME="$(mktemp -d -t sissy-codex-smoke)"
trap 'rm -rf "$FIXTURE_HOME"' EXIT
mkdir -p "$FIXTURE_HOME/sessions/2026/05/25"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
cat > "$FIXTURE_HOME/sessions/2026/05/25/rollout-fixture.jsonl" <<JSONL
{"type":"session_meta","timestamp":"$NOW","payload":{"id":"fixture","timestamp":"$NOW","model_provider":"openai"}}
{"type":"turn_context","timestamp":"$NOW","payload":{"turn_id":"t1","model":"gpt-5-codex"}}
{"type":"event_msg","timestamp":"$NOW","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":14297,"cached_input_tokens":9600,"output_tokens":361,"reasoning_output_tokens":0,"total_tokens":14658},"total_token_usage":{"input_tokens":14297,"cached_input_tokens":9600,"output_tokens":361,"reasoning_output_tokens":0,"total_tokens":14658}}}}
{"type":"event_msg","timestamp":"$NOW","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":28035,"cached_input_tokens":9600,"output_tokens":546,"reasoning_output_tokens":66,"total_tokens":28581},"total_token_usage":{"input_tokens":42332,"cached_input_tokens":19200,"output_tokens":907,"reasoning_output_tokens":66,"total_tokens":43239}}}}
JSONL

EXPECTED=43239
OUT=$(CODEX_HOME="$FIXTURE_HOME" "$CLI" --scan --scan-provider codex)
echo "$OUT"
GOT=$(echo "$OUT" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['codex']['tokens'])")
[[ "$GOT" == "$EXPECTED" ]] || { echo "Codex parser drift: expected $EXPECTED, got $GOT" >&2; exit 1; }

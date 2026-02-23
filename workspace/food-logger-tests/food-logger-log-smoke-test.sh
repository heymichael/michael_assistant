#!/usr/bin/env bash
# End-to-end smoke test for food logging:
# 1) pick shortest and longest prompts from prompts file
# 2) submit each prompt to OpenClaw in its own session
# 3) send "save" in the same session
# 4) poll Google Sheet for an appended row
# 5) print last logged A:M values for each case

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_FILE="${SCRIPT_DIR}/food-logger-test-prompts.txt"

TARGET="${TARGET:-6822603184}"
SHEET_ID="${SHEET_ID:-1G_Vupq2nxYe6lIySuItTMIjo8V5HZFLYbTU3O54R1Kw}"
SHEET_RANGE="${SHEET_RANGE:-Sheet1!A:M}"
RESTART_GATEWAY="${RESTART_GATEWAY:-1}"
POLL_ATTEMPTS="${POLL_ATTEMPTS:-12}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-2}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 1
  fi
}

need_cmd openclaw
need_cmd /opt/homebrew/bin/gog
need_cmd jq

if [[ ! -f "$PROMPTS_FILE" ]]; then
  echo "Prompts file not found: $PROMPTS_FILE"
  exit 1
fi

get_sheet_json() {
  /opt/homebrew/bin/gog sheets get "$SHEET_ID" "$SHEET_RANGE" --json --results-only
}

extract_rows_array() {
  printf '%s' "$1" | jq '
    if type == "array" then .
    elif type == "object" and has("values") and (.values | type == "array") then .values
    else []
    end
  '
}

rows_count_from_json() {
  extract_rows_array "$1" | jq 'length'
}

pick_shortest_and_longest_prompts() {
  shortest_prompt=""
  longest_prompt=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    prompt="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$prompt" ]] && continue

    if [[ -z "$shortest_prompt" || ${#prompt} -lt ${#shortest_prompt} ]]; then
      shortest_prompt="$prompt"
    fi
    if [[ -z "$longest_prompt" || ${#prompt} -gt ${#longest_prompt} ]]; then
      longest_prompt="$prompt"
    fi
  done < "$PROMPTS_FILE"

  if [[ -z "$shortest_prompt" || -z "$longest_prompt" ]]; then
    echo "No non-empty prompts found in $PROMPTS_FILE"
    exit 1
  fi
}

print_last_row() {
  extract_rows_array "$1" | jq -r '
    (.[-1] // []) as $r |
    "Date: \($r[0] // "")\n" +
    "Time: \($r[1] // "")\n" +
    "Meal: \($r[2] // "")\n" +
    "Type: \($r[3] // "")\n" +
    "Description: \($r[4] // "")\n" +
    "Calories: \($r[5] // "")\n" +
    "Fat: \($r[6] // "")\n" +
    "Carbs: \($r[7] // "")\n" +
    "Sugar: \($r[8] // "")\n" +
    "Fiber: \($r[9] // "")\n" +
    "Protein: \($r[10] // "")\n" +
    "Timezone: \($r[11] // "")\n" +
    "Rounds: \($r[12] // "")"
  '
}

run_case() {
  local label="$1"
  local prompt="$2"
  local slug session_id before_json before_count after_json after_count attempt
  local turn1_output turn2_output

  slug="$(echo "$label" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')"
  session_id="foodlog-smoke-${slug}-$(date +%s)-$$"

  echo "=================================================="
  echo "Case: $label"
  echo "Prompt (${#prompt} chars): $prompt"
  echo "Session ID: $session_id"
  echo ""

  echo "Reading sheet before logging..."
  before_json="$(get_sheet_json)"
  before_count="$(rows_count_from_json "$before_json")"
  echo "Rows before: $before_count"
  echo ""

  echo "=== TURN 1: Submit prompt ==="
  turn1_output="$(openclaw agent --to "$TARGET" --session-id "$session_id" --message "$prompt" 2>&1)"
  echo "$turn1_output"
  echo ""

  echo "=== TURN 2: Confirm save ==="
  turn2_output="$(openclaw agent --to "$TARGET" --session-id "$session_id" --message "save" 2>&1)"
  echo "$turn2_output"
  echo ""

  echo "Polling for appended row..."
  after_json="$before_json"
  after_count="$before_count"

  for ((attempt=1; attempt<=POLL_ATTEMPTS; attempt++)); do
    sleep "$POLL_INTERVAL_SECONDS"
    after_json="$(get_sheet_json)"
    after_count="$(rows_count_from_json "$after_json")"
    echo "Attempt $attempt/$POLL_ATTEMPTS -> rows: $after_count"
    if (( after_count > before_count )); then
      break
    fi
  done

  echo ""
  echo "Rows after: $after_count"
  if (( after_count <= before_count )); then
    echo "FAIL ($label): No new row detected in $SHEET_RANGE after save confirmation."
    return 1
  fi

  echo ""
  echo "=== LAST LOGGED ROW (A:M) [$label] ==="
  print_last_row "$after_json"
  echo ""
}

pick_shortest_and_longest_prompts

if [[ "$RESTART_GATEWAY" == "1" ]]; then
  echo "Restarting OpenClaw gateway..."
  openclaw gateway restart
  sleep 2
fi

echo "Running logging smoke cases:"
echo "- shortest (${#shortest_prompt} chars): $shortest_prompt"
echo "- longest  (${#longest_prompt} chars): $longest_prompt"
echo "NOTE: Non-interactive script; do not type input during execution."
echo ""

run_case "shortest" "$shortest_prompt"

if [[ "$longest_prompt" == "$shortest_prompt" ]]; then
  echo "Only one unique prompt available; skipping duplicate longest case."
else
  run_case "longest" "$longest_prompt"
fi

echo "PASS: Logging smoke test completed for shortest and longest prompts."

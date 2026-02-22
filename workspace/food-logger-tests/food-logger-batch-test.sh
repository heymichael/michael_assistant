#!/usr/bin/env bash
# Batch test script for the food logger (OpenClaw agent).
#
# Checks per response:
#   Nutrition:  Calories, Fat, Carbs, Sugar, Fiber, Protein
#   Metadata:   Date, Time, Description, Type, Meal
#   Type value: One of (case-insensitive) Home-Cooked, Restaurant, Delivery, Store-Bought (* ignored)
#   Multiples:  Each macronutrient appears exactly once
#   Values:    (only if Multiples passed) After each macro name, a 0 or positive integer (optional :* etc. before number; number may be followed by letters)
#
# Usage: ./food-logger-batch-test.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_FILE="${SCRIPT_DIR}/food-logger-test-prompts.txt"
TARGET=6822603184

REQUIRED_WORDS=(Calories Fat Sugar Fiber Protein)
CARBS_PATTERN="Carbohydrates|Carbs"
METADATA_WORDS=(Date Time Description Type Meal)
# Type allowed values (case-insensitive); normalized to lowercase with hyphen; * stripped
ALLOWED_TYPES="home-cooked|restaurant|delivery|store-bought"

if [[ ! -f "$PROMPTS_FILE" ]]; then
  echo "Prompts file not found: $PROMPTS_FILE"
  exit 1
fi

# Arrays for summary table and failure report
declare -a PROMPTS PROMPT_WORDS N_RES M_RES T_RES U_RES V_RES TYPE_VALUES
i=0
any_failed=0

while IFS= read -r prompt || [[ -n "$prompt" ]]; do
  prompt="$(echo "$prompt" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$prompt" ]] && continue
  i=$((i + 1))
  echo "=== Test $i: $prompt ==="
  response="$(openclaw agent --to "$TARGET" --message "$prompt" 2>&1)"
  echo "$response"
  echo "---"

  # ---- Nutrition ----
  missing_n=()
  for word in "${REQUIRED_WORDS[@]}"; do
    if ! echo "$response" | grep -qi "$word"; then
      missing_n+=( "$word" )
    fi
  done
  if ! echo "$response" | grep -qEi "$CARBS_PATTERN"; then
    missing_n+=( "Carbohydrates/Carbs" )
  fi
  if [[ ${#missing_n[@]} -eq 0 ]]; then
    n_res="PASS"
    echo "Nutrition:    PASS"
  else
    n_res="FAIL"
    echo "Nutrition:    FAIL (missing: ${missing_n[*]})"
    any_failed=1
  fi
  N_RES+=("$n_res")

  # ---- Metadata (presence of field names) ----
  missing_m=()
  for word in "${METADATA_WORDS[@]}"; do
    if ! echo "$response" | grep -qi "$word"; then
      missing_m+=( "$word" )
    fi
  done
  if [[ ${#missing_m[@]} -eq 0 ]]; then
    m_res="PASS"
    echo "Metadata:     PASS (Date, Time, Description, Type, Meal)"
  else
    m_res="FAIL"
    echo "Metadata:     FAIL (missing: ${missing_m[*]})"
    any_failed=1
  fi
  M_RES+=("$m_res")

  # ---- Type value (must be one of the four; strip * before comparing) ----
  type_line="$(echo "$response" | grep -i "Type:" | head -1)"
  type_value=""
  if [[ -n "$type_line" ]]; then
    type_value="$(echo "$type_line" | sed 's/.*:[[:space:]]*//;s/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '*')"
    type_value="$(echo "$type_value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  fi
  type_norm="$(echo "$type_value" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -d '\r')"
  if [[ -n "$type_norm" && "$type_norm" =~ ^($ALLOWED_TYPES)$ ]]; then
    t_res="PASS"
    echo "Type value:   PASS ($type_value)"
  else
    t_res="FAIL"
    if [[ -z "$type_value" ]]; then
      echo "Type value:   FAIL (no Type field or empty; allowed: Home-Cooked, Restaurant, Delivery, Store-Bought)"
    else
      echo "Type value:   FAIL (got \"$type_value\"; allowed: Home-Cooked, Restaurant, Delivery, Store-Bought)"
    fi
    any_failed=1
  fi
  T_RES+=("$t_res")
  TYPE_VALUES+=("$type_value")

  # ---- Multiples (each macronutrient appears exactly once) ----
  dupes=()
  count_cal="$(echo "$response" | grep -ci "Calories:" || true)"
  [[ -z "$count_cal" ]] && count_cal=0
  [[ "$count_cal" -ne 1 ]] && dupes+=( "Calories($count_cal)" )
  count_fat="$(echo "$response" | grep -ci "Fat:" || true)"
  [[ -z "$count_fat" ]] && count_fat=0
  [[ "$count_fat" -ne 1 ]] && dupes+=( "Fat($count_fat)" )
  count_carbs="$(echo "$response" | grep -ciE "Carbs:|Carbohydrates:" || true)"
  [[ -z "$count_carbs" ]] && count_carbs=0
  [[ "$count_carbs" -ne 1 ]] && dupes+=( "Carbs($count_carbs)" )
  count_sugar="$(echo "$response" | grep -ci "Sugar:" || true)"
  [[ -z "$count_sugar" ]] && count_sugar=0
  [[ "$count_sugar" -ne 1 ]] && dupes+=( "Sugar($count_sugar)" )
  count_fiber="$(echo "$response" | grep -ci "Fiber:" || true)"
  [[ -z "$count_fiber" ]] && count_fiber=0
  [[ "$count_fiber" -ne 1 ]] && dupes+=( "Fiber($count_fiber)" )
  count_protein="$(echo "$response" | grep -ci "Protein:" || true)"
  [[ -z "$count_protein" ]] && count_protein=0
  [[ "$count_protein" -ne 1 ]] && dupes+=( "Protein($count_protein)" )
  if [[ ${#dupes[@]} -eq 0 ]]; then
    u_res="PASS"
    echo "Multiples:    PASS (each macronutrient appears once)"
  else
    u_res="FAIL"
    echo "Multiples:    FAIL (repeated or missing: ${dupes[*]})"
    any_failed=1
  fi
  U_RES+=("$u_res")

  # ---- Values (only if Multiples passed): after each macro, 0 or positive integer ----
  if [[ "$u_res" == "PASS" ]]; then
    no_num=()
    for macro in "Calories" "Fat" "Sugar" "Fiber" "Protein"; do
      line="$(echo "$response" | grep -i "$macro" | head -1)"
      line_lower="$(echo "$line" | tr '[:upper:]' '[:lower:]')"
      macro_lower="$(echo "$macro" | tr '[:upper:]' '[:lower:]')"
      if [[ -z "$line" ]] || ! [[ "$line_lower" =~ ${macro_lower}[^0-9]*[0-9]+ ]]; then
        no_num+=( "$macro" )
      fi
    done
    # Carbs: line may say "Carbs" or "Carbohydrates"
    carbs_line="$(echo "$response" | grep -iE "Carbs:|Carbohydrates:" | head -1)"
    carbs_lower="$(echo "$carbs_line" | tr '[:upper:]' '[:lower:]')"
    if [[ -z "$carbs_line" ]] || ( ! [[ "$carbs_lower" =~ carbs[^0-9]*[0-9]+ ]] && ! [[ "$carbs_lower" =~ carbohydrates[^0-9]*[0-9]+ ]] ); then
      no_num+=( "Carbs" )
    fi
    if [[ ${#no_num[@]} -eq 0 ]]; then
      v_res="PASS"
      echo "Values:       PASS (each macro has 0 or positive integer)"
    else
      v_res="FAIL"
      echo "Values:       FAIL (no number after: ${no_num[*]})"
      any_failed=1
    fi
    V_RES+=("$v_res")
  else
    v_res="SKIP"
    echo "Values:       SKIP (Multiples did not pass)"
    V_RES+=("SKIP")
  fi

  prompt_words="$(echo "$prompt" | wc -w | tr -d ' ')"
  PROMPT_WORDS+=("$prompt_words")
  PROMPTS+=("$prompt")
  echo ""
done < "$PROMPTS_FILE"

# ---- Summary table ----
echo "========== SUMMARY =========="
printf "%-28s | %5s | %-9s | %-9s | %-5s | %-9s | %-6s\n" "Prompt" "Words" "Nutrition" "Metadata" "Type" "Multiples" "Values"
echo "------------------------------|-------|-----------|-----------|-------|-----------|--------"
for j in "${!PROMPTS[@]}"; do
  p="${PROMPTS[j]}"
  [[ ${#p} -gt 27 ]] && p="${p:0:24}..."
  printf "%-28s | %5s | %-9s | %-9s | %-5s | %-9s | %-6s\n" "$p" "${PROMPT_WORDS[j]}" "${N_RES[j]}" "${M_RES[j]}" "${T_RES[j]}" "${U_RES[j]}" "${V_RES[j]}"
done
echo "------------------------------|-------|-----------|-----------|-------|-----------|--------"
echo "Ran $i prompts."
echo ""

# ---- Failed tests: one line per failure (prompt | test | type value only if Type failed) ----
if [[ $any_failed -ne 0 ]]; then
  echo "========== FAILED TESTS =========="
  for j in "${!PROMPTS[@]}"; do
    p="${PROMPTS[j]}"
    [[ "${N_RES[j]}" == "FAIL" ]] && echo "$p | Nutrition"
    [[ "${M_RES[j]}" == "FAIL" ]] && echo "$p | Metadata"
    if [[ "${T_RES[j]}" == "FAIL" ]]; then
      tv="${TYPE_VALUES[j]}"
      [[ -z "$tv" ]] && tv="(empty)"
      echo "$p | Type | $tv"
    fi
    [[ "${U_RES[j]}" == "FAIL" ]] && echo "$p | Multiples"
    [[ "${V_RES[j]}" == "FAIL" ]] && echo "$p | Values"
  done
  echo "=========================================="
fi

[[ $any_failed -eq 0 ]] && exit 0 || exit 1

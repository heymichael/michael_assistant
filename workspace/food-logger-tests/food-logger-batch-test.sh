#!/usr/bin/env bash
# Batch test script for the food logger (OpenClaw agent).
#
# Checks per response:
#   Nutrition:  Calories, Fat, Carbs, Sugar, Fiber, Protein
#   Metadata:   Date, Time, Description, Type, Meal
#   Type value: One of (case-insensitive) Home-Cooked, Restaurant, Delivery, Store-Bought (* ignored)
#   Multiples:  Each macro appears once, OR multiple blocks with a "Total" block whose values equal the sum of preceding blocks
#   Values:     Last occurrence of each macro has a 0 or positive integer
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
  response="$(echo "$response" | sed 's/\*\*//g')"
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

  # ---- Helper: extract first integer from a line (strips units like "g", "kcal") ----
  extract_num() {
    echo "$1" | sed 's/.*:[[:space:]]*//' | grep -oE '[0-9]+' | head -1
  }

  # ---- Multiples (single block OR multiple blocks with a valid Total) ----
  MACRO_NAMES=("Calories" "Fat" "Carbs" "Sugar" "Fiber" "Protein")
  MACRO_PATTERNS=("Calories:" "Fat:" "Carbs:|Carbohydrates:" "Sugar:" "Fiber:" "Protein:")
  has_multiples=0
  missing_macros=()
  macro_counts=()
  for idx in "${!MACRO_NAMES[@]}"; do
    pat="${MACRO_PATTERNS[$idx]}"
    cnt="$(echo "$response" | grep -ciE "$pat" || true)"
    [[ -z "$cnt" ]] && cnt=0
    macro_counts+=("$cnt")
    [[ "$cnt" -eq 0 ]] && missing_macros+=("${MACRO_NAMES[$idx]}")
    [[ "$cnt" -gt 1 ]] && has_multiples=1
  done

  if [[ ${#missing_macros[@]} -gt 0 ]]; then
    u_res="FAIL"
    echo "Multiples:    FAIL (missing macros: ${missing_macros[*]})"
    any_failed=1
  elif [[ $has_multiples -eq 0 ]]; then
    u_res="PASS"
    echo "Multiples:    PASS (each macronutrient appears once)"
  else
    total_ok=1
    sum_ok=1
    sum_errors=()

    if ! echo "$response" | grep -qi "total"; then
      total_ok=0
    fi

    for idx in "${!MACRO_NAMES[@]}"; do
      pat="${MACRO_PATTERNS[$idx]}"
      name="${MACRO_NAMES[$idx]}"
      lines=()
      while IFS= read -r _line; do
        lines+=("$_line")
      done < <(echo "$response" | grep -iE "$pat")
      cnt=${#lines[@]}
      if [[ $cnt -le 1 ]]; then
        continue
      fi
      sum=0
      for ((k=0; k<cnt-1; k++)); do
        val="$(extract_num "${lines[$k]}")"
        [[ -z "$val" ]] && val=0
        sum=$((sum + val))
      done
      last_val="$(extract_num "${lines[$((cnt-1))]}")"
      [[ -z "$last_val" ]] && last_val=0
      if [[ $sum -ne $last_val ]]; then
        sum_ok=0
        sum_errors+=("${name}(expected:${sum} got:${last_val})")
      fi
    done

    if [[ $total_ok -eq 1 && $sum_ok -eq 1 ]]; then
      u_res="PASS"
      echo "Multiples:    PASS (multiple blocks with valid Total)"
    else
      u_res="FAIL"
      reasons=""
      [[ $total_ok -eq 0 ]] && reasons="no Total header"
      if [[ $sum_ok -eq 0 ]]; then
        [[ -n "$reasons" ]] && reasons="$reasons; "
        reasons="${reasons}sum mismatch: ${sum_errors[*]}"
      fi
      echo "Multiples:    FAIL ($reasons)"
      any_failed=1
    fi
  fi
  U_RES+=("$u_res")

  # ---- Values: check last occurrence of each macro has a numeric value ----
  no_num=()
  for macro in "Calories" "Fat" "Sugar" "Fiber" "Protein"; do
    line="$(echo "$response" | grep -i "$macro:" | tail -1)"
    line_lower="$(echo "$line" | tr '[:upper:]' '[:lower:]')"
    macro_lower="$(echo "$macro" | tr '[:upper:]' '[:lower:]')"
    if [[ -z "$line" ]] || ! [[ "$line_lower" =~ ${macro_lower}[^0-9]*[0-9]+ ]]; then
      no_num+=( "$macro" )
    fi
  done
  carbs_line="$(echo "$response" | grep -iE "Carbs:|Carbohydrates:" | tail -1)"
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

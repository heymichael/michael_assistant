#!/usr/bin/env python3
"""
Conversation scenario runner for food-logger multi-turn tests.

Reads `suite.yaml` + scenario YAML files, runs user turns through OpenClaw in a
shared session, and evaluates:
  - hard per-turn checks (contains/regex/field checks)
  - suite/scenario-level behavior checks
  - optional Google Sheet append side-effect checks

Usage:
  python3 runner.py
  python3 runner.py --list
  python3 runner.py --scenario-id simple_input_save
  python3 runner.py --suite /path/to/suite.yaml --target 6822603184
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

try:
    import yaml
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "Missing dependency: PyYAML. Install with `python3 -m pip install pyyaml`."
    ) from exc


DEFAULT_SHEET_ID = "1G_Vupq2nxYe6lIySuItTMIjo8V5HZFLYbTU3O54R1Kw"
DEFAULT_SHEET_RANGE = "Sheet1!A:M"

SAVE_INTENTS = {
    "save",
    "log",
    "yes save",
    "yes log",
    "confirm",
    "yes",
}

RE_FLAGS = re.IGNORECASE | re.MULTILINE


def _load_yaml(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        raise ValueError(f"YAML root must be an object: {path}")
    return data


def _run_cmd(cmd: Sequence[str], timeout: Optional[int] = None) -> str:
    proc = subprocess.run(
        list(cmd),
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0:
        raise RuntimeError(
            f"Command failed ({proc.returncode}): {' '.join(cmd)}\n{out.strip()}"
        )
    return out


def _openclaw_turn(
    target: str, session_id: str, message: str, timeout_seconds: int
) -> str:
    cmd = [
        "openclaw",
        "agent",
        "--to",
        target,
        "--session-id",
        session_id,
        "--message",
        message,
        "--timeout",
        str(timeout_seconds),
    ]
    return _run_cmd(cmd, timeout=timeout_seconds + 10)


def _extract_rows(sheet_payload: Any) -> List[List[Any]]:
    if isinstance(sheet_payload, list):
        return sheet_payload
    if isinstance(sheet_payload, dict):
        vals = sheet_payload.get("values")
        if isinstance(vals, list):
            return vals
    return []


def _sheet_row_count(sheet_id: str, sheet_range: str) -> int:
    cmd = [
        "/opt/homebrew/bin/gog",
        "sheets",
        "get",
        sheet_id,
        sheet_range,
        "--json",
        "--results-only",
    ]
    out = _run_cmd(cmd)
    payload = json.loads(out)
    return len(_extract_rows(payload))


def _is_save_intent(message: str) -> bool:
    msg = " ".join(message.strip().lower().split())
    if msg in SAVE_INTENTS:
        return True
    if re.search(r"^(yes\s+)?save\b", msg):
        return True
    if re.search(r"^(yes\s+)?log\b", msg):
        return True
    if re.search(r"^confirm\b", msg):
        return True
    return False


def _is_decline_save_intent(message: str) -> bool:
    msg = " ".join(message.strip().lower().split())
    patterns = [
        r"\b(?:don't|do not|dont|won't|will not)\s+(?:save|log)\b",
        r"\bno\b.*\b(?:save|log)\b",
        r"\b(?:cancel|skip)\b.*\b(?:save|log)\b",
    ]
    return any(re.search(p, msg) for p in patterns)


def _contains_positive_log_signal(response: str) -> bool:
    # Detect likely "already logged/saved" confirmations while ignoring
    # negative forms like "will not be saved".
    for sentence in re.split(r"[.!?\n]+", response.lower()):
        sentence = sentence.strip()
        if not sentence:
            continue
        if not re.search(r"\b(logged|saved|appended|added)\b", sentence):
            continue
        if re.search(
            r"\b(?:not|don't|do not|dont|won't|will not|cannot|can't|cant)\b.{0,24}\b(logged|saved|appended|added)\b",
            sentence,
        ):
            continue
        return True
    return False


def _last_field_value(response: str, field: str) -> Optional[str]:
    # Supports plain + markdown bullet/bold forms, e.g. "- **Calories:** 320"
    pattern = re.compile(
        rf"^\s*(?:[-*]\s*)?(?:\*\*)?{re.escape(field)}(?:\*\*)?\s*:\s*([^\n\r]+)$",
        RE_FLAGS,
    )
    matches = pattern.findall(response)
    return matches[-1].strip() if matches else None


def _has_numeric(value: str) -> bool:
    return bool(re.search(r"-?\d+(?:\.\d+)?", value))


def _normalize_space(value: str) -> str:
    return " ".join(value.strip().split())


def _run_turn_checks(turn: Dict[str, Any], response: str) -> List[str]:
    errors: List[str] = []
    checks = turn.get("checks", {}) or {}
    if not isinstance(checks, dict):
        return ["checks must be a mapping."]

    for needle in checks.get("must_contain", []) or []:
        if needle not in response:
            errors.append(f'must_contain failed: "{needle}" not found')

    for needle in checks.get("must_not_contain", []) or []:
        if needle in response:
            errors.append(f'must_not_contain failed: "{needle}" was found')

    for pat in checks.get("must_match_regex", []) or []:
        if not re.search(pat, response, RE_FLAGS):
            errors.append(f"must_match_regex failed: /{pat}/ not found")

    for pat in checks.get("must_not_match_regex", []) or []:
        if re.search(pat, response, RE_FLAGS):
            errors.append(f"must_not_match_regex failed: /{pat}/ matched")

    for field in checks.get("field_is_numeric", []) or []:
        val = _last_field_value(response, field)
        if val is None:
            errors.append(f'field_is_numeric failed: "{field}" field missing')
            continue
        if not _has_numeric(val):
            errors.append(f'field_is_numeric failed: "{field}" has non-numeric value "{val}"')

    field_equals = checks.get("field_equals")
    if isinstance(field_equals, dict):
        items = [{"field": k, "value": v} for k, v in field_equals.items()]
    else:
        items = field_equals or []
    for item in items:
        if not isinstance(item, dict):
            errors.append("field_equals entry must be an object with field/value")
            continue
        field = item.get("field")
        expected = item.get("value")
        if not isinstance(field, str):
            errors.append("field_equals missing string `field`")
            continue
        if expected is None:
            errors.append(f'field_equals missing `value` for field "{field}"')
            continue
        actual = _last_field_value(response, field)
        if actual is None:
            errors.append(f'field_equals failed: "{field}" field missing')
            continue
        actual_norm = _normalize_space(actual)
        expected_norm = _normalize_space(str(expected))
        if expected_norm not in actual_norm:
            errors.append(
                f'field_equals failed for "{field}": expected contains "{expected_norm}", got "{actual_norm}"'
            )

    return errors


def _run_default_expectations(
    expectations: Dict[str, Any], user_message: str, response: str
) -> List[str]:
    errors: List[str] = []
    is_save_turn = _is_save_intent(user_message)
    is_decline_turn = _is_decline_save_intent(user_message)

    if expectations.get("require_review_fields_each_turn") and not is_save_turn and not is_decline_turn:
        required = [
            "Date",
            "Time",
            "Meal",
            "Type",
            "Description",
            "Calories",
            "Fat",
            "Carbs",
            "Sugar",
            "Fiber",
            "Protein",
        ]
        for field in required:
            if _last_field_value(response, field) is None:
                errors.append(f'require_review_fields_each_turn failed: "{field}" missing')

    if expectations.get("require_numeric_macros_each_turn") and not is_save_turn and not is_decline_turn:
        for field in ["Calories", "Fat", "Carbs", "Sugar", "Fiber", "Protein"]:
            val = _last_field_value(response, field)
            if val is None:
                errors.append(f'require_numeric_macros_each_turn failed: "{field}" missing')
                continue
            if not _has_numeric(val):
                errors.append(
                    f'require_numeric_macros_each_turn failed: "{field}" not numeric ("{val}")'
                )

    return errors


def _print_header(msg: str) -> None:
    print(f"\n=== {msg} ===")


def _scenario_result_template(sid: str) -> Dict[str, Any]:
    return {
        "scenario_id": sid,
        "passed": True,
        "errors": [],
        "turn_count": 0,
        "duration_seconds": 0.0,
        "session_id": None,
        "transcript": [],
    }


def _run_scenario(
    scenario: Dict[str, Any],
    defaults: Dict[str, Any],
    target_override: Optional[str],
    show_turns: bool,
) -> Dict[str, Any]:
    scenario_id = str(scenario.get("id", "unknown"))
    result = _scenario_result_template(scenario_id)
    started = time.time()

    cfg = dict(defaults)
    cfg.update(scenario.get("config") or {})

    target = str(target_override or cfg.get("target", "6822603184"))
    timeout_seconds = int(cfg.get("timeout_seconds", 120))
    poll_attempts = int(cfg.get("poll_attempts", 10))
    poll_interval_seconds = int(cfg.get("poll_interval_seconds", 2))

    pre = scenario.get("preconditions") or {}
    exp = scenario.get("expectations") or {}
    turns = scenario.get("turns") or []
    if not isinstance(turns, list) or not turns:
        result["passed"] = False
        result["errors"].append("Scenario has no turns.")
        result["duration_seconds"] = round(time.time() - started, 3)
        return result

    expect_sheet_access = bool(pre.get("expect_sheet_access", False))
    expected_append_count = int(exp.get("expected_append_count", 0))
    expect_append_on_save = bool(exp.get("expect_sheet_append_on_save", False))
    if expect_append_on_save and expected_append_count == 0:
        expected_append_count = 1

    sheet_before = None
    if expect_sheet_access:
        try:
            sheet_before = _sheet_row_count(DEFAULT_SHEET_ID, DEFAULT_SHEET_RANGE)
        except Exception as exc:  # pragma: no cover
            result["passed"] = False
            result["errors"].append(f"Failed pre-scenario sheet read: {exc}")
            result["duration_seconds"] = round(time.time() - started, 3)
            return result

    safe_id = re.sub(r"[^a-z0-9\-]+", "-", scenario_id.lower())
    session_id = f"foodlog-conv-{safe_id}-{int(time.time())}-{random.randint(1000,9999)}"
    result["session_id"] = session_id

    assistant_responses: List[str] = []
    save_turn_indexes: List[int] = []

    for idx, turn in enumerate(turns, start=1):
        role = str(turn.get("role", "user")).lower()
        if role != "user":
            result["passed"] = False
            result["errors"].append(f"Turn {idx}: only role=user is supported (got: {role}).")
            continue

        message = str(turn.get("message", ""))
        if not message.strip():
            result["passed"] = False
            result["errors"].append(f"Turn {idx}: empty message.")
            continue

        if _is_save_intent(message):
            save_turn_indexes.append(idx - 1)  # 0-based response index

        try:
            response = _openclaw_turn(target, session_id, message, timeout_seconds)
        except Exception as exc:
            result["passed"] = False
            result["errors"].append(f"Turn {idx}: openclaw command failed: {exc}")
            break

        assistant_responses.append(response)

        turn_errors = []
        turn_errors.extend(_run_turn_checks(turn, response))
        turn_errors.extend(_run_default_expectations(exp, message, response))
        if turn_errors:
            result["passed"] = False
            for err in turn_errors:
                result["errors"].append(f"Turn {idx}: {err}")

        turn_record = {
            "turn_index": idx,
            "role": role,
            "message": message,
            "is_save_turn": _is_save_intent(message),
            "is_decline_turn": _is_decline_save_intent(message),
            "response": response,
            "check_errors": turn_errors,
            "passed": len(turn_errors) == 0,
        }
        result["transcript"].append(turn_record)

        if show_turns:
            _print_header(f"{scenario_id} | Turn {idx}")
            print(f"User: {message}")
            print("\nAssistant:")
            print(response.rstrip())

    # Scenario-level checks across turns.
    if exp.get("forbid_logged_before_save") and assistant_responses:
        stop_at = save_turn_indexes[0] if save_turn_indexes else len(assistant_responses)
        for idx, resp in enumerate(assistant_responses[:stop_at], start=1):
            if _contains_positive_log_signal(resp):
                result["passed"] = False
                result["errors"].append(
                    f"Turn {idx}: forbid_logged_before_save failed (found logged/saved signal)."
                )

    if exp.get("require_confirmation_gate") and save_turn_indexes:
        first_save_resp_idx = save_turn_indexes[0]
        if first_save_resp_idx == 0:
            result["passed"] = False
            result["errors"].append(
                "require_confirmation_gate failed: save intent sent before any prior assistant review."
            )
        else:
            prev_resp = assistant_responses[first_save_resp_idx - 1]
            if not re.search(
                r"(Should I save this to your Food Log\?|Would you like to log this(?: [^?]+)?\?|Would you like to modify anything\?|Would you like to save this(?: [^?]+)?\?)",
                prev_resp,
                RE_FLAGS,
            ):
                result["passed"] = False
                result["errors"].append(
                    "require_confirmation_gate failed: no explicit review/save prompt before save intent."
                )

    # Sheet side-effect checks.
    if expect_sheet_access and sheet_before is not None:
        sheet_after = sheet_before
        if expected_append_count > 0:
            for _ in range(poll_attempts):
                time.sleep(poll_interval_seconds)
                sheet_after = _sheet_row_count(DEFAULT_SHEET_ID, DEFAULT_SHEET_RANGE)
                if sheet_after - sheet_before >= expected_append_count:
                    break
        else:
            # For no-append scenarios, still allow async effects to settle briefly.
            for _ in range(min(3, poll_attempts)):
                time.sleep(poll_interval_seconds)
                sheet_after = _sheet_row_count(DEFAULT_SHEET_ID, DEFAULT_SHEET_RANGE)

        delta = sheet_after - sheet_before
        if delta != expected_append_count:
            result["passed"] = False
            result["errors"].append(
                f"Sheet append mismatch: expected {expected_append_count}, observed {delta}."
            )

    result["turn_count"] = len(turns)
    result["duration_seconds"] = round(time.time() - started, 3)
    return result


def _parse_args() -> argparse.Namespace:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Run food logger conversation scenarios.")
    parser.add_argument(
        "--suite",
        default=str(here / "suite.yaml"),
        help="Path to suite YAML (default: conversation-tests/suite.yaml).",
    )
    parser.add_argument(
        "--scenario-id",
        action="append",
        default=[],
        help="Scenario id to run (repeatable). If omitted, runs all enabled scenarios.",
    )
    parser.add_argument(
        "--target",
        default=None,
        help="Override target phone/session routing id for openclaw agent calls.",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List scenarios and exit.",
    )
    parser.add_argument(
        "--json-report",
        default=None,
        help="Optional path to write JSON results.",
    )
    parser.add_argument(
        "--show-turns",
        action="store_true",
        help="Print each user/assistant turn during execution.",
    )
    parser.add_argument(
        "--transcript-dir",
        default=None,
        help="Optional directory to write one transcript JSON file per scenario.",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    suite_path = Path(args.suite).resolve()
    if not suite_path.exists():
        print(f"Suite file not found: {suite_path}")
        return 2

    suite = _load_yaml(suite_path)
    defaults = suite.get("defaults") or {}
    scenario_refs = suite.get("scenarios") or []
    if not isinstance(scenario_refs, list) or not scenario_refs:
        print("No scenarios listed in suite.")
        return 2

    scenarios: List[Tuple[Path, Dict[str, Any]]] = []
    for ref in scenario_refs:
        path = (suite_path.parent / str(ref)).resolve()
        if not path.exists():
            print(f"Scenario file missing: {path}")
            return 2
        data = _load_yaml(path)
        scenarios.append((path, data))

    if args.list:
        _print_header("Available scenarios")
        for path, s in scenarios:
            sid = s.get("id", path.stem)
            enabled = bool(s.get("enabled", True))
            desc = s.get("description", "")
            print(f"- {sid} | enabled={enabled} | {desc}")
        return 0

    filter_ids = set(args.scenario_id or [])
    run_list: List[Tuple[Path, Dict[str, Any]]] = []
    for path, s in scenarios:
        sid = str(s.get("id", path.stem))
        if filter_ids and sid not in filter_ids:
            continue
        if not bool(s.get("enabled", True)):
            continue
        run_list.append((path, s))

    if not run_list:
        print("No scenarios selected.")
        return 2

    _print_header("Conversation test run")
    print(f"Suite: {suite.get('suite_id', suite_path.name)}")
    print(f"Scenarios: {len(run_list)}")
    if args.target:
        print(f"Target override: {args.target}")

    results: List[Dict[str, Any]] = []
    transcript_dir_path: Optional[Path] = None
    if args.transcript_dir:
        transcript_dir_path = Path(args.transcript_dir).resolve()
        transcript_dir_path.mkdir(parents=True, exist_ok=True)

    for scenario_idx, (_, scenario) in enumerate(run_list, start=1):
        sid = str(scenario.get("id", "unknown"))
        print(f"\n--- Running: {sid} ---")
        result = _run_scenario(scenario, defaults, args.target, show_turns=args.show_turns)
        results.append(result)
        if result["passed"]:
            print(f"PASS {sid} ({result['turn_count']} turns, {result['duration_seconds']}s)")
        else:
            print(f"FAIL {sid} ({result['turn_count']} turns, {result['duration_seconds']}s)")
            for err in result["errors"]:
                print(f"  - {err}")

        if transcript_dir_path is not None:
            safe_sid = re.sub(r"[^a-zA-Z0-9._-]+", "-", sid)
            out_file = transcript_dir_path / f"{scenario_idx:02d}-{safe_sid}.json"
            with out_file.open("w", encoding="utf-8") as f:
                json.dump(
                    {
                        "scenario_id": sid,
                        "session_id": result.get("session_id"),
                        "passed": result["passed"],
                        "errors": result["errors"],
                        "turn_count": result["turn_count"],
                        "duration_seconds": result["duration_seconds"],
                        "transcript": result.get("transcript", []),
                    },
                    f,
                    indent=2,
                )
            print(f"Transcript written: {out_file}")

    passed = sum(1 for r in results if r["passed"])
    failed = len(results) - passed

    _print_header("Summary")
    print(f"Passed: {passed}")
    print(f"Failed: {failed}")
    print(f"Total:  {len(results)}")

    if args.json_report:
        report_path = Path(args.json_report).resolve()
        report_path.parent.mkdir(parents=True, exist_ok=True)
        with report_path.open("w", encoding="utf-8") as f:
            json.dump(
                {
                    "suite_id": suite.get("suite_id", suite_path.name),
                    "results": results,
                    "passed": passed,
                    "failed": failed,
                    "total": len(results),
                },
                f,
                indent=2,
            )
        print(f"Report written to: {report_path}")

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

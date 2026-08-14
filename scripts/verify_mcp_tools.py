#!/usr/bin/env python3
"""Validate the packaged helper against deterministic, isolated fixture semantics."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


TOOL_NAMES = {
    "search", "recent_activity", "ambient_timeline", "ambient_app_usage", "get_context",
    "get_journal", "get_dictation", "get_meeting", "get_memo", "get_stats", "get_config",
}
DICTATION_ID = "10000000-0000-0000-0000-000000000001"
MEETING_ID = "20000000-0000-0000-0000-000000000002"
MEMO_ID = "30000000-0000-0000-0000-000000000003"
FORBIDDEN_KEYS = {
    "audioRelativePath", "audioTracks", "relativePath", "recoverySourceID", "webhookDeliveries",
    "payloadBody", "rawText", "token", "webhookSecret",
}


class VerificationError(Exception):
    pass


def require(condition, assertion):
    if not condition:
        raise VerificationError(assertion)


def request(identifier, method, params):
    return {"jsonrpc": "2.0", "id": identifier, "method": method, "params": params}


def run_helper(helper, home, requests):
    environment = os.environ.copy()
    environment["HOME"] = str(home)
    environment["CFFIXED_USER_HOME"] = str(home)
    payload = "".join(json.dumps(item, separators=(",", ":")) + "\n" for item in requests)
    process = subprocess.Popen(
        [str(helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, env=environment,
    )
    try:
        stdout, stderr = process.communicate(payload, timeout=20)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        raise VerificationError("helper-timeout")
    require(process.returncode == 0, "helper-exit")
    require(len(stdout) <= 2_000_000 and len(stderr) <= 200_000, "helper-output-size")
    try:
        responses = [json.loads(line) for line in stdout.splitlines() if line.strip()]
    except json.JSONDecodeError as error:
        raise VerificationError("protocol-json") from error
    indexed = {response.get("id"): response for response in responses}
    require(len(indexed) == len(requests), "protocol-response-count")
    require(set(indexed) == {item["id"] for item in requests}, "protocol-response-ids")
    return indexed, stdout + stderr


def result(responses, identifier, assertion):
    response = responses[identifier]
    require("error" not in response and "result" in response, assertion)
    return response["result"]


def content_json(responses, identifier, assertion):
    body = result(responses, identifier, assertion)
    content = body.get("content") if isinstance(body, dict) else None
    require(isinstance(content, list) and len(content) == 1, assertion)
    item = content[0]
    require(item.get("type") == "text" and isinstance(item.get("text"), str), assertion)
    try:
        return json.loads(item["text"])
    except json.JSONDecodeError as error:
        raise VerificationError(assertion) from error


def reject_private(value):
    if isinstance(value, dict):
        require(not (set(value) & FORBIDDEN_KEYS), "privacy-key")
        for nested in value.values():
            reject_private(nested)
    elif isinstance(value, list):
        for nested in value:
            reject_private(nested)


def verify_semantics(responses):
    initialize = result(responses, 1, "initialize")
    require(initialize.get("protocolVersion") == "2025-03-26", "initialize-version")
    tools = result(responses, 2, "tools-list").get("tools", [])
    require({tool.get("name") for tool in tools} == TOOL_NAMES, "tools-list-exact")

    search = content_json(responses, 10, "search")
    require(len(search) == 1 and search[0]["record"]["id"] == DICTATION_ID, "search-record")
    require("Alpha verification phrase" in search[0]["snippet"], "search-snippet")

    recent = content_json(responses, 11, "recent-activity")
    require([record["id"] for record in recent] == [MEMO_ID, MEETING_ID, DICTATION_ID], "recent-order")
    meeting_only = content_json(responses, 12, "recent-meeting-filter")
    require([record["id"] for record in meeting_only] == [MEETING_ID], "recent-meeting-filter")

    timeline = content_json(responses, 13, "ambient-timeline")
    require(timeline["enabled"] is True, "ambient-timeline-enabled")
    require(any(event.get("applicationName") == "Editor" for event in timeline["value"]), "ambient-timeline-editor")
    timeline_text = json.dumps(timeline)
    require("Alpha verification phrase" not in timeline_text, "ambient-timeline-transcript")

    usage = content_json(responses, 14, "ambient-app-usage")
    usage_by_name = {item["applicationName"]: item for item in usage["value"]}
    require({"Browser", "Editor"} <= set(usage_by_name), "ambient-app-usage-names")
    require(all(item["totalDuration"] > 0 and item["visitCount"] > 0 for item in usage_by_name.values()), "ambient-app-usage-aggregates")

    context = content_json(responses, 15, "get-context")
    require(context["enabled"] is True and context["value"]["applicationName"] == "Browser", "get-context-browser")

    journal = content_json(responses, 16, "get-journal")
    require(journal["enabled"] is True and len(journal["value"]) == 1, "get-journal-enabled")
    entry = journal["value"][0]
    require(entry["activity"]["trackedDuration"] > 0, "get-journal-duration")
    require((entry["voiceRecordCount"], entry["dictationCount"], entry["meetingCount"], entry["memoCount"]) == (3, 1, 1, 1), "get-journal-counts")
    require(entry["meetingDecisions"][0]["text"] == "ship the isolated verifier", "get-journal-decision")
    require(entry["meetingActionItems"][0]["text"] == "inspect the packaged helper", "get-journal-action")
    require(entry["memoActionItems"] == ["Inspect the packaged helper"], "get-journal-memo-action")

    dictation = content_json(responses, 17, "get-dictation")
    require(dictation["id"] == DICTATION_ID and dictation["text"] == "Alpha verification phrase for search", "get-dictation-content")
    meeting = content_json(responses, 18, "get-meeting")
    require(meeting["id"] == MEETING_ID and len(meeting["segments"]) == 2, "get-meeting-segments")
    require(meeting["notes"] == "Decision evidence: ship the isolated verifier", "get-meeting-notes")
    require(len(meeting["meetingIntelligence"]["decisions"]) == 1 and len(meeting["meetingIntelligence"]["actionItems"]) == 1, "get-meeting-insights")
    memo = content_json(responses, 19, "get-memo")
    require(memo["id"] == MEMO_ID and memo["memoIntelligence"]["highlights"] == ["Remember to inspect the packaged helper."], "get-memo-highlight")
    require(memo["memoIntelligence"]["actionItems"] == ["Inspect the packaged helper"], "get-memo-action")

    stats = content_json(responses, 20, "get-stats")
    require((stats["totalRecords"], stats["dictations"], stats["meetings"], stats["memos"]) == (3, 1, 1, 1), "get-stats-counts")
    require(stats["totalDuration"] > 0 and stats["totalWords"] > 0, "get-stats-aggregates")
    config = content_json(responses, 21, "get-config")
    require(config["model"] == "parakeet" and config["languageCode"] == "en", "get-config-model")
    require((config["dictionaryTermCount"], config["appStyleCount"]) == (3, 2), "get-config-counts")
    require(config["localAPIEnabled"] is False and config["webhookConfigured"] is False, "get-config-local")

    for identifier in range(10, 22):
        reject_private(content_json(responses, identifier, "privacy-content"))


def verify_invalid_parameters(responses):
    for identifier in range(30, 35):
        response = responses[identifier]
        require("result" not in response and response.get("error", {}).get("code") == -32602, "invalid-parameters")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--home", required=True, type=Path)
    args = parser.parse_args()
    helper = args.helper.resolve()
    home = args.home.resolve()
    require(helper.is_file() and os.access(helper, os.X_OK), "helper-path")
    require(home.is_dir() and home != Path.home().resolve(), "fixture-home")

    requests = [
        request(1, "initialize", {}),
        request(2, "tools/list", {}),
        request(10, "tools/call", {"name": "search", "arguments": {"query": "Alpha verification phrase"}}),
        request(11, "tools/call", {"name": "recent_activity", "arguments": {}}),
        request(12, "tools/call", {"name": "recent_activity", "arguments": {"kind": "meeting"}}),
        request(13, "tools/call", {"name": "ambient_timeline", "arguments": {}}),
        request(14, "tools/call", {"name": "ambient_app_usage", "arguments": {}}),
        request(15, "tools/call", {"name": "get_context", "arguments": {}}),
        request(16, "tools/call", {"name": "get_journal", "arguments": {}}),
        request(17, "tools/call", {"name": "get_dictation", "arguments": {"id": DICTATION_ID}}),
        request(18, "tools/call", {"name": "get_meeting", "arguments": {"id": MEETING_ID}}),
        request(19, "tools/call", {"name": "get_memo", "arguments": {"id": MEMO_ID}}),
        request(20, "tools/call", {"name": "get_stats", "arguments": {}}),
        request(21, "tools/call", {"name": "get_config", "arguments": {}}),
        request(30, "tools/call", {"name": "search", "arguments": {"query": "Alpha", "kind": "invalid"}}),
        request(31, "tools/call", {"name": "recent_activity", "arguments": {"since": "not-a-date"}}),
        request(32, "tools/call", {"name": "get_dictation", "arguments": {"id": "not-a-uuid"}}),
        request(33, "tools/call", {"name": "recent_activity", "arguments": {"limit": 0}}),
        request(34, "tools/call", {"name": "recent_activity", "arguments": {"limit": 201}}),
    ]
    responses, transcript = run_helper(helper, home, requests)
    blocked_strings = {str(home), str(Path(__file__).resolve().parents[1]), str(Path.home().resolve())}
    require(not any(value and value in transcript for value in blocked_strings), "privacy-path")
    require(re.search(r"api\.token", transcript, flags=re.IGNORECASE) is None, "privacy-token")
    verify_semantics(responses)
    verify_invalid_parameters(responses)
    print("MCP semantic verification passed")


if __name__ == "__main__":
    try:
        main()
    except VerificationError as error:
        print(f"MCP semantic verification failed: {error}", file=sys.stderr)
        sys.exit(1)

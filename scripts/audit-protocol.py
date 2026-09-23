#!/usr/bin/env python3
"""Inspect locally generated schemas. No requests to a model or credentials."""
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
required_usage = {
    "inputTokens", "cachedInputTokens", "cacheWriteInputTokens", "outputTokens",
    "reasoningOutputTokens", "totalTokens",
}
for variant in (root, root / "experimental"):
    turn_path = variant / "v2/TurnStartParams.json"
    turn = json.loads(turn_path.read_text())
    properties = turn["properties"]
    assert {"input", "threadId"} <= set(turn["required"])
    usage = json.loads((variant / "v2/ThreadTokenUsageUpdatedNotification.json").read_text())
    assert required_usage <= set(usage["definitions"]["TokenUsageBreakdown"]["properties"])
    assert "modelContextWindow" in usage["definitions"]["ThreadTokenUsage"]["properties"]
    assert "readOnly" in json.dumps(turn["definitions"]["SandboxPolicy"])
    print(f"{variant.name}: TurnStartParams SHA256 {hashlib.sha256(turn_path.read_bytes()).hexdigest()}")
    print("turn/start properties:", ", ".join(sorted(properties)))
    print("Tool-disable fields present:", sorted(set(properties) & {
        "tools", "toolChoice", "tool_choice", "allowedTools", "allowed_tools", "disableTools",
    }))
    print("Sandbox override:", properties["sandboxPolicy"]["description"])
    print("Effort override:", properties["effort"]["description"])
    if "environments" in properties:
        print("Environment override:", properties["environments"]["description"])
    response = json.loads((variant / "v2/ThreadResumeResponse.json").read_text())
    print("Disabled plugins:", response["properties"]["disabledPluginIds"]["description"])
    print("Usage fields verified. Automatic heartbeat safety gate remains CLOSED.\n")

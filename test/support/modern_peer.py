"""An independent modern stdio peer; any initialized-session traffic fails."""
import json
import sys

listening = None
calls = 0
cancelled = False

def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)

def notify(method, identifier, extra=None):
    params = {"_meta": {"io.modelcontextprotocol/subscriptionId": identifier}}
    params.update(extra or {})
    emit({"jsonrpc": "2.0", "method": method, "params": params})

for raw in sys.stdin:
    envelope = json.loads(raw)
    method = envelope["method"]
    params = envelope.get("params", {})
    if method == "notifications/cancelled":
        assert params["requestId"] == listening
        cancelled = True
        continue
    assert method not in ("initialize", "ping", "notifications/initialized")
    meta = params["_meta"]
    assert meta["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
    assert meta["io.modelcontextprotocol/clientCapabilities"] == {}
    identifier = envelope["id"]
    if method == "subscriptions/listen":
        listening = identifier
        assert params["notifications"] == {"toolsListChanged": True}
        notify("notifications/subscriptions/acknowledged", identifier,
               {"notifications": {"toolsListChanged": True}})
    elif method == "tools/call":
        calls += 1
        assert params["name"] == "number"
        if calls == 1:
            assert params["arguments"] == {"n": 17}
            notify("notifications/tools/list_changed", listening)
            result = {"resultType": "input_required", "requestState": "native-opaque-state"}
        elif calls == 2:
            assert params["arguments"] == {"n": 17}
            assert params["requestState"] == "native-opaque-state"
            assert params["inputResponses"] == {}
            result = {"resultType": "complete", "content": [], "structuredContent": 17}
        else:
            assert calls == 3 and cancelled
            assert params["arguments"] == {"n": 23}
            result = {"resultType": "complete", "content": [], "structuredContent": 23}
        emit({"jsonrpc": "2.0", "id": identifier, "result": result})
    else:
        raise AssertionError(method)

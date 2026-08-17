#!/usr/bin/env python3
"""Security and lifecycle invariants spanning QML and the bridge contract."""

import json
import os
import re
import sys


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVICE_PATH = os.path.join(ROOT, "Service.qml")
CREDENTIALS_PATH = os.path.join(ROOT, "CredentialManager.qml")
BRIDGE_PATH = os.path.join(ROOT, "bin", "hass-bridge")
MANIFEST_PATH = os.path.join(ROOT, "manifest.json")

service = open(SERVICE_PATH, encoding="utf-8").read()
credentials = open(CREDENTIALS_PATH, encoding="utf-8").read()
bridge = open(BRIDGE_PATH, encoding="utf-8").read()
failures = []


def check(name, condition):
    if condition:
        print("  ok   %s" % name)
    else:
        print("  FAIL %s" % name)
        failures.append(name)


def function_block(name):
    match = re.search(r"\bfunction\s+" + re.escape(name) + r"\s*\([^)]*\)\s*\{",
                      service)
    if not match:
        return ""
    start = match.end() - 1
    depth = 0
    for index in range(start, len(service)):
        if service[index] == "{":
            depth += 1
        elif service[index] == "}":
            depth -= 1
            if depth == 0:
                return service[start:index + 1]
    return ""


def main():
    print("service: credential and connection lifecycle invariants")
    current_config = function_block("currentConfig")
    check("config serialization never contains a token",
          "token" not in current_config.lower())
    check("keyring entries are scoped by normalized origin",
          credentials.count('"service", "hass", "origin", root.') >= 3)
    check("the legacy unscoped token is lookup-only",
          credentials.count('"account", "token"') == 1
          and "legacyProcess" in credentials)

    process_start = credentials.find("property Process storeProcess")
    started = credentials.find("onStarted:", process_start)
    write = credentials.find("storeProcess.write", process_start)
    exited = credentials.find("onExited:", process_start)
    check("token is written only after secret-tool starts",
          process_start >= 0 and process_start < started < write < exited)
    check("reusing the store process restores stdin before launch",
          "storeProcess.stdinEnabled = true" in credentials)
    check("token draft is cleared on terminal paths",
          credentials.count('root.writeToken = ""') >= 2)
    check("keyring readers don't retain collector copies of tokens",
          "StdioCollector" not in credentials
          and 'root.lookupToken = ""' in credentials
          and "legacyTokenSeen" in credentials)
    check("keyring process launch has a timeout",
          "writeStartTimeout" in credentials
          and "clearStartTimeout" in credentials
          and "lookupStartTimeout" in credentials
          and "legacyStartTimeout" in credentials)
    check("credential processes live outside the service",
          "CredentialManager" in service and "secret-tool" not in service)

    push_config = function_block("pushConfig")
    handle_event = function_block("handleEvent")
    check("config commands carry a connection generation",
          "generation: root.connectionGeneration" in push_config)
    check("the process controller versions every NDJSON command",
          "payload.protocolVersion = root.protocolVersion"
          in open(os.path.join(ROOT, "BridgeController.qml"), encoding="utf-8").read()
          and "PROTOCOL_VERSION = 1" in bridge)
    check("events from old generations are rejected",
          "acceptsGeneration" in handle_event)
    reconcile = function_block("reconcileConnection")
    check("connection identity comes from Connection.js, not a local copy",
          "Connection.signature(" in reconcile
          and "root.baseUrl.trim()" not in reconcile)

    check("cancel uses explicit disconnect rather than blank credentials",
          'op: "disconnect"' in function_block("disconnectBridge"))
    check("device state is cleared on connection replacement",
          "forgetDevices" in function_block("cancelConnection")
          and "forgetDevices" in function_block("removeConnection"))

    panel = open(os.path.join(ROOT, "Panel.qml"), encoding="utf-8").read()
    settings = open(os.path.join(ROOT, "Settings.qml"), encoding="utf-8").read()
    check("IPC never prints a raw attribute map",
          "JSON.stringify(entity.attributes)" not in panel
          and "Model.redactAttributes" in panel
          and "access_token" in open(os.path.join(ROOT, "Model.js"),
                                     encoding="utf-8").read())
    check("plaintext connection URLs show an explicit token warning",
          'indexOf("http://")' in settings
          and 'indexOf("ws://")' in settings
          and "without transport encryption" in settings)
    check("a refused keyring read is retried rather than dropped",
          "credentialRetry" in function_block("pushCredentials")
          and "property Timer credentialRetry" in service)

    check("domain actions validate entity capabilities",
          service.count("root.capabilities(entityId)") >= 7
          and "Model.capabilitiesFor(entity)" in service)
    check("selected tab persistence is debounced",
          "selectedTabSaveDebounce.restart()" in service)

    check("bridge never accepts the token in argv",
          "access_token" in bridge and '"--token"' not in bridge)
    check("bridge disables environment proxies explicitly",
          "proxy=None" in bridge)
    check("custom WebSocket parser isn't present",
          "class WebSocket:" not in bridge and "def ws_connect(" not in bridge)

    try:
        manifest = json.load(open(MANIFEST_PATH, encoding="utf-8"))
        valid_manifest = (manifest.get("schemaVersion") == 1
                          and manifest.get("id") == "hass"
                          and set(manifest.get("entryPoints", {}))
                          == {"service", "barWidget", "overlay"})
    except (OSError, ValueError):
        valid_manifest = False
    check("manifest has the expected schema and entry points", valid_manifest)

    print()
    if failures:
        print("FAILED: %s" % ", ".join(failures))
        return 1
    print("all service contract checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

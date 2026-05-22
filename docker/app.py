#!/usr/bin/env python3
"""
Okta Agent Web API

POST /api/okta   — {"prompt": "Add Abe Ramo with email x@y.com to TheFlux group"}
                 → {"steps": [...], "summary": "..."}
GET  /api/health — health check
"""

import json
import logging
import os

import anthropic
import requests as okta_http
from flask import Flask, jsonify, request

OKTA_DOMAIN    = os.environ.get("OKTA_DOMAIN", "")
OKTA_API_TOKEN = os.environ.get("OKTA_API_TOKEN", "")
MODEL          = "claude-sonnet-4-6"

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

app    = Flask(__name__)
claude = anthropic.Anthropic()


def _okta_headers():
    return {
        "Authorization": f"SSWS {OKTA_API_TOKEN}",
        "Content-Type":  "application/json",
        "Accept":        "application/json",
    }

def _base():
    return f"https://{OKTA_DOMAIN}/api/v1"

def create_user(first_name, last_name, email, activate=True):
    url = f"{_base()}/users?activate={str(activate).lower()}&provider=false&nextLogin=changePassword"
    payload = {"profile": {"firstName": first_name, "lastName": last_name, "email": email, "login": email}}
    resp = okta_http.post(url, headers=_okta_headers(), json=payload, timeout=15)
    return {"status_code": resp.status_code, "body": resp.json()}

def find_user(email):
    url = f"{_base()}/users/{okta_http.utils.quote(email)}"
    resp = okta_http.get(url, headers=_okta_headers(), timeout=15)
    return {"status_code": resp.status_code, "body": resp.json()}

def find_group(group_name):
    url = f'{_base()}/groups?search=profile.name eq "{group_name}"'
    resp = okta_http.get(url, headers=_okta_headers(), timeout=15)
    body = resp.json()
    if isinstance(body, list) and body:
        return {"status_code": resp.status_code, "body": body[0]}
    return {"status_code": resp.status_code, "body": body, "found": False}

def add_user_to_group(group_id, user_id):
    url = f"{_base()}/groups/{group_id}/users/{user_id}"
    resp = okta_http.put(url, headers=_okta_headers(), timeout=15)
    return {"status_code": resp.status_code, "success": resp.status_code == 204,
            "body": resp.text or "(204 No Content — success)"}


TOOLS = [
    {
        "name": "create_okta_user",
        "description": (
            "Create a new user in Okta. Returns the created user object including their ID. "
            "If you receive HTTP 409 (user already exists), call find_okta_user instead."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "first_name": {"type": "string"},
                "last_name":  {"type": "string"},
                "email":      {"type": "string"},
                "activate":   {"type": "boolean"},
            },
            "required": ["first_name", "last_name", "email"],
        },
    },
    {
        "name": "find_okta_user",
        "description": "Look up an existing Okta user by email/login. Returns user object with ID.",
        "input_schema": {
            "type": "object",
            "properties": {"email": {"type": "string"}},
            "required": ["email"],
        },
    },
    {
        "name": "find_okta_group",
        "description": "Find an Okta group by its display name. Returns group object including group ID.",
        "input_schema": {
            "type": "object",
            "properties": {"group_name": {"type": "string"}},
            "required": ["group_name"],
        },
    },
    {
        "name": "add_user_to_okta_group",
        "description": "Add a user to an Okta group using their IDs. HTTP 204 means success.",
        "input_schema": {
            "type": "object",
            "properties": {
                "group_id": {"type": "string"},
                "user_id":  {"type": "string"},
            },
            "required": ["group_id", "user_id"],
        },
    },
]

SYSTEM = """You are an Okta administrator assistant. When asked to add a user to a group:

1. Create the user with create_okta_user (activate=true).
   If HTTP 409 (already exists), call find_okta_user to get their ID.
2. Find the group with find_okta_group.
3. Add the user to the group with add_user_to_okta_group.

After all steps, write a concise summary of what happened."""


def dispatch(tool_name, tool_input):
    if tool_name == "create_okta_user":
        result = create_user(tool_input["first_name"], tool_input["last_name"],
                             tool_input["email"], tool_input.get("activate", True))
    elif tool_name == "find_okta_user":
        result = find_user(tool_input["email"])
    elif tool_name == "find_okta_group":
        result = find_group(tool_input["group_name"])
    elif tool_name == "add_user_to_okta_group":
        result = add_user_to_group(tool_input["group_id"], tool_input["user_id"])
    else:
        result = {"error": f"Unknown tool: {tool_name}"}
    return json.dumps(result)


def run_agent(prompt):
    messages = [{"role": "user", "content": prompt}]
    steps    = []

    while True:
        response = claude.messages.create(
            model=MODEL,
            max_tokens=1024,
            system=SYSTEM,
            tools=TOOLS,
            messages=messages,
        )
        messages.append({"role": "assistant", "content": response.content})

        if response.stop_reason == "end_turn":
            summary = next((b.text for b in response.content if hasattr(b, "text")), "")
            return steps, summary

        if response.stop_reason == "tool_use":
            tool_results = []
            for block in response.content:
                if block.type == "tool_use":
                    result_str  = dispatch(block.name, block.input)
                    result_data = json.loads(result_str)
                    steps.append({"tool": block.name, "input": block.input, "result": result_data})
                    logger.info(f"tool={block.name} status={result_data.get('status_code')}")
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": result_str,
                    })
            messages.append({"role": "user", "content": tool_results})


@app.route("/api/okta", methods=["POST"])
def okta_endpoint():
    data   = request.get_json() or {}
    prompt = data.get("prompt", "").strip()
    if not prompt:
        return jsonify({"error": "Missing 'prompt' field"}), 400
    if len(prompt) > 600:
        return jsonify({"error": "Prompt too long (max 600 characters)"}), 400
    try:
        steps, summary = run_agent(prompt)
        return jsonify({"steps": steps, "summary": summary})
    except Exception as e:
        logger.error(f"Agent error: {e}")
        return jsonify({"error": str(e)}), 500


@app.route("/api/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "okta_domain": OKTA_DOMAIN})


if __name__ == "__main__":
    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise SystemExit("ANTHROPIC_API_KEY not set")
    app.run(host="127.0.0.1", port=5001, debug=False)

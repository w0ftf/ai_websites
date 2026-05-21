#!/usr/bin/env python3
"""
Okta User Management Agent

Uses Claude to interpret natural-language requests and execute the necessary
Okta API calls (create user → find group → add user to group).

Prerequisites:
  export ANTHROPIC_API_KEY="sk-ant-..."
  export OKTA_API_TOKEN="your-okta-token"
  export OKTA_DOMAIN="integrator-2383045.okta.com"

Usage:
  python3 okta_agent.py "Add Abe Ramo with email wof@theflux.net to TheFlux group"
  python3 okta_agent.py   # interactive prompt
"""

import json
import os
import sys

import anthropic
import requests

# ── Config ────────────────────────────────────────────────────────────────────
OKTA_DOMAIN = os.environ.get("OKTA_DOMAIN", "")
OKTA_API_TOKEN = os.environ.get("OKTA_API_TOKEN", "")
MODEL = "claude-sonnet-4-6"

client = anthropic.Anthropic()


# ── Okta helpers ──────────────────────────────────────────────────────────────
def _headers():
    return {
        "Authorization": f"SSWS {OKTA_API_TOKEN}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }


def _base():
    return f"https://{OKTA_DOMAIN}/api/v1"


def create_user(first_name: str, last_name: str, email: str, activate: bool = True) -> dict:
    url = f"{_base()}/users?activate={str(activate).lower()}&provider=false&nextLogin=changePassword"
    payload = {
        "profile": {
            "firstName": first_name,
            "lastName": last_name,
            "email": email,
            "login": email,
        }
    }
    resp = requests.post(url, headers=_headers(), json=payload, timeout=15)
    return {"status_code": resp.status_code, "body": resp.json()}


def find_user(email: str) -> dict:
    url = f"{_base()}/users/{requests.utils.quote(email)}"
    resp = requests.get(url, headers=_headers(), timeout=15)
    return {"status_code": resp.status_code, "body": resp.json()}


def find_group(group_name: str) -> dict:
    url = f'{_base()}/groups?search=profile.name eq "{group_name}"'
    resp = requests.get(url, headers=_headers(), timeout=15)
    body = resp.json()
    if isinstance(body, list) and body:
        return {"status_code": resp.status_code, "body": body[0]}
    return {"status_code": resp.status_code, "body": body, "found": False}


def add_user_to_group(group_id: str, user_id: str) -> dict:
    url = f"{_base()}/groups/{group_id}/users/{user_id}"
    resp = requests.put(url, headers=_headers(), timeout=15)
    return {
        "status_code": resp.status_code,
        "success": resp.status_code == 204,
        "body": resp.text or "(empty — 204 No Content is expected on success)",
    }


# ── Tool definitions for Claude ───────────────────────────────────────────────
TOOLS = [
    {
        "name": "create_okta_user",
        "description": (
            "Create a new user in Okta. Returns the created user object including their ID. "
            "If the user already exists (HTTP 409), call find_okta_user instead."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "first_name": {"type": "string", "description": "User's first name"},
                "last_name": {"type": "string", "description": "User's last name"},
                "email": {"type": "string", "description": "User's email (also used as login)"},
                "activate": {
                    "type": "boolean",
                    "description": "Activate the account immediately (default true)",
                },
            },
            "required": ["first_name", "last_name", "email"],
        },
    },
    {
        "name": "find_okta_user",
        "description": "Look up an existing Okta user by email/login. Returns user object with ID.",
        "input_schema": {
            "type": "object",
            "properties": {
                "email": {"type": "string", "description": "User's email / Okta login"}
            },
            "required": ["email"],
        },
    },
    {
        "name": "find_okta_group",
        "description": "Find an Okta group by its display name. Returns the group object including group ID.",
        "input_schema": {
            "type": "object",
            "properties": {
                "group_name": {"type": "string", "description": "Exact display name of the group"}
            },
            "required": ["group_name"],
        },
    },
    {
        "name": "add_user_to_okta_group",
        "description": "Add a user to an Okta group using their respective IDs. HTTP 204 means success.",
        "input_schema": {
            "type": "object",
            "properties": {
                "group_id": {"type": "string", "description": "Okta group ID"},
                "user_id": {"type": "string", "description": "Okta user ID"},
            },
            "required": ["group_id", "user_id"],
        },
    },
]


# ── Tool dispatcher ───────────────────────────────────────────────────────────
def dispatch(tool_name: str, tool_input: dict) -> str:
    if tool_name == "create_okta_user":
        result = create_user(
            tool_input["first_name"],
            tool_input["last_name"],
            tool_input["email"],
            tool_input.get("activate", True),
        )
    elif tool_name == "find_okta_user":
        result = find_user(tool_input["email"])
    elif tool_name == "find_okta_group":
        result = find_group(tool_input["group_name"])
    elif tool_name == "add_user_to_okta_group":
        result = add_user_to_group(tool_input["group_id"], tool_input["user_id"])
    else:
        result = {"error": f"Unknown tool: {tool_name}"}
    return json.dumps(result)


# ── Agentic loop ──────────────────────────────────────────────────────────────
SYSTEM = """You are an Okta administrator assistant. When asked to add a user to a group:

1. Create the user with create_okta_user (activate=true).
   - If you get HTTP 409 (user already exists), call find_okta_user to get their ID instead.
2. Call find_okta_group to get the group ID.
3. Call add_user_to_okta_group with both IDs.

After all steps, summarise what happened: whether the user was created or already existed,
whether the group was found, and whether the group membership was set successfully."""


def run_agent(prompt: str) -> None:
    messages = [{"role": "user", "content": prompt}]

    print(f"\nRequest: {prompt}\n")

    while True:
        response = client.messages.create(
            model=MODEL,
            max_tokens=1024,
            system=SYSTEM,
            tools=TOOLS,
            messages=messages,
        )

        messages.append({"role": "assistant", "content": response.content})

        if response.stop_reason == "end_turn":
            for block in response.content:
                if hasattr(block, "text"):
                    print(block.text)
            break

        if response.stop_reason == "tool_use":
            tool_results = []
            for block in response.content:
                if block.type == "tool_use":
                    print(f"[tool] {block.name}({json.dumps(block.input)})")
                    result_str = dispatch(block.name, block.input)
                    print(f"       → {result_str}")
                    tool_results.append(
                        {
                            "type": "tool_result",
                            "tool_use_id": block.id,
                            "content": result_str,
                        }
                    )
            messages.append({"role": "user", "content": tool_results})


# ── Entry point ───────────────────────────────────────────────────────────────
def main() -> None:
    missing = [v for v in ("ANTHROPIC_API_KEY", "OKTA_API_TOKEN", "OKTA_DOMAIN") if not os.environ.get(v)]
    if missing:
        print(f"Error: missing environment variable(s): {', '.join(missing)}")
        print("\nSet them before running:")
        for v in missing:
            print(f"  export {v}=...")
        sys.exit(1)

    if len(sys.argv) > 1:
        prompt = " ".join(sys.argv[1:])
    else:
        print("Okta User Management Agent")
        print('Example: "Add Abe Ramo with email wof@theflux.net to TheFlux group"')
        prompt = input("\nEnter your request: ").strip()
        if not prompt:
            sys.exit(0)

    run_agent(prompt)


if __name__ == "__main__":
    main()

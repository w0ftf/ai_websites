#!/usr/bin/env bash
# ==============================================================================
# setup-okta-agent-site.sh
#
# Deploys a web interface for the Okta User Management Agent on Debian 11+:
#   1. Installs Apache2 + Python3/Flask
#   2. Creates a Flask API that wraps the Claude-powered Okta agent
#   3. Builds an HTML admin UI (natural-language → Okta operations)
#   4. Configures Apache as a reverse proxy to the Flask backend
#   5. Creates a systemd service for the Flask API
#   6. Verifies everything is working
#
# Prerequisites:
#   - Debian 11+ with root/sudo
#   - Environment variables set:
#       ANTHROPIC_API_KEY   — Claude API key
#       OKTA_API_TOKEN      — Okta SSWS API token
#       OKTA_DOMAIN         — e.g. integrator-2383045.okta.com
#
# Usage:
#   export ANTHROPIC_API_KEY="sk-ant-..."
#   export OKTA_API_TOKEN="your-token"
#   export OKTA_DOMAIN="yourorg.okta.com"
#   chmod +x setup-okta-agent-site.sh
#   sudo -E ./setup-okta-agent-site.sh
# ==============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SITE_NAME="okta-agent-site"
SITE_DIR="/var/www/${SITE_NAME}"
VHOST_CONF="/etc/apache2/sites-available/${SITE_NAME}.conf"
SERVER_NAME="localhost"
API_DIR="/opt/${SITE_NAME}-api"
API_PORT=5001
SERVICE_NAME="${SITE_NAME}-api"

# ── Helper functions ──────────────────────────────────────────────────────────
info()    { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
success() { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
fail()    { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    fail "Run as root: sudo -E ./setup-okta-agent-site.sh"
fi
[[ -z "${ANTHROPIC_API_KEY:-}" ]] && fail "ANTHROPIC_API_KEY not set."
[[ -z "${OKTA_API_TOKEN:-}" ]]    && fail "OKTA_API_TOKEN not set."
[[ -z "${OKTA_DOMAIN:-}" ]]       && fail "OKTA_DOMAIN not set (e.g. yourorg.okta.com)."

info "OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
info "Okta domain: ${OKTA_DOMAIN}"
info "API key: ${ANTHROPIC_API_KEY:0:12}..."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: Install system packages
# ══════════════════════════════════════════════════════════════════════════════
info "Updating package lists..."
apt-get update -qq

info "Installing apache2, python3, pip, venv..."
apt-get install -y -qq apache2 curl python3 python3-pip python3-venv > /dev/null 2>&1
success "System packages installed."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Enable Apache modules
# ══════════════════════════════════════════════════════════════════════════════
info "Enabling Apache modules..."
a2enmod rewrite    > /dev/null 2>&1 || true
a2enmod headers    > /dev/null 2>&1 || true
a2enmod proxy      > /dev/null 2>&1 || true
a2enmod proxy_http > /dev/null 2>&1 || true
success "Apache modules enabled."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: Create Flask API backend
# ══════════════════════════════════════════════════════════════════════════════
info "Setting up Flask API at ${API_DIR}..."
mkdir -p "${API_DIR}"

python3 -m venv "${API_DIR}/venv"
source "${API_DIR}/venv/bin/activate"
info "Installing Python dependencies (flask, anthropic, requests)..."
pip install --quiet flask anthropic requests
deactivate

cat > "${API_DIR}/app.py" <<'PYEOF'
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


# ── Okta helpers ──────────────────────────────────────────────────────────────
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


# ── Tool definitions ──────────────────────────────────────────────────────────
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
    """Run the agentic loop; return (steps, summary)."""
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


# ── Flask routes ──────────────────────────────────────────────────────────────
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
PYEOF

success "Flask API created."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Create systemd service
# ══════════════════════════════════════════════════════════════════════════════
info "Creating systemd service..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SVCEOF
[Unit]
Description=Okta Agent Web API (Flask)
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=${API_DIR}
Environment="ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"
Environment="OKTA_API_TOKEN=${OKTA_API_TOKEN}"
Environment="OKTA_DOMAIN=${OKTA_DOMAIN}"
ExecStart=${API_DIR}/venv/bin/python ${API_DIR}/app.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" > /dev/null 2>&1
systemctl start  "${SERVICE_NAME}"
success "Service started and enabled on boot."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: Create site directory and HTML frontend
# ══════════════════════════════════════════════════════════════════════════════
info "Creating site directory at ${SITE_DIR}..."
mkdir -p "${SITE_DIR}"

info "Building HTML admin UI..."
cat > "${SITE_DIR}/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Okta User Management Agent</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
    <style>
        *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }

        :root {
            --bg:           #f4f6f9;
            --surface:      #ffffff;
            --surface-alt:  #f8f9fb;
            --border:       #e2e6ed;
            --border-light: #edf0f5;
            --text-black:   #0d1117;
            --text-body:    #374151;
            --text-mid:     #6b7280;
            --text-muted:   #9ca3af;
            --blue:         #2563eb;
            --blue-dark:    #1d4ed8;
            --blue-bg:      #eff6ff;
            --green:        #16a34a;
            --green-bg:     #f0fdf4;
            --amber:        #d97706;
            --amber-bg:     #fffbeb;
            --red:          #dc2626;
            --red-bg:       #fef2f2;
            --purple:       #7c3aed;
            --purple-bg:    #f5f3ff;
            --okta-blue:    #007dc1;
            --font:         'Inter', system-ui, sans-serif;
            --mono:         'JetBrains Mono', monospace;
        }

        body {
            font-family: var(--font);
            background: var(--bg);
            color: var(--text-body);
            min-height: 100vh;
            padding: 2rem 1rem;
        }

        /* ── Layout ── */
        .page { max-width: 780px; margin: 0 auto; }

        /* ── Header ── */
        .header {
            display: flex; align-items: center; gap: 0.75rem;
            margin-bottom: 2rem;
        }
        .header .logo {
            width: 40px; height: 40px; border-radius: 10px;
            background: linear-gradient(135deg, var(--okta-blue), #005fa3);
            display: flex; align-items: center; justify-content: center;
            color: #fff; font-weight: 700; font-size: 1rem; letter-spacing: -0.5px;
            flex-shrink: 0;
        }
        .header h1 { font-size: 1.25rem; font-weight: 700; color: var(--text-black); }
        .header p  { font-size: 0.8rem; color: var(--text-mid); margin-top: 1px; }

        /* ── Input card ── */
        .input-card {
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 14px;
            padding: 1.5rem;
            box-shadow: 0 1px 4px rgba(0,0,0,0.05);
            margin-bottom: 1.25rem;
        }
        .input-card label {
            display: block; font-size: 0.78rem; font-weight: 600;
            color: var(--text-mid); text-transform: uppercase;
            letter-spacing: 0.8px; margin-bottom: 0.5rem;
        }
        .input-row { display: flex; gap: 0.6rem; }
        .input-row textarea {
            flex: 1; padding: 0.75rem 1rem;
            border: 1.5px solid var(--border);
            border-radius: 10px; font-family: var(--font);
            font-size: 0.9rem; color: var(--text-black);
            background: var(--surface-alt);
            outline: none; resize: none; height: 60px;
            line-height: 1.5; transition: border-color 0.2s;
        }
        .input-row textarea:focus { border-color: var(--blue); background: #fff; }
        .input-row textarea::placeholder { color: var(--text-muted); }
        .run-btn {
            padding: 0 1.25rem;
            background: var(--blue);
            color: #fff; border: none; border-radius: 10px;
            font-family: var(--font); font-weight: 600;
            font-size: 0.9rem; cursor: pointer;
            white-space: nowrap; transition: background 0.2s;
            display: flex; align-items: center; gap: 0.4rem;
        }
        .run-btn:hover    { background: var(--blue-dark); }
        .run-btn:disabled { opacity: 0.5; cursor: not-allowed; }

        /* ── Example chips ── */
        .examples { display: flex; flex-wrap: wrap; gap: 0.4rem; margin-top: 0.85rem; }
        .example-chip {
            padding: 0.3rem 0.7rem; border-radius: 999px;
            font-size: 0.74rem; font-weight: 500;
            border: 1px solid var(--border);
            background: var(--surface-alt); color: var(--text-mid);
            cursor: pointer; transition: all 0.15s;
        }
        .example-chip:hover { border-color: var(--blue); color: var(--blue); background: var(--blue-bg); }

        /* ── Result area ── */
        .result-area { display: none; }
        .result-area.show { display: block; }

        /* ── Steps ── */
        .steps-title {
            font-size: 0.72rem; font-weight: 600; color: var(--text-muted);
            text-transform: uppercase; letter-spacing: 1px;
            margin-bottom: 0.6rem;
        }
        .step-card {
            background: var(--surface); border: 1px solid var(--border);
            border-radius: 12px; overflow: hidden; margin-bottom: 0.6rem;
        }
        .step-header {
            display: flex; align-items: center; gap: 0.6rem;
            padding: 0.65rem 1rem;
            background: var(--surface-alt);
            border-bottom: 1px solid var(--border-light);
            cursor: pointer; user-select: none;
        }
        .step-header:hover { background: var(--border-light); }
        .step-icon {
            width: 26px; height: 26px; border-radius: 6px;
            display: flex; align-items: center; justify-content: center;
            font-size: 0.75rem; flex-shrink: 0;
        }
        .step-icon.create { background: var(--blue-bg);   color: var(--blue);   }
        .step-icon.find   { background: var(--purple-bg); color: var(--purple); }
        .step-icon.add    { background: var(--green-bg);  color: var(--green);  }
        .step-icon.warn   { background: var(--amber-bg);  color: var(--amber);  }
        .step-label { font-size: 0.85rem; font-weight: 600; color: var(--text-black); flex: 1; }
        .step-status {
            font-size: 0.72rem; font-weight: 600; padding: 0.2rem 0.5rem;
            border-radius: 999px;
        }
        .step-status.ok  { background: var(--green-bg); color: var(--green); }
        .step-status.err { background: var(--red-bg);   color: var(--red);   }
        .step-status.mid { background: var(--amber-bg); color: var(--amber); }
        .step-toggle { font-size: 0.7rem; color: var(--text-muted); transition: transform 0.2s; }
        .step-toggle.open { transform: rotate(90deg); }

        .step-body { display: none; padding: 0.85rem 1rem; }
        .step-body.open { display: block; }

        .kv-row {
            display: flex; gap: 0.5rem; margin-bottom: 0.3rem;
            font-size: 0.8rem;
        }
        .kv-row .kv-key {
            font-weight: 600; color: var(--text-mid);
            min-width: 90px; flex-shrink: 0;
        }
        .kv-row .kv-val { color: var(--text-body); word-break: break-all; }

        .json-block {
            background: #1e2330; color: #a8b3c8;
            border-radius: 8px; padding: 0.75rem 1rem;
            font-family: var(--mono); font-size: 0.75rem;
            overflow-x: auto; margin-top: 0.5rem; white-space: pre;
        }
        .section-label {
            font-size: 0.7rem; font-weight: 600; color: var(--text-muted);
            text-transform: uppercase; letter-spacing: 0.6px;
            margin: 0.75rem 0 0.35rem;
        }

        /* ── Summary card ── */
        .summary-card {
            background: var(--green-bg);
            border: 1px solid #bbf7d0; border-radius: 12px;
            padding: 1rem 1.2rem; margin-top: 0.75rem;
            display: flex; gap: 0.75rem; align-items: flex-start;
        }
        .summary-card.error-card {
            background: var(--red-bg); border-color: #fecaca;
        }
        .summary-icon { font-size: 1.1rem; flex-shrink: 0; margin-top: 1px; }
        .summary-text { font-size: 0.9rem; line-height: 1.6; color: var(--text-body); }
        .summary-text strong { color: var(--text-black); }

        /* ── Spinner ── */
        .spinner-wrap {
            display: none; align-items: center; gap: 0.75rem;
            padding: 1.25rem; background: var(--surface);
            border: 1px solid var(--border); border-radius: 12px;
            font-size: 0.88rem; color: var(--text-mid);
        }
        .spinner-wrap.show { display: flex; }
        .spinner {
            width: 18px; height: 18px; border-radius: 50%;
            border: 2.5px solid var(--border);
            border-top-color: var(--blue);
            animation: spin 0.8s linear infinite; flex-shrink: 0;
        }
        @keyframes spin { to { transform: rotate(360deg); } }

        /* ── Responsive ── */
        @media (max-width: 600px) {
            body { padding: 1rem 0.75rem; }
            .input-row { flex-direction: column; }
            .run-btn { padding: 0.75rem; justify-content: center; }
        }
    </style>
</head>
<body>
<div class="page">

    <!-- Header -->
    <div class="header">
        <div class="logo">Ok</div>
        <div>
            <h1>Okta User Management Agent</h1>
            <p>Natural language &rarr; Okta API &mdash; powered by Claude</p>
        </div>
    </div>

    <!-- Input -->
    <div class="input-card">
        <label>What would you like to do?</label>
        <div class="input-row">
            <textarea id="prompt"
                placeholder="e.g. Add Abe Ramo with email wof@theflux.net to the TheFlux group"></textarea>
            <button class="run-btn" id="runBtn" onclick="runAgent()">
                &#9654; Run
            </button>
        </div>
        <div class="examples">
            <span class="example-chip"
                  onclick="setPrompt('Add Abe Ramo with email wof@theflux.net to the TheFlux group')">
                Add user to group
            </span>
            <span class="example-chip"
                  onclick="setPrompt('Create user Jane Doe with email jane.doe@example.com and add her to the Engineering group')">
                Create &amp; assign to Engineering
            </span>
            <span class="example-chip"
                  onclick="setPrompt('Add john.smith@example.com to the Admins group')">
                Add existing user to Admins
            </span>
        </div>
    </div>

    <!-- Spinner -->
    <div class="spinner-wrap" id="spinner">
        <div class="spinner"></div>
        <span>Claude is working &mdash; calling Okta APIs&hellip;</span>
    </div>

    <!-- Results -->
    <div class="result-area" id="resultArea">
        <div class="steps-title">Steps taken</div>
        <div id="stepsList"></div>
        <div id="summaryBox"></div>
    </div>

</div>

<script>
    const TOOL_META = {
        create_okta_user:      { label: "Create User",        iconClass: "create", icon: "&#43;" },
        find_okta_user:        { label: "Find User",          iconClass: "find",   icon: "&#128269;" },
        find_okta_group:       { label: "Find Group",         iconClass: "find",   icon: "&#128101;" },
        add_user_to_okta_group:{ label: "Add User to Group",  iconClass: "add",    icon: "&#10003;" },
    };

    function setPrompt(text) {
        document.getElementById("prompt").value = text;
        document.getElementById("prompt").focus();
    }

    function statusClass(code) {
        if (!code) return "mid";
        if (code >= 200 && code < 300) return "ok";
        if (code === 204) return "ok";
        return "err";
    }

    function statusLabel(code) {
        if (!code) return "—";
        return "HTTP " + code;
    }

    function esc(s) {
        const d = document.createElement("div");
        d.textContent = String(s ?? "");
        return d.innerHTML;
    }

    function renderStep(step, idx) {
        const meta   = TOOL_META[step.tool] || { label: step.tool, iconClass: "find", icon: "?" };
        const code   = step.result?.status_code;
        const sClass = statusClass(code);
        const sLabel = statusLabel(code);

        // Flatten top-level input fields as key-value rows
        const inputRows = Object.entries(step.input || {})
            .map(([k, v]) => `<div class="kv-row">
                <span class="kv-key">${esc(k)}</span>
                <span class="kv-val">${esc(typeof v === "object" ? JSON.stringify(v) : v)}</span>
            </div>`).join("");

        const resultJson = JSON.stringify(step.result ?? {}, null, 2);

        return `
        <div class="step-card" id="step-${idx}">
            <div class="step-header" onclick="toggleStep(${idx})">
                <div class="step-icon ${meta.iconClass}">${meta.icon}</div>
                <span class="step-label">${esc(meta.label)}</span>
                <span class="step-status ${sClass}">${sLabel}</span>
                <span class="step-toggle" id="toggle-${idx}">&#9654;</span>
            </div>
            <div class="step-body" id="body-${idx}">
                ${inputRows ? `<div class="section-label">Input</div>${inputRows}` : ""}
                <div class="section-label">Response</div>
                <div class="json-block">${esc(resultJson)}</div>
            </div>
        </div>`;
    }

    function toggleStep(idx) {
        const body   = document.getElementById("body-" + idx);
        const toggle = document.getElementById("toggle-" + idx);
        body.classList.toggle("open");
        toggle.classList.toggle("open");
    }

    async function runAgent() {
        const prompt = document.getElementById("prompt").value.trim();
        if (!prompt) return;

        const btn    = document.getElementById("runBtn");
        const spin   = document.getElementById("spinner");
        const result = document.getElementById("resultArea");

        btn.disabled = true;
        spin.classList.add("show");
        result.classList.remove("show");
        document.getElementById("stepsList").innerHTML  = "";
        document.getElementById("summaryBox").innerHTML = "";

        try {
            const resp = await fetch("/api/okta", {
                method:  "POST",
                headers: { "Content-Type": "application/json" },
                body:    JSON.stringify({ prompt }),
            });
            const data = await resp.json();

            spin.classList.remove("show");
            result.classList.add("show");

            if (data.error) {
                document.getElementById("summaryBox").innerHTML = `
                    <div class="summary-card error-card">
                        <div class="summary-icon">&#9888;</div>
                        <div class="summary-text"><strong>Error:</strong> ${esc(data.error)}</div>
                    </div>`;
                return;
            }

            const steps = data.steps || [];
            document.getElementById("stepsList").innerHTML =
                steps.map((s, i) => renderStep(s, i)).join("");

            document.getElementById("summaryBox").innerHTML = `
                <div class="summary-card">
                    <div class="summary-icon">&#10003;</div>
                    <div class="summary-text">${esc(data.summary || "Done.")}</div>
                </div>`;

        } catch (err) {
            spin.classList.remove("show");
            result.classList.add("show");
            document.getElementById("summaryBox").innerHTML = `
                <div class="summary-card error-card">
                    <div class="summary-icon">&#9888;</div>
                    <div class="summary-text"><strong>Network error:</strong> ${esc(err.message)}</div>
                </div>`;
        } finally {
            btn.disabled = false;
        }
    }

    // Submit on Ctrl/Cmd+Enter
    document.getElementById("prompt").addEventListener("keydown", e => {
        if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); runAgent(); }
    });
</script>
</body>
</html>
HTMLEOF

success "HTML frontend created."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6: Set permissions
# ══════════════════════════════════════════════════════════════════════════════
info "Setting file permissions..."
chown -R www-data:www-data "${SITE_DIR}"
chown -R www-data:www-data "${API_DIR}"
chmod -R 755 "${SITE_DIR}"
success "Permissions set."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7: Configure Apache virtual host
# ══════════════════════════════════════════════════════════════════════════════
info "Writing Apache virtual host config..."
cat > "${VHOST_CONF}" <<VHOSTEOF
<VirtualHost *:80>
    ServerName ${SERVER_NAME}
    DocumentRoot ${SITE_DIR}

    <Directory ${SITE_DIR}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    # Reverse proxy /api/* to Flask backend
    ProxyPreserveHost On
    ProxyPass        /api/ http://127.0.0.1:${API_PORT}/api/
    ProxyPassReverse /api/ http://127.0.0.1:${API_PORT}/api/

    # Security headers
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set X-XSS-Protection "1; mode=block"

    ErrorLog  \${APACHE_LOG_DIR}/${SITE_NAME}-error.log
    CustomLog \${APACHE_LOG_DIR}/${SITE_NAME}-access.log combined
</VirtualHost>
VHOSTEOF

success "Virtual host config written."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8: Enable site and restart Apache
# ══════════════════════════════════════════════════════════════════════════════
info "Enabling site..."
a2dissite 000-default > /dev/null 2>&1 || true
a2ensite "${SITE_NAME}" > /dev/null 2>&1

info "Testing Apache config..."
if apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
    success "Apache config syntax OK."
else
    fail "Apache config test failed. Check ${VHOST_CONF}."
fi

info "Restarting Apache..."
systemctl enable apache2 > /dev/null 2>&1
systemctl restart apache2
success "Apache restarted."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 9: Smoke tests
# ══════════════════════════════════════════════════════════════════════════════
info "Waiting for services to stabilize..."
sleep 2

info "Smoke test — landing page..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/)
if [[ "${HTTP_CODE}" == "200" ]]; then
    success "Landing page — HTTP 200 OK!"
else
    warn "Landing page returned HTTP ${HTTP_CODE}."
fi

info "Smoke test — API health..."
HEALTH=$(curl -s http://localhost/api/health 2>/dev/null || echo '{"status":"unreachable"}')
echo "       ${HEALTH}"
if echo "${HEALTH}" | grep -q '"ok"'; then
    success "API health check passed."
else
    warn "API may not be ready yet. Check: sudo journalctl -u ${SERVICE_NAME} -f"
fi

# ══════════════════════════════════════════════════════════════════════════════
# DONE
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "================================================================"
echo "  OKTA AGENT SITE — SETUP COMPLETE"
echo "================================================================"
echo ""
echo "  URL:            http://localhost"
echo "  API endpoint:   POST http://localhost/api/okta"
echo "  Health check:   GET  http://localhost/api/health"
echo ""
echo "  Okta domain:    ${OKTA_DOMAIN}"
echo ""
echo "  Example usage (curl):"
echo "    curl -s -X POST http://localhost/api/okta \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"prompt\": \"Add Abe Ramo with email wof@theflux.net to TheFlux group\"}'"
echo ""
echo "  Useful commands:"
echo "      sudo journalctl -u ${SERVICE_NAME} -f   # API logs"
echo "      sudo systemctl restart ${SERVICE_NAME}   # Restart API"
echo "      sudo systemctl restart apache2           # Restart Apache"
echo "================================================================"

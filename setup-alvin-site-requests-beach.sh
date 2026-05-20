#!/usr/bin/env bash
# ==============================================================================
# setup-alvin-site.sh
#
# A single-run script that:
#   1. Installs Apache2 + Python3/Flask on Debian 11 (Bullseye)
#   2. Deploys a professional landing page for Alvin
#   3. Sets up a Flask API backend that:
#      a) Requires visitors to provide Name, Email, Company before chatting
#      b) Logs visitor info to a CSV file on the server
#      c) Reads Alvin's PDF resume and uses Claude to answer questions
#   4. Configures Apache as a reverse proxy to the Flask backend
#   5. Creates a systemd service for the Flask API
#   6. Verifies everything is working
#
# Prerequisites:
#   - Debian 11 (Bullseye) with root/sudo
#   - Alvin's resume PDF placed at /var/www/alvin-site/alvin.pdf
#   - Claude API key set as environment variable ANTHROPIC_API_KEY
#
# Usage:
#   export ANTHROPIC_API_KEY="sk-ant-..."
#   chmod +x setup-alvin-site.sh
#   sudo -E ./setup-alvin-site.sh      # -E preserves env vars
# ==============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SITE_NAME="alvin-site"
SITE_DIR="/var/www/${SITE_NAME}"
VHOST_CONF="/etc/apache2/sites-available/${SITE_NAME}.conf"
SERVER_NAME="localhost"
API_DIR="/opt/${SITE_NAME}-api"
API_PORT=5000
SERVICE_NAME="${SITE_NAME}-api"
VISITOR_LOG="${SITE_DIR}/data/visitors.csv"

# ── Helper functions ──────────────────────────────────────────────────────────
info()    { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
success() { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
fail()    { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

# ── Pre-flight checks ────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root (use: sudo -E ./setup-alvin-site.sh)"
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    fail "ANTHROPIC_API_KEY environment variable is not set.\n       Run: export ANTHROPIC_API_KEY=\"sk-ant-...\" then re-run with sudo -E"
fi

info "Detected OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
info "API key detected: ${ANTHROPIC_API_KEY:0:12}..."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: Install system packages
# ══════════════════════════════════════════════════════════════════════════════
info "Updating package lists..."
apt-get update -qq

info "Installing apache2, python3, pip, and dependencies..."
apt-get install -y -qq apache2 curl python3 python3-pip python3-venv > /dev/null 2>&1
success "System packages installed."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Enable Apache modules
# ══════════════════════════════════════════════════════════════════════════════
info "Enabling Apache modules (rewrite, headers, proxy, proxy_http)..."
a2enmod rewrite  > /dev/null 2>&1 || true
a2enmod headers  > /dev/null 2>&1 || true
a2enmod proxy    > /dev/null 2>&1 || true
a2enmod proxy_http > /dev/null 2>&1 || true
success "Apache modules enabled."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: Create data directory for visitor log
# ══════════════════════════════════════════════════════════════════════════════
info "Creating visitor log directory..."
mkdir -p "${SITE_DIR}/data"
# Initialize CSV with headers if it doesn't exist
if [[ ! -f "${VISITOR_LOG}" ]]; then
    echo "timestamp,name,email,company,ip_address,user_agent" > "${VISITOR_LOG}"
fi
chown -R www-data:www-data "${SITE_DIR}/data"
chmod 750 "${SITE_DIR}/data"
chmod 640 "${VISITOR_LOG}"
success "Visitor log initialized at ${VISITOR_LOG}"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Create Flask API backend
# ══════════════════════════════════════════════════════════════════════════════
info "Setting up Flask API backend at ${API_DIR}..."
mkdir -p "${API_DIR}"

# Create Python virtual environment
python3 -m venv "${API_DIR}/venv"
source "${API_DIR}/venv/bin/activate"

info "Installing Python dependencies (Flask, anthropic, PyPDF2)..."
pip install --quiet flask anthropic PyPDF2
deactivate

# Write the Flask application
cat > "${API_DIR}/app.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Alvin Resume Chatbot — Flask API Backend

Features:
  - /api/register  — Accepts visitor name, email, company; logs to CSV
  - /api/chat      — Requires registration token; answers resume questions via Claude
  - /api/health    — Health check
"""

import os
import sys
import csv
import json
import uuid
import logging
import re
from datetime import datetime
from flask import Flask, request, jsonify
from anthropic import Anthropic
import PyPDF2

# ── Configuration ─────────────────────────────────────────────────────────────
PDF_PATH = "/var/www/alvin-site/alvin.pdf"
VISITOR_LOG = "/var/www/alvin-site/data/visitors.csv"
MODEL = "claude-sonnet-4-20250514"
MAX_TOKENS = 1024

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

# ── In-memory session store (maps token → visitor info) ──────────────────────
sessions = {}

# ── Read PDF at startup ──────────────────────────────────────────────────────
def extract_pdf_text(path):
    """Extract all text from a PDF file."""
    if not os.path.exists(path):
        logger.error(f"PDF not found at {path}")
        return None
    try:
        text_parts = []
        with open(path, "rb") as f:
            reader = PyPDF2.PdfReader(f)
            for i, page in enumerate(reader.pages):
                page_text = page.extract_text()
                if page_text:
                    text_parts.append(f"--- Page {i+1} ---\n{page_text}")
        full_text = "\n\n".join(text_parts)
        logger.info(f"Extracted {len(full_text)} characters from {len(reader.pages)} pages")
        return full_text
    except Exception as e:
        logger.error(f"Failed to read PDF: {e}")
        return None

RESUME_TEXT = extract_pdf_text(PDF_PATH)

# ── Flask App ─────────────────────────────────────────────────────────────────
app = Flask(__name__)

# Initialize Anthropic client (reads ANTHROPIC_API_KEY from env)
client = Anthropic()

SYSTEM_PROMPT = """You are a helpful AI assistant embedded on Alvin's professional portfolio website.
Your role is to answer questions about Alvin based ONLY on the resume content provided below.

The person chatting with you has identified themselves as: {visitor_name} from {visitor_company}.

RULES:
- Answer questions about Alvin's experience, skills, certifications, education, and career history.
- Be professional, concise, and friendly.
- You may address the visitor by their first name occasionally to keep it personable.
- If a question cannot be answered from the resume content, say so politely.
- Do not make up information that is not in the resume.
- Keep answers focused and relevant — typically 2-4 sentences unless more detail is requested.
- You may format responses with simple markdown (bold, bullet points) for readability.

ALVIN'S RESUME CONTENT:
{resume_text}
"""


def validate_email(email):
    """Basic email validation."""
    pattern = r'^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$'
    return re.match(pattern, email) is not None


def log_visitor(name, email, company, ip, user_agent):
    """Append visitor info to the CSV log file."""
    try:
        timestamp = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
        with open(VISITOR_LOG, "a", newline="") as f:
            writer = csv.writer(f)
            writer.writerow([timestamp, name, email, company, ip, user_agent])
        logger.info(f"Visitor logged: {name} ({email}) from {company}")
    except Exception as e:
        logger.error(f"Failed to log visitor: {e}")


@app.route("/api/register", methods=["POST"])
def register():
    """Register a visitor — collect name, email, company. Returns a session token."""
    try:
        data = request.get_json()
        if not data:
            return jsonify({"error": "Invalid request"}), 400

        name = data.get("name", "").strip()
        email = data.get("email", "").strip()
        company = data.get("company", "").strip()

        # Validate required fields
        errors = []
        if not name or len(name) < 2:
            errors.append("Please enter your full name.")
        if not email or not validate_email(email):
            errors.append("Please enter a valid email address.")
        if not company or len(company) < 2:
            errors.append("Please enter your company name.")

        if errors:
            return jsonify({"error": " ".join(errors)}), 400

        # Sanitize inputs (limit length)
        name = name[:100]
        email = email[:150]
        company = company[:100]

        # Generate session token
        token = str(uuid.uuid4())

        # Store session
        sessions[token] = {
            "name": name,
            "email": email,
            "company": company,
            "registered_at": datetime.utcnow().isoformat()
        }

        # Log to CSV
        ip = request.headers.get("X-Forwarded-For", request.remote_addr)
        user_agent = request.headers.get("User-Agent", "unknown")[:200]
        log_visitor(name, email, company, ip, user_agent)

        logger.info(f"New registration: {name} ({email}) — {company} → token={token[:8]}...")

        return jsonify({
            "success": True,
            "token": token,
            "greeting": f"Welcome, {name.split()[0]}! You can now ask me anything about Alvin's experience."
        })

    except Exception as e:
        logger.error(f"Registration error: {e}")
        return jsonify({"error": "Something went wrong. Please try again."}), 500


@app.route("/api/chat", methods=["POST"])
def chat():
    """Handle chat messages — requires a valid session token."""
    try:
        data = request.get_json()
        if not data or "message" not in data:
            return jsonify({"error": "Missing 'message' field"}), 400

        # Verify session token
        token = data.get("token", "")
        if not token or token not in sessions:
            return jsonify({"error": "SESSION_EXPIRED"}), 401

        visitor = sessions[token]
        user_message = data["message"].strip()

        if not user_message:
            return jsonify({"error": "Empty message"}), 400

        if len(user_message) > 1000:
            return jsonify({"error": "Message too long (max 1000 characters)"}), 400

        # Check if resume was loaded
        if not RESUME_TEXT:
            return jsonify({
                "reply": "I'm sorry, but I couldn't load Alvin's resume PDF. "
                         "Please make sure the file is placed at /var/www/alvin-site/alvin.pdf "
                         "and restart the service."
            }), 200

        # Conversation history from client (optional)
        history = data.get("history", [])

        # Build messages array
        messages = []
        for msg in history[-10:]:  # Keep last 10 messages for context
            if msg.get("role") in ("user", "assistant") and msg.get("content"):
                messages.append({"role": msg["role"], "content": msg["content"]})

        # Add current user message
        messages.append({"role": "user", "content": user_message})

        # Call Claude API
        response = client.messages.create(
            model=MODEL,
            max_tokens=MAX_TOKENS,
            system=SYSTEM_PROMPT.format(
                resume_text=RESUME_TEXT,
                visitor_name=visitor["name"],
                visitor_company=visitor["company"]
            ),
            messages=messages
        )

        reply = response.content[0].text
        logger.info(f"[{visitor['name']}] Q: {user_message[:60]}... → A: {reply[:60]}...")

        return jsonify({"reply": reply})

    except Exception as e:
        logger.error(f"Chat error: {e}")
        return jsonify({"error": "Something went wrong. Please try again."}), 500


@app.route("/api/health", methods=["GET"])
def health():
    """Health check endpoint."""
    return jsonify({
        "status": "ok",
        "resume_loaded": RESUME_TEXT is not None,
        "resume_length": len(RESUME_TEXT) if RESUME_TEXT else 0,
        "active_sessions": len(sessions)
    })


if __name__ == "__main__":
    if not os.environ.get("ANTHROPIC_API_KEY"):
        logger.error("ANTHROPIC_API_KEY not set!")
        sys.exit(1)
    app.run(host="127.0.0.1", port=5000, debug=False)
PYEOF

success "Flask API application created."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: Create systemd service for the Flask API
# ══════════════════════════════════════════════════════════════════════════════
info "Creating systemd service for the API..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SVCEOF
[Unit]
Description=Alvin Resume Chatbot API (Flask)
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=${API_DIR}
Environment="ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"
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
systemctl start "${SERVICE_NAME}"
success "Flask API service started and enabled on boot."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6: Create the website directory & HTML landing page
# ══════════════════════════════════════════════════════════════════════════════
info "Creating site directory at ${SITE_DIR}..."
mkdir -p "${SITE_DIR}"

info "Building HTML landing page with Florida beach theme + lead-capture + AI chatbot..."
cat > "${SITE_DIR}/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Alvin — Senior Operations Engineer</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link href="https://fonts.googleapis.com/css2?family=Playfair+Display:ital,wght@0,400;0,600;0,700;0,800;1,400&family=Source+Sans+3:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
    <style>
        *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }

        :root {
            /* Dusky twilight palette */
            --sky-deep: #2c3e6b;
            --sky-purple: #4a5d8a;
            --sky-mauve: #7b6e8e;
            --horizon-warm: #c97b7b;
            --horizon-gold: #e8a87c;
            --ocean-twilight: #4a8fa0;
            --ocean-deep: #2e6e7e;
            --sand-wet: #c4a67a;
            --sand-mid: #dcc9a3;
            --sand-light: #ede0c8;
            --sand-pale: #f5eede;

            /* Text — all dark/black */
            --text-black: #1a1a1a;
            --text-dark: #2d2d2d;
            --text-body: #3a3a3a;
            --text-mid: #555555;
            --text-caption: #666666;

            /* Accent */
            --accent-warm: #c97b7b;
            --accent-coral: #d4836b;
            --accent-gold: #c49550;
            --accent-ocean: #2e6e7e;

            /* Cards */
            --card-bg: rgba(245, 238, 225, 0.93);
            --card-bg-hover: rgba(245, 238, 225, 0.97);
            --card-border: rgba(180, 160, 125, 0.45);

            /* Chat */
            --chat-bg: rgba(250, 245, 235, 0.94);
            --chat-border: rgba(180, 160, 125, 0.4);
            --chat-input-bg: rgba(240, 232, 215, 0.85);

            --error: #cc2222;
            --font-display: 'Playfair Display', Georgia, serif;
            --font-body: 'Source Sans 3', 'Segoe UI', sans-serif;
            --font-mono: 'JetBrains Mono', monospace;
        }

        html { scroll-behavior: smooth; }

        body {
            font-family: var(--font-body);
            min-height: 100vh;
            overflow-x: hidden;
            line-height: 1.6;
            color: var(--text-body);
            background: var(--sand-light);
        }

        /* ══════════════════════════════════════════════════════════════════
           DUSKY TWILIGHT BEACH — SOLID, STATIC BACKGROUND
           ══════════════════════════════════════════════════════════════════ */
        .beach-bg {
            position: fixed; inset: 0; z-index: 0;
            background: linear-gradient(
                180deg,
                #2c3e6b 0%,
                #4a5d8a 14%,
                #7b6e8e 26%,
                #c97b7b 38%,
                #e8a87c 48%,
                #d4a07a 53%,
                #4a8fa0 58%,
                #2e6e7e 70%,
                #c4a67a 78%,
                #dcc9a3 86%,
                #ede0c8 94%,
                #f5eede 100%
            );
        }

        /* Subtle horizon glow line */
        .horizon-glow {
            position: fixed; z-index: 1;
            top: 48%; left: 0; right: 0; height: 3px;
            background: linear-gradient(90deg,
                transparent 5%,
                rgba(232, 168, 124, 0.4) 25%,
                rgba(232, 168, 124, 0.55) 50%,
                rgba(232, 168, 124, 0.4) 75%,
                transparent 95%
            );
            filter: blur(2px);
        }

        /* ══════════════════════════════════════════════════════════════════
           CONTENT
           ══════════════════════════════════════════════════════════════════ */
        .container {
            position: relative; z-index: 10;
            max-width: 940px; margin: 0 auto;
            padding: 2.5rem 1.5rem;
        }

        /* ── Hero ── */
        .hero {
            text-align: center;
            margin-bottom: 2.5rem;
            padding: 2.5rem 2rem;
            background: var(--card-bg);
            backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px);
            border-radius: 20px;
            border: 1px solid var(--card-border);
            box-shadow: 0 6px 30px rgba(80, 60, 30, 0.1);
        }

        .hero h1 {
            font-family: var(--font-display);
            font-size: clamp(2.2rem, 5vw, 3.2rem);
            font-weight: 800;
            color: var(--text-black);
            letter-spacing: -0.5px;
            margin-bottom: 0.3rem;
        }
        .hero .role {
            font-family: var(--font-body);
            font-size: 0.88rem; font-weight: 600; letter-spacing: 3px;
            text-transform: uppercase;
            color: var(--accent-coral);
            margin-bottom: 1.6rem;
        }
        .hero .bio {
            max-width: 720px; margin: 0 auto;
            font-size: 1.02rem; line-height: 1.85;
            color: var(--text-body);
        }

        /* ── Skill pills ── */
        .skills {
            display: flex; flex-wrap: wrap; justify-content: center;
            gap: 0.5rem; margin-top: 1.8rem;
        }
        .pill {
            padding: 0.35rem 0.85rem; border-radius: 999px;
            font-size: 0.76rem; font-weight: 600;
            background: rgba(220, 201, 163, 0.5);
            border: 1px solid rgba(180, 160, 125, 0.4);
            color: var(--text-dark);
            transition: all 0.2s;
        }
        .pill:hover {
            background: rgba(220, 201, 163, 0.8);
            transform: translateY(-1px);
            box-shadow: 0 2px 8px rgba(100, 80, 40, 0.1);
        }
        .pill.hl {
            background: rgba(201, 123, 123, 0.18);
            border-color: rgba(201, 123, 123, 0.4);
            color: #8b3a3a;
        }

        /* ── Stats ── */
        .stats {
            display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
            gap: 1rem; margin-bottom: 2.5rem;
        }
        .stat {
            background: var(--card-bg);
            backdrop-filter: blur(8px); -webkit-backdrop-filter: blur(8px);
            border: 1px solid var(--card-border);
            border-radius: 16px; padding: 1.3rem; text-align: center;
            transition: all 0.2s;
        }
        .stat:hover {
            background: var(--card-bg-hover);
            transform: translateY(-2px);
            box-shadow: 0 6px 20px rgba(80, 60, 30, 0.1);
        }
        .stat .num {
            font-family: var(--font-display);
            font-size: 1.8rem; font-weight: 800;
            color: var(--accent-ocean);
        }
        .stat .lbl {
            font-size: 0.72rem; font-weight: 600;
            color: var(--text-mid);
            text-transform: uppercase; letter-spacing: 1.5px; margin-top: 0.25rem;
        }

        /* ══════════════════════════════════════════════════════════════════
           CHATBOT
           ══════════════════════════════════════════════════════════════════ */
        .chat-section {
            border: 1px solid var(--chat-border);
            border-radius: 20px; overflow: hidden;
            background: var(--chat-bg);
            backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px);
            box-shadow: 0 6px 30px rgba(80, 60, 30, 0.1);
        }

        .chat-header {
            padding: 1rem 1.5rem;
            display: flex; align-items: center; gap: 0.75rem;
            border-bottom: 1px solid rgba(180, 160, 125, 0.25);
            background: rgba(240, 232, 215, 0.5);
        }
        .chat-header .dot {
            width: 10px; height: 10px; border-radius: 50%;
            background: #5a9e6f;
            box-shadow: 0 0 6px rgba(90, 158, 111, 0.4);
        }
        .chat-header h3 { font-size: 0.9rem; font-weight: 700; color: var(--text-black); }
        .chat-header .powered { font-size: 0.72rem; color: var(--text-caption); margin-left: auto; font-family: var(--font-mono); }

        /* ── Registration gate ── */
        .register-gate { padding: 2rem 1.5rem; }
        .register-gate .gate-intro {
            font-size: 0.95rem; color: var(--text-body); margin-bottom: 1.5rem; line-height: 1.7;
        }
        .register-gate .gate-intro strong { color: var(--text-black); }
        .form-group { margin-bottom: 1rem; }
        .form-group label {
            display: block; font-size: 0.75rem; font-weight: 700;
            color: var(--text-dark); margin-bottom: 0.35rem;
            text-transform: uppercase; letter-spacing: 1px;
        }
        .form-group input {
            width: 100%; padding: 0.7rem 1rem;
            background: var(--chat-input-bg);
            border: 1px solid rgba(180, 160, 125, 0.45);
            border-radius: 10px; color: var(--text-black);
            font-family: var(--font-body); font-size: 0.9rem;
            outline: none; transition: all 0.2s;
        }
        .form-group input::placeholder { color: var(--text-caption); }
        .form-group input:focus { border-color: var(--accent-warm); background: rgba(250, 245, 232, 0.95); }
        .form-group input.input-error { border-color: var(--error); }

        .register-btn {
            width: 100%; padding: 0.8rem; margin-top: 0.5rem;
            background: linear-gradient(135deg, var(--accent-warm), var(--accent-coral));
            border: none; border-radius: 10px; color: #fff; font-weight: 700;
            font-size: 0.9rem; cursor: pointer; transition: all 0.2s;
            font-family: var(--font-body);
            box-shadow: 0 4px 14px rgba(201, 123, 123, 0.25);
        }
        .register-btn:hover { filter: brightness(1.08); transform: translateY(-1px); box-shadow: 0 6px 18px rgba(201, 123, 123, 0.35); }
        .register-btn:disabled { opacity: 0.5; cursor: not-allowed; transform: none; }

        .form-error {
            margin-top: 0.75rem; padding: 0.6rem 0.9rem; border-radius: 8px;
            background: rgba(204, 34, 34, 0.08); border: 1px solid rgba(204, 34, 34, 0.2);
            color: var(--error); font-size: 0.85rem; font-weight: 500; display: none;
        }
        .form-error.show { display: block; }

        /* ── Chat area ── */
        .chat-body { display: none; }
        .chat-body.active { display: block; }

        .chat-messages {
            height: 400px; overflow-y: auto; padding: 1.5rem;
            display: flex; flex-direction: column; gap: 1rem; scroll-behavior: smooth;
        }
        .chat-messages::-webkit-scrollbar { width: 6px; }
        .chat-messages::-webkit-scrollbar-track { background: transparent; }
        .chat-messages::-webkit-scrollbar-thumb { background: rgba(180, 155, 110, 0.35); border-radius: 3px; }

        .msg {
            max-width: 80%; padding: 0.85rem 1.1rem;
            border-radius: 14px; font-size: 0.92rem;
            line-height: 1.7;
        }
        .msg.bot {
            align-self: flex-start;
            background: rgba(220, 201, 163, 0.35);
            border: 1px solid rgba(180, 160, 125, 0.3);
            border-bottom-left-radius: 4px;
            color: var(--text-body);
        }
        .msg.user {
            align-self: flex-end;
            background: linear-gradient(135deg, var(--ocean-twilight), var(--ocean-deep));
            border-bottom-right-radius: 4px;
            color: #fff;
            box-shadow: 0 2px 10px rgba(46, 110, 126, 0.2);
        }
        .msg.bot strong { color: var(--text-black); }
        .msg.bot ul, .msg.bot ol { margin: 0.4rem 0 0.4rem 1.2rem; }

        .typing-indicator {
            display: none; align-self: flex-start;
            padding: 0.85rem 1.1rem;
            background: rgba(220, 201, 163, 0.35);
            border: 1px solid rgba(180, 160, 125, 0.3);
            border-radius: 14px; border-bottom-left-radius: 4px;
        }
        .typing-indicator.show { display: flex; gap: 5px; align-items: center; }
        .typing-dot {
            width: 7px; height: 7px; border-radius: 50%;
            background: var(--text-caption);
        }
        .typing-dot:nth-child(1) { animation: tb 1.4s ease-in-out infinite; }
        .typing-dot:nth-child(2) { animation: tb 1.4s ease-in-out 0.2s infinite; }
        .typing-dot:nth-child(3) { animation: tb 1.4s ease-in-out 0.4s infinite; }
        @keyframes tb { 0%,60%,100%{transform:translateY(0);opacity:0.4} 30%{transform:translateY(-6px);opacity:1} }

        .suggestions { display: flex; flex-wrap: wrap; gap: 0.5rem; padding: 0 1.5rem 1rem; }
        .suggestion-chip {
            padding: 0.4rem 0.85rem; border-radius: 999px; font-size: 0.78rem;
            font-family: var(--font-body); font-weight: 500;
            background: rgba(220, 201, 163, 0.4); border: 1px solid rgba(180, 160, 125, 0.35);
            color: var(--text-dark); cursor: pointer; transition: all 0.2s;
        }
        .suggestion-chip:hover {
            background: rgba(201, 123, 123, 0.15); border-color: rgba(201, 123, 123, 0.35);
            color: #8b3a3a;
        }

        .chat-input-area {
            display: flex; gap: 0.75rem; padding: 1rem 1.5rem;
            border-top: 1px solid rgba(180, 160, 125, 0.2);
            background: rgba(240, 232, 215, 0.35);
        }
        .chat-input-area input {
            flex: 1; padding: 0.75rem 1rem;
            background: var(--chat-input-bg);
            border: 1px solid rgba(180, 160, 125, 0.4);
            border-radius: 10px; color: var(--text-black);
            font-family: var(--font-body); font-size: 0.9rem;
            outline: none; transition: border-color 0.2s;
        }
        .chat-input-area input::placeholder { color: var(--text-caption); }
        .chat-input-area input:focus { border-color: var(--accent-warm); }
        .chat-input-area button {
            padding: 0.75rem 1.3rem;
            background: linear-gradient(135deg, var(--accent-warm), var(--accent-coral));
            border: none; border-radius: 10px; color: #fff; font-weight: 700;
            font-size: 0.85rem; cursor: pointer; transition: all 0.2s;
            font-family: var(--font-body);
            box-shadow: 0 2px 10px rgba(201, 123, 123, 0.2);
        }
        .chat-input-area button:hover { filter: brightness(1.08); transform: scale(1.02); }
        .chat-input-area button:disabled { opacity: 0.5; cursor: not-allowed; transform: none; }

        /* ── Footer ── */
        footer {
            text-align: center; margin-top: 2.5rem; padding: 1.2rem 0;
            color: var(--text-caption); font-size: 0.78rem;
        }
        footer span { color: var(--accent-coral); font-weight: 600; }

        /* ── Responsive ── */
        @media (max-width: 700px) {
            .container { padding: 1.5rem 1rem; }
            .stats { grid-template-columns: 1fr 1fr; }
            .msg { max-width: 90%; }
            .chat-messages { height: 320px; }
            .hero { padding: 1.8rem 1.2rem; }
        }
    </style>
</head>
<body>

    <!-- Static dusky twilight beach background -->
    <div class="beach-bg"></div>
    <div class="horizon-glow"></div>

    <div class="container">

        <section class="hero">
            <h1>Alvin</h1>
            <p class="role">Senior Operations Engineer</p>
            <p class="bio">
                Versatile and growth-driven Cloud Infrastructure &amp; Cybersecurity Architect
                with over 25 years of success leading enterprise-scale IT transformations.
                Proven ability to architect, automate, and secure hybrid environments using
                modern Dev/SecOps practices and cloud-native tooling. Deep expertise in
                multi-cloud deployments (AWS/Azure), infrastructure as code, and end-to-end
                solutions. A seasoned leader with a passion for scalable automation, security
                compliance, and innovation across infrastructure platforms.
            </p>
            <div class="skills">
                <span class="pill hl">AWS</span>
                <span class="pill hl">Azure</span>
                <span class="pill">Infrastructure as Code</span>
                <span class="pill">DevSecOps</span>
                <span class="pill">Cybersecurity</span>
                <span class="pill">Hybrid Cloud</span>
                <span class="pill">Automation</span>
                <span class="pill">CI/CD Pipelines</span>
                <span class="pill">Terraform</span>
                <span class="pill">Kubernetes</span>
                <span class="pill">Security Compliance</span>
                <span class="pill">Linux / Windows</span>
            </div>
        </section>

        <div class="stats">
            <div class="stat"><div class="num">25+</div><div class="lbl">Years Experience</div></div>
            <div class="stat"><div class="num">Multi</div><div class="lbl">Cloud Expertise</div></div>
            <div class="stat"><div class="num">E2E</div><div class="lbl">Solutions Architect</div></div>
            <div class="stat"><div class="num">Dev/Sec</div><div class="lbl">Ops Practices</div></div>
        </div>

        <section class="chat-section" id="chatbot">
            <div class="chat-header">
                <div class="dot"></div>
                <h3>Ask AI About Alvin's Experience</h3>
                <span class="powered">Powered by Claude</span>
            </div>

            <div class="register-gate" id="registerGate">
                <p class="gate-intro">
                    <strong>Welcome!</strong> Before you chat with our AI assistant about Alvin's
                    experience and qualifications, please introduce yourself below.
                </p>
                <div class="form-group">
                    <label for="regName">Your Name</label>
                    <input type="text" id="regName" placeholder="John Smith" maxlength="100" autocomplete="name">
                </div>
                <div class="form-group">
                    <label for="regEmail">Email Address</label>
                    <input type="email" id="regEmail" placeholder="john@company.com" maxlength="150" autocomplete="email">
                </div>
                <div class="form-group">
                    <label for="regCompany">Company</label>
                    <input type="text" id="regCompany" placeholder="Acme Corp" maxlength="100" autocomplete="organization">
                </div>
                <button class="register-btn" id="registerBtn" onclick="submitRegistration()">
                    Start Chatting &#8594;
                </button>
                <div class="form-error" id="formError"></div>
            </div>

            <div class="chat-body" id="chatBody">
                <div class="chat-messages" id="chatMessages"></div>

                <div class="suggestions" id="suggestions">
                    <button class="suggestion-chip" onclick="askSuggestion(this)">What are Alvin's top skills?</button>
                    <button class="suggestion-chip" onclick="askSuggestion(this)">Summarize his experience</button>
                    <button class="suggestion-chip" onclick="askSuggestion(this)">What certifications does he hold?</button>
                    <button class="suggestion-chip" onclick="askSuggestion(this)">Cloud platforms experience?</button>
                </div>

                <div class="chat-input-area">
                    <input type="text" id="chatInput" placeholder="Ask about Alvin's experience..."
                           autocomplete="off" maxlength="1000">
                    <button id="sendBtn" onclick="sendMessage()">
                        Send &#9654;
                    </button>
                </div>
            </div>
        </section>

        <footer>
            &copy; 2026 Alvin &mdash; <span>Senior Operations Engineer</span> &middot; Tampa, FL
        </footer>
    </div>

    <script>
        let sessionToken = null;
        let visitorName = '';
        let conversationHistory = [];
        let isWaiting = false;

        const registerGate = document.getElementById('registerGate');
        const chatBody     = document.getElementById('chatBody');
        const chatMessages = document.getElementById('chatMessages');
        const chatInput    = document.getElementById('chatInput');
        const sendBtn      = document.getElementById('sendBtn');
        const suggestions  = document.getElementById('suggestions');
        const formError    = document.getElementById('formError');
        const registerBtn  = document.getElementById('registerBtn');

        async function submitRegistration() {
            const name    = document.getElementById('regName').value.trim();
            const email   = document.getElementById('regEmail').value.trim();
            const company = document.getElementById('regCompany').value.trim();

            formError.classList.remove('show');
            document.querySelectorAll('.form-group input').forEach(i => i.classList.remove('input-error'));

            let hasError = false;
            if (!name || name.length < 2) { document.getElementById('regName').classList.add('input-error'); hasError = true; }
            if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) { document.getElementById('regEmail').classList.add('input-error'); hasError = true; }
            if (!company || company.length < 2) { document.getElementById('regCompany').classList.add('input-error'); hasError = true; }
            if (hasError) { showFormError('Please fill in all fields with valid information.'); return; }

            registerBtn.disabled = true;
            registerBtn.textContent = 'Registering...';

            try {
                const res = await fetch('/api/register', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ name, email, company })
                });
                const data = await res.json();
                if (data.error) {
                    showFormError(data.error);
                    registerBtn.disabled = false;
                    registerBtn.textContent = 'Start Chatting \u2192';
                    return;
                }
                sessionToken = data.token;
                visitorName = name.split(' ')[0];
                registerGate.style.display = 'none';
                chatBody.classList.add('active');
                appendMessage('bot', data.greeting);
            } catch (err) {
                showFormError('Could not reach the server. Please try again.');
                registerBtn.disabled = false;
                registerBtn.textContent = 'Start Chatting \u2192';
            }
        }

        function showFormError(msg) { formError.textContent = msg; formError.classList.add('show'); }

        document.querySelectorAll('.register-gate input').forEach(input => {
            input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); submitRegistration(); } });
        });

        async function sendMessage() {
            const text = chatInput.value.trim();
            if (!text || isWaiting || !sessionToken) return;
            suggestions.style.display = 'none';
            appendMessage('user', text);
            chatInput.value = '';
            conversationHistory.push({ role: 'user', content: text });
            isWaiting = true; sendBtn.disabled = true;
            const typingEl = showTyping();
            try {
                const res = await fetch('/api/chat', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ message: text, token: sessionToken, history: conversationHistory.slice(-10) })
                });
                const data = await res.json();
                typingEl.remove();
                if (data.error === 'SESSION_EXPIRED') {
                    appendMessage('bot', 'Your session has expired. Please refresh the page to start a new conversation.');
                } else if (data.error) {
                    appendMessage('bot', '&#9888;&#65039; ' + data.error);
                } else {
                    appendMessage('bot', formatMarkdown(data.reply));
                    conversationHistory.push({ role: 'assistant', content: data.reply });
                }
            } catch (err) {
                typingEl.remove();
                appendMessage('bot', '&#9888;&#65039; Could not reach the server. Please try again.');
            }
            isWaiting = false; sendBtn.disabled = false; chatInput.focus();
        }

        function askSuggestion(el) { chatInput.value = el.textContent; sendMessage(); }

        function appendMessage(type, html) {
            const div = document.createElement('div');
            div.className = 'msg ' + type;
            div.innerHTML = html;
            chatMessages.appendChild(div);
            chatMessages.scrollTop = chatMessages.scrollHeight;
        }

        function showTyping() {
            const div = document.createElement('div');
            div.className = 'typing-indicator show';
            div.innerHTML = '<div class="typing-dot"></div><div class="typing-dot"></div><div class="typing-dot"></div>';
            chatMessages.appendChild(div);
            chatMessages.scrollTop = chatMessages.scrollHeight;
            return div;
        }

        function formatMarkdown(text) {
            return text
                .replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>')
                .replace(/\*(.*?)\*/g, '<em>$1</em>')
                .replace(/^- (.+)$/gm, '<li>$1</li>')
                .replace(/(<li>.*<\/li>)/s, '<ul>$1</ul>')
                .replace(/\n/g, '<br>');
        }

        chatInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
        });
    </script>
</body>
</html>
HTMLEOF
success "HTML landing page with dusky twilight beach theme created."
success "HTML landing page with natural Florida beach theme created."
success "HTML landing page with Florida beach theme created."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7: Set permissions
# ══════════════════════════════════════════════════════════════════════════════
info "Setting file permissions..."
chown -R www-data:www-data "${SITE_DIR}"
chmod -R 755 "${SITE_DIR}"
# Keep data directory locked down
chmod 750 "${SITE_DIR}/data"
chmod 640 "${VISITOR_LOG}"

if [[ -f "${SITE_DIR}/alvin.pdf" ]]; then
    success "Resume PDF found at ${SITE_DIR}/alvin.pdf"
    chmod 644 "${SITE_DIR}/alvin.pdf"
else
    warn "Resume PDF NOT found at ${SITE_DIR}/alvin.pdf"
    warn "The chatbot will show a helpful error until the PDF is placed there."
    warn "After placing it, restart the API:  sudo systemctl restart ${SERVICE_NAME}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8: Configure Apache virtual host with reverse proxy
# ══════════════════════════════════════════════════════════════════════════════
info "Writing Apache virtual host config with reverse proxy..."
cat > "${VHOST_CONF}" <<VHOSTEOF
<VirtualHost *:80>
    ServerName ${SERVER_NAME}
    DocumentRoot ${SITE_DIR}

    <Directory ${SITE_DIR}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    # Block direct web access to the PDF and data directory
    <Files "alvin.pdf">
        Require all denied
    </Files>
    <Directory ${SITE_DIR}/data>
        Require all denied
    </Directory>

    # Reverse proxy /api/* requests to Flask backend
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
# STEP 9: Enable site, disable default, test & restart Apache
# ══════════════════════════════════════════════════════════════════════════════
info "Enabling site and disabling default..."
a2dissite 000-default > /dev/null 2>&1 || true
a2ensite "${SITE_NAME}" > /dev/null 2>&1
success "Site enabled."

info "Testing Apache configuration..."
if apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
    success "Apache config syntax OK."
else
    fail "Apache config test failed. Check ${VHOST_CONF}."
fi

info "Restarting Apache..."
systemctl enable apache2 > /dev/null 2>&1
systemctl restart apache2
success "Apache restarted and enabled on boot."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 10: Smoke tests
# ══════════════════════════════════════════════════════════════════════════════
info "Waiting for services to stabilize..."
sleep 2

info "Smoke test — landing page (http://localhost)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/)
if [[ "${HTTP_CODE}" == "200" ]]; then
    success "Landing page — HTTP 200 OK!"
else
    warn "Landing page returned HTTP ${HTTP_CODE}."
fi

info "Smoke test — API health (/api/health)..."
HEALTH=$(curl -s http://localhost/api/health 2>/dev/null || echo '{"status":"unreachable"}')
echo "       ${HEALTH}"
if echo "${HEALTH}" | grep -q '"ok"'; then
    success "API health check passed."
else
    warn "API may not be ready yet. Check: sudo journalctl -u ${SERVICE_NAME} -f"
fi

info "Verifying data directory is blocked from web access..."
DATA_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/data/visitors.csv)
if [[ "${DATA_CODE}" == "403" ]] || [[ "${DATA_CODE}" == "404" ]]; then
    success "Visitor log is NOT accessible from the web (HTTP ${DATA_CODE})."
else
    warn "Visitor log returned HTTP ${DATA_CODE} — check Apache config."
fi

# ══════════════════════════════════════════════════════════════════════════════
# DONE
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "================================================================"
echo "  SETUP COMPLETE"
echo "================================================================"
echo ""
echo "  Website:       http://localhost"
echo "  Chat API:      http://localhost/api/chat"
echo "  Register API:  http://localhost/api/register"
echo "  Health check:  http://localhost/api/health"
echo ""
echo "  Site files:    ${SITE_DIR}/"
echo "  Resume PDF:    ${SITE_DIR}/alvin.pdf"
echo "  Visitor log:   ${VISITOR_LOG}"
echo "  Flask API:     ${API_DIR}/"
echo "  VHost conf:    ${VHOST_CONF}"
echo ""
echo "  View visitor log:"
echo "      sudo cat ${VISITOR_LOG}"
echo "      sudo column -t -s, ${VISITOR_LOG}"
echo ""
echo "  Useful commands:"
echo "      sudo journalctl -u ${SERVICE_NAME} -f    # API logs"
echo "      sudo systemctl restart ${SERVICE_NAME}    # Restart API"
echo "      sudo systemctl restart apache2            # Restart Apache"
echo ""
echo "  If resume PDF is not yet in place:"
echo "      cp /path/to/resume.pdf ${SITE_DIR}/alvin.pdf"
echo "      sudo systemctl restart ${SERVICE_NAME}"
echo "================================================================"

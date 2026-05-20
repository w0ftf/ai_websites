#!/usr/bin/env bash
# ==============================================================================
# setup-job-dashboard.sh
#
# Adds a password-protected job application dashboard to Alvin's site:
#   1. Extends the Flask API with dashboard endpoints
#   2. Creates an HTML dashboard at /dashboard (password-protected)
#   3. Updates the job agent to generate Claude-written cover letters
#   4. Provides one-click "Apply Now" links + copy-ready cover letters
#   5. Tracks application status (new → reviewed → applied → rejected)
#
# This script is an ADD-ON — run AFTER setup-alvin-site.sh and setup-job-agent.sh
#
# Prerequisites:
#   - Both previous scripts already deployed and running
#   - Environment variables:
#       ANTHROPIC_API_KEY    — Claude API key (already set)
#       DASHBOARD_PASSWORD   — password to access the dashboard
#
# Usage:
#   export ANTHROPIC_API_KEY="sk-ant-..."
#   export DASHBOARD_PASSWORD="your-secure-password"
#   chmod +x setup-job-dashboard.sh
#   sudo -E ./setup-job-dashboard.sh
# ==============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SITE_DIR="/var/www/alvin-site"
API_DIR="/opt/alvin-site-api"
AGENT_DIR="/opt/job-agent"
DASH_DATA="${AGENT_DIR}/data"
SERVICE_NAME="alvin-site-api"

# ── Helper functions ──────────────────────────────────────────────────────────
info()    { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
success() { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
fail()    { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

# ── Pre-flight checks ────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    fail "Run as root: sudo -E ./setup-job-dashboard.sh"
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    fail "ANTHROPIC_API_KEY not set."
fi

if [[ -z "${DASHBOARD_PASSWORD:-}" ]]; then
    fail "DASHBOARD_PASSWORD not set. Export it before running."
fi

if [[ ! -d "${API_DIR}" ]]; then
    fail "API directory not found at ${API_DIR}. Run setup-alvin-site.sh first."
fi

if [[ ! -d "${AGENT_DIR}" ]]; then
    fail "Job agent not found at ${AGENT_DIR}. Run setup-job-agent.sh first."
fi

info "Adding job dashboard to existing site..."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: Create the dashboard API extension
# ══════════════════════════════════════════════════════════════════════════════
info "Creating dashboard API module..."
cat > "${API_DIR}/dashboard_api.py" <<'PYEOF'
"""
Dashboard API — extends the main Flask app with job management endpoints.

Endpoints:
  POST /api/dash/login        — authenticate with dashboard password
  GET  /api/dash/jobs         — list all jobs with status & cover letters
  POST /api/dash/status       — update a job's status
  POST /api/dash/cover-letter — generate/regenerate a cover letter for a job
  GET  /api/dash/stats        — summary statistics
"""

import os
import json
import hashlib
import secrets
import logging
from datetime import datetime
from pathlib import Path
from flask import request, jsonify
from anthropic import Anthropic
import PyPDF2

logger = logging.getLogger(__name__)

AGENT_DATA = Path("/opt/job-agent/data")
JOBS_FILE = AGENT_DATA / "dashboard_jobs.json"
RESUME_PATH = "/var/www/alvin-site/alvin.pdf"
MODEL = "claude-sonnet-4-20250514"

# In-memory session tokens for dashboard auth
dash_sessions = set()

# Hashed dashboard password (set during setup)
DASH_PASSWORD_HASH = os.environ.get("DASH_PASSWORD_HASH", "")


def _hash(pw):
    return hashlib.sha256(pw.encode()).hexdigest()


def _check_auth():
    """Verify dashboard session token."""
    token = request.headers.get("X-Dash-Token", "")
    if token not in dash_sessions:
        return False
    return True


def _load_jobs():
    """Load jobs from the dashboard JSON file."""
    if JOBS_FILE.exists():
        try:
            with open(JOBS_FILE) as f:
                return json.load(f)
        except Exception:
            return []
    return []


def _save_jobs(jobs):
    """Save jobs to the dashboard JSON file."""
    JOBS_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(JOBS_FILE, "w") as f:
        json.dump(jobs, f, indent=2)


def _get_resume_text():
    """Extract resume text for cover letter generation."""
    try:
        with open(RESUME_PATH, "rb") as f:
            reader = PyPDF2.PdfReader(f)
            return "\n".join(p.extract_text() or "" for p in reader.pages)
    except Exception as e:
        logger.error(f"Failed to read resume: {e}")
        return ""


def generate_cover_letter(job, resume_text):
    """Use Claude to write a tailored cover letter."""
    try:
        client = Anthropic()
        response = client.messages.create(
            model=MODEL,
            max_tokens=1024,
            system="""You are an expert career coach writing cover letters for a senior IT professional.

Write a concise, professional cover letter (3-4 paragraphs, under 300 words) that:
- Opens with genuine interest in the specific role and company
- Highlights 2-3 relevant accomplishments from the resume that match the job
- Uses confident but not arrogant tone
- Closes with enthusiasm and a call to action
- Does NOT use cliches like "I am writing to express my interest" or "I believe I would be a great fit"
- Sounds human and authentic, not AI-generated
- Addresses the hiring manager (use "Dear Hiring Manager" if no name is given)

Return ONLY the cover letter text, no subject lines or metadata.""",
            messages=[{
                "role": "user",
                "content": f"""Write a cover letter for this job:

POSITION: {job.get('title', 'Unknown')}
COMPANY: {job.get('company', 'Unknown')}
LOCATION: {job.get('location', 'Unknown')}
DESCRIPTION: {job.get('snippet', 'No description available')}

CANDIDATE RESUME:
{resume_text[:3000]}"""
            }]
        )
        return response.content[0].text.strip()
    except Exception as e:
        logger.error(f"Cover letter generation failed: {e}")
        return f"[Cover letter generation failed: {e}]"


def register_dashboard_routes(app):
    """Register all dashboard API routes on the Flask app."""

    @app.route("/api/dash/login", methods=["POST"])
    def dash_login():
        data = request.get_json() or {}
        password = data.get("password", "")
        if _hash(password) == DASH_PASSWORD_HASH:
            token = secrets.token_hex(32)
            dash_sessions.add(token)
            logger.info("Dashboard login successful")
            return jsonify({"success": True, "token": token})
        logger.warning("Dashboard login failed")
        return jsonify({"error": "Invalid password"}), 401

    @app.route("/api/dash/jobs", methods=["GET"])
    def dash_jobs():
        if not _check_auth():
            return jsonify({"error": "Unauthorized"}), 401
        jobs = _load_jobs()
        # Sort: new first, then by score descending
        status_order = {"new": 0, "reviewed": 1, "applied": 2, "rejected": 3}
        jobs.sort(key=lambda j: (status_order.get(j.get("status", "new"), 9), -j.get("score", 0)))
        return jsonify({"jobs": jobs, "total": len(jobs)})

    @app.route("/api/dash/status", methods=["POST"])
    def dash_update_status():
        if not _check_auth():
            return jsonify({"error": "Unauthorized"}), 401
        data = request.get_json() or {}
        job_id = data.get("id", "")
        new_status = data.get("status", "")
        if new_status not in ("new", "reviewed", "applied", "rejected"):
            return jsonify({"error": "Invalid status"}), 400
        jobs = _load_jobs()
        updated = False
        for job in jobs:
            if job.get("id") == job_id:
                job["status"] = new_status
                job["status_updated"] = datetime.now().strftime("%Y-%m-%d %H:%M")
                updated = True
                break
        if updated:
            _save_jobs(jobs)
            logger.info(f"Job {job_id[:8]} status → {new_status}")
            return jsonify({"success": True})
        return jsonify({"error": "Job not found"}), 404

    @app.route("/api/dash/cover-letter", methods=["POST"])
    def dash_cover_letter():
        if not _check_auth():
            return jsonify({"error": "Unauthorized"}), 401
        data = request.get_json() or {}
        job_id = data.get("id", "")
        jobs = _load_jobs()
        target_job = None
        for job in jobs:
            if job.get("id") == job_id:
                target_job = job
                break
        if not target_job:
            return jsonify({"error": "Job not found"}), 404

        resume_text = _get_resume_text()
        if not resume_text:
            return jsonify({"error": "Could not read resume"}), 500

        cover_letter = generate_cover_letter(target_job, resume_text)
        target_job["cover_letter"] = cover_letter
        target_job["cover_letter_date"] = datetime.now().strftime("%Y-%m-%d %H:%M")
        _save_jobs(jobs)

        return jsonify({"success": True, "cover_letter": cover_letter})

    @app.route("/api/dash/stats", methods=["GET"])
    def dash_stats():
        if not _check_auth():
            return jsonify({"error": "Unauthorized"}), 401
        jobs = _load_jobs()
        stats = {
            "total": len(jobs),
            "new": sum(1 for j in jobs if j.get("status", "new") == "new"),
            "reviewed": sum(1 for j in jobs if j.get("status") == "reviewed"),
            "applied": sum(1 for j in jobs if j.get("status") == "applied"),
            "rejected": sum(1 for j in jobs if j.get("status") == "rejected"),
            "avg_score": round(sum(j.get("score", 0) for j in jobs) / max(len(jobs), 1), 1),
            "strong_matches": sum(1 for j in jobs if j.get("score", 0) >= 70),
        }
        return jsonify(stats)

    logger.info("Dashboard API routes registered")
PYEOF

success "Dashboard API module created."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Update the main Flask app to include dashboard routes
# ══════════════════════════════════════════════════════════════════════════════
info "Updating main Flask app to load dashboard module..."

# Add dashboard import and registration to app.py
# We append to the existing app.py before the __main__ block
if grep -q "dashboard_api" "${API_DIR}/app.py"; then
    info "Dashboard already integrated in app.py — skipping."
else
    # Insert before the if __name__ block
    sed -i '/^if __name__ == "__main__":/i \
# ── Dashboard integration ─────────────────────────────────────────────────────\
try:\
    from dashboard_api import register_dashboard_routes\
    register_dashboard_routes(app)\
except Exception as e:\
    logger.warning(f"Dashboard module not loaded: {e}")\
' "${API_DIR}/app.py"
    success "Dashboard routes integrated into main app."
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: Update systemd service with dashboard password hash
# ══════════════════════════════════════════════════════════════════════════════
info "Updating service environment with dashboard password hash..."

PASS_HASH=$(python3 -c "import hashlib; print(hashlib.sha256('${DASHBOARD_PASSWORD}'.encode()).hexdigest())")

# Add DASH_PASSWORD_HASH to the service file
if grep -q "DASH_PASSWORD_HASH" "/etc/systemd/system/${SERVICE_NAME}.service"; then
    sed -i "s|Environment=\"DASH_PASSWORD_HASH=.*\"|Environment=\"DASH_PASSWORD_HASH=${PASS_HASH}\"|" "/etc/systemd/system/${SERVICE_NAME}.service"
else
    sed -i "/Environment=\"ANTHROPIC_API_KEY=/a Environment=\"DASH_PASSWORD_HASH=${PASS_HASH}\"" "/etc/systemd/system/${SERVICE_NAME}.service"
fi

systemctl daemon-reload
success "Service updated with dashboard password."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Update the job agent to feed jobs into the dashboard
# ══════════════════════════════════════════════════════════════════════════════
info "Adding dashboard sync to job agent..."
cat > "${AGENT_DIR}/sync_dashboard.py" <<'PYEOF'
"""
Syncs newly found jobs from the job agent into the dashboard JSON file.
Called by the job agent after scoring. Generates cover letters for top matches.
"""

import json
import os
import sys
import logging
from pathlib import Path
from datetime import datetime

import PyPDF2
from anthropic import Anthropic

AGENT_DATA = Path("/opt/job-agent/data")
DASH_JOBS = AGENT_DATA / "dashboard_jobs.json"
RESUME_PATH = "/var/www/alvin-site/alvin.pdf"
MODEL = "claude-sonnet-4-20250514"
COVER_LETTER_THRESHOLD = 65  # Generate cover letters for jobs scored 65+

logger = logging.getLogger(__name__)

# Load .env
env_file = Path("/opt/job-agent/.env")
if env_file.exists():
    with open(env_file) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


def load_dashboard_jobs():
    if DASH_JOBS.exists():
        try:
            with open(DASH_JOBS) as f:
                return json.load(f)
        except Exception:
            return []
    return []


def save_dashboard_jobs(jobs):
    DASH_JOBS.parent.mkdir(parents=True, exist_ok=True)
    with open(DASH_JOBS, "w") as f:
        json.dump(jobs, f, indent=2)


def get_resume_text():
    try:
        with open(RESUME_PATH, "rb") as f:
            reader = PyPDF2.PdfReader(f)
            return "\n".join(p.extract_text() or "" for p in reader.pages)
    except Exception:
        return ""


def generate_cover_letter(job, resume_text):
    try:
        client = Anthropic()
        resp = client.messages.create(
            model=MODEL,
            max_tokens=1024,
            system="""Write a concise, professional cover letter (3-4 paragraphs, under 300 words).
- Open with genuine interest in the specific role and company
- Highlight 2-3 relevant accomplishments matching the job
- Confident but not arrogant tone
- Close with enthusiasm and call to action
- No cliches like "I am writing to express my interest"
- Sound human and authentic
- Address "Dear Hiring Manager"
Return ONLY the cover letter text.""",
            messages=[{
                "role": "user",
                "content": f"POSITION: {job.get('title')}\nCOMPANY: {job.get('company')}\nLOCATION: {job.get('location')}\nDESCRIPTION: {job.get('snippet', '')}\n\nRESUME:\n{resume_text[:3000]}"
            }]
        )
        return resp.content[0].text.strip()
    except Exception as e:
        return f"[Generation failed: {e}]"


def sync_jobs(new_scored_jobs):
    """Merge newly scored jobs into the dashboard, generate cover letters for top matches."""
    existing = load_dashboard_jobs()
    existing_ids = {j["id"] for j in existing}

    added = 0
    resume_text = ""

    for job in new_scored_jobs:
        if job["id"] not in existing_ids:
            job["status"] = "new"
            job["added_date"] = datetime.now().strftime("%Y-%m-%d %H:%M")
            job["cover_letter"] = ""
            job["cover_letter_date"] = ""

            # Generate cover letter for strong matches
            if job.get("score", 0) >= COVER_LETTER_THRESHOLD:
                if not resume_text:
                    resume_text = get_resume_text()
                if resume_text:
                    job["cover_letter"] = generate_cover_letter(job, resume_text)
                    job["cover_letter_date"] = datetime.now().strftime("%Y-%m-%d %H:%M")

            existing.append(job)
            added += 1

    # Prune jobs older than 30 days with status "rejected" or "new"
    cutoff = datetime.now().strftime("%Y-%m-%d")
    existing = [j for j in existing if j.get("status") in ("reviewed", "applied") or
                j.get("found_date", cutoff) >= (datetime.now().replace(day=1)).strftime("%Y-%m-%d")]

    save_dashboard_jobs(existing)
    logger.info(f"Dashboard sync: {added} new jobs added, {len(existing)} total in dashboard")
    return added


if __name__ == "__main__":
    # Can be called standalone with a JSON file of scored jobs
    logging.basicConfig(level=logging.INFO)
    if len(sys.argv) > 1:
        with open(sys.argv[1]) as f:
            jobs = json.load(f)
        sync_jobs(jobs)
    else:
        print("Usage: sync_dashboard.py <scored_jobs.json>")
PYEOF

# Now patch the job agent to call sync_dashboard after scoring
if grep -q "sync_dashboard" "${AGENT_DIR}/job_agent.py"; then
    info "Job agent already has dashboard sync — skipping."
else
    # Add import at the top (after the existing imports)
    sed -i '/^from anthropic import Anthropic$/a\
try:\
    from sync_dashboard import sync_jobs as sync_to_dashboard\
except ImportError:\
    sync_to_dashboard = None' "${AGENT_DIR}/job_agent.py"

    # Add sync call after scoring (before the email section)
    sed -i '/# 7. Log to CSV/i\
    # 6b. Sync to dashboard\
    if sync_to_dashboard and scored_jobs:\
        try:\
            sync_to_dashboard(scored_jobs)\
        except Exception as e:\
            logger.warning(f"Dashboard sync failed: {e}")\
' "${AGENT_DIR}/job_agent.py"

    success "Job agent updated to sync with dashboard."
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: Create the dashboard HTML page
# ══════════════════════════════════════════════════════════════════════════════
info "Creating dashboard HTML page..."
cat > "${SITE_DIR}/dashboard.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Job Dashboard — Alvin</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link href="https://fonts.googleapis.com/css2?family=Playfair+Display:wght@600;700;800&family=Source+Sans+3:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
    <style>
        *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }
        :root {
            --bg: #f5eede;
            --bg-card: #ffffff;
            --bg-card-alt: #faf8f2;
            --border: #e8e0cc;
            --border-light: #f0ece0;
            --text-black: #1a1a1a;
            --text-dark: #2d2d2d;
            --text-body: #3a3a3a;
            --text-mid: #666;
            --text-muted: #999;
            --accent: #c97b7b;
            --accent-hover: #b56a6a;
            --ocean: #2e6e7e;
            --ocean-light: #3a8a9c;
            --green: #16a34a;
            --green-bg: #f0fdf4;
            --blue: #2563eb;
            --blue-bg: #eff6ff;
            --amber: #d97706;
            --amber-bg: #fffbeb;
            --red: #dc2626;
            --red-bg: #fef2f2;
            --gray-bg: #f5f5f4;
            --font-display: 'Playfair Display', Georgia, serif;
            --font-body: 'Source Sans 3', sans-serif;
            --font-mono: 'JetBrains Mono', monospace;
        }
        body { font-family: var(--font-body); background: var(--bg); color: var(--text-body); min-height: 100vh; }

        /* ── Login Screen ── */
        .login-screen {
            min-height: 100vh; display: flex; align-items: center; justify-content: center;
            background: linear-gradient(180deg, #2c3e6b 0%, #4a5d8a 30%, #7b6e8e 50%, #c97b7b 65%, #e8a87c 80%, #ede0c8 100%);
        }
        .login-card {
            background: rgba(255,255,255,0.95); border-radius: 16px; padding: 2.5rem 2rem;
            width: 100%; max-width: 380px; box-shadow: 0 10px 40px rgba(0,0,0,0.15);
        }
        .login-card h1 { font-family: var(--font-display); font-size: 1.6rem; color: var(--text-black); margin-bottom: 0.3rem; }
        .login-card p { font-size: 0.88rem; color: var(--text-mid); margin-bottom: 1.5rem; }
        .login-card input {
            width: 100%; padding: 0.7rem 1rem; border: 1px solid var(--border); border-radius: 8px;
            font-family: var(--font-body); font-size: 0.9rem; outline: none; margin-bottom: 1rem;
        }
        .login-card input:focus { border-color: var(--accent); }
        .login-card button {
            width: 100%; padding: 0.75rem; background: var(--accent); color: #fff; border: none;
            border-radius: 8px; font-weight: 700; font-size: 0.9rem; cursor: pointer;
            font-family: var(--font-body); transition: background 0.2s;
        }
        .login-card button:hover { background: var(--accent-hover); }
        .login-error { color: var(--red); font-size: 0.85rem; margin-top: 0.5rem; display: none; }
        .login-error.show { display: block; }

        /* ── Dashboard ── */
        .dashboard { display: none; }
        .dashboard.active { display: block; }

        .dash-header {
            background: var(--bg-card); border-bottom: 1px solid var(--border);
            padding: 1rem 2rem; display: flex; align-items: center; gap: 1rem;
            position: sticky; top: 0; z-index: 100;
        }
        .dash-header h1 { font-family: var(--font-display); font-size: 1.3rem; color: var(--text-black); }
        .dash-header .back-link { font-size: 0.82rem; color: var(--ocean); text-decoration: none; margin-left: auto; }
        .dash-header .back-link:hover { text-decoration: underline; }

        .dash-body { max-width: 1100px; margin: 0 auto; padding: 1.5rem; }

        /* ── Stat cards ── */
        .stat-row { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 0.75rem; margin-bottom: 1.5rem; }
        .stat-card {
            background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px;
            padding: 1rem; text-align: center;
        }
        .stat-card .val { font-family: var(--font-display); font-size: 1.8rem; font-weight: 800; color: var(--ocean); }
        .stat-card .lbl { font-size: 0.7rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: 1px; margin-top: 2px; }
        .stat-card.highlight .val { color: var(--green); }

        /* ── Filter tabs ── */
        .filter-bar {
            display: flex; gap: 0.4rem; margin-bottom: 1rem; flex-wrap: wrap;
        }
        .filter-btn {
            padding: 0.4rem 0.9rem; border-radius: 999px; font-size: 0.78rem; font-weight: 600;
            border: 1px solid var(--border); background: var(--bg-card); color: var(--text-mid);
            cursor: pointer; transition: all 0.15s; font-family: var(--font-body);
        }
        .filter-btn:hover { border-color: var(--accent); color: var(--accent); }
        .filter-btn.active { background: var(--ocean); border-color: var(--ocean); color: #fff; }

        /* ── Job cards ── */
        .job-list { display: flex; flex-direction: column; gap: 0.75rem; }
        .job-card {
            background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px;
            padding: 1.2rem 1.4rem; transition: box-shadow 0.2s;
        }
        .job-card:hover { box-shadow: 0 4px 16px rgba(0,0,0,0.06); }
        .job-card-top { display: flex; align-items: flex-start; gap: 1rem; }
        .job-card-main { flex: 1; }
        .job-title { font-size: 1rem; font-weight: 700; color: var(--text-black); margin-bottom: 2px; }
        .job-meta { font-size: 0.82rem; color: var(--text-mid); }
        .job-meta span { margin-right: 8px; }
        .job-reason { font-size: 0.82rem; color: var(--ocean); margin-top: 4px; font-style: italic; }

        .job-score {
            display: flex; flex-direction: column; align-items: center; min-width: 54px;
        }
        .score-badge {
            width: 44px; height: 44px; border-radius: 50%; display: flex; align-items: center;
            justify-content: center; font-size: 0.85rem; font-weight: 700; color: #fff;
        }
        .score-badge.excellent { background: var(--green); }
        .score-badge.good { background: var(--blue); }
        .score-badge.fair { background: var(--amber); }
        .score-badge.low { background: #9ca3af; }
        .score-label { font-size: 0.65rem; color: var(--text-muted); margin-top: 2px; text-transform: uppercase; letter-spacing: 0.5px; }

        /* ── Job actions ── */
        .job-actions {
            display: flex; gap: 0.5rem; margin-top: 0.8rem; flex-wrap: wrap; align-items: center;
        }
        .action-btn {
            padding: 0.35rem 0.8rem; border-radius: 6px; font-size: 0.78rem; font-weight: 600;
            border: 1px solid; cursor: pointer; transition: all 0.15s;
            font-family: var(--font-body); background: transparent;
        }
        .action-btn.apply { border-color: var(--green); color: var(--green); }
        .action-btn.apply:hover { background: var(--green); color: #fff; }
        .action-btn.reject { border-color: var(--red); color: var(--red); }
        .action-btn.reject:hover { background: var(--red); color: #fff; }
        .action-btn.cover { border-color: var(--ocean); color: var(--ocean); }
        .action-btn.cover:hover { background: var(--ocean); color: #fff; }
        .action-btn.view { border-color: var(--text-mid); color: var(--text-mid); }
        .action-btn.view:hover { background: var(--text-mid); color: #fff; }
        .action-btn:disabled { opacity: 0.4; cursor: not-allowed; }

        .status-badge {
            padding: 0.25rem 0.6rem; border-radius: 999px; font-size: 0.7rem;
            font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px;
        }
        .status-badge.new { background: var(--blue-bg); color: var(--blue); }
        .status-badge.reviewed { background: var(--amber-bg); color: var(--amber); }
        .status-badge.applied { background: var(--green-bg); color: var(--green); }
        .status-badge.rejected { background: var(--red-bg); color: var(--red); }

        /* ── Cover letter modal ── */
        .modal-overlay {
            display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.4);
            z-index: 200; align-items: center; justify-content: center; padding: 1rem;
        }
        .modal-overlay.show { display: flex; }
        .modal {
            background: var(--bg-card); border-radius: 16px; width: 100%; max-width: 640px;
            max-height: 85vh; overflow-y: auto; box-shadow: 0 20px 60px rgba(0,0,0,0.2);
        }
        .modal-header {
            padding: 1.2rem 1.5rem; border-bottom: 1px solid var(--border);
            display: flex; align-items: center; gap: 1rem;
        }
        .modal-header h2 { font-size: 1rem; font-weight: 700; color: var(--text-black); flex: 1; }
        .modal-close {
            width: 30px; height: 30px; border-radius: 50%; border: 1px solid var(--border);
            background: var(--bg); cursor: pointer; font-size: 1rem; color: var(--text-mid);
            display: flex; align-items: center; justify-content: center; transition: all 0.15s;
        }
        .modal-close:hover { background: var(--red-bg); border-color: var(--red); color: var(--red); }
        .modal-body { padding: 1.5rem; }
        .modal-body .cover-text {
            font-size: 0.92rem; line-height: 1.75; color: var(--text-body); white-space: pre-wrap;
            background: var(--bg-card-alt); border: 1px solid var(--border-light);
            border-radius: 8px; padding: 1.2rem; margin-bottom: 1rem;
        }
        .modal-actions { display: flex; gap: 0.5rem; flex-wrap: wrap; }
        .modal-actions button {
            padding: 0.5rem 1rem; border-radius: 8px; font-size: 0.85rem; font-weight: 600;
            cursor: pointer; font-family: var(--font-body); border: none; transition: all 0.15s;
        }
        .btn-copy { background: var(--ocean); color: #fff; }
        .btn-copy:hover { background: var(--ocean-light); }
        .btn-regen { background: var(--bg); border: 1px solid var(--border); color: var(--text-mid); }
        .btn-regen:hover { border-color: var(--ocean); color: var(--ocean); }
        .btn-apply-link { background: var(--green); color: #fff; text-decoration: none; display: inline-block; }
        .btn-apply-link:hover { filter: brightness(1.1); }

        .loading-spinner {
            display: inline-block; width: 16px; height: 16px; border: 2px solid var(--border);
            border-top-color: var(--ocean); border-radius: 50%; animation: spin 0.8s linear infinite;
        }
        @keyframes spin { to { transform: rotate(360deg); } }

        .empty-state {
            text-align: center; padding: 3rem 1.5rem; color: var(--text-muted);
        }
        .empty-state p { font-size: 0.95rem; margin-top: 0.5rem; }

        @media (max-width: 600px) {
            .dash-body { padding: 1rem; }
            .stat-row { grid-template-columns: repeat(2, 1fr); }
            .job-card-top { flex-direction: column; gap: 0.5rem; }
            .dash-header { padding: 0.8rem 1rem; }
        }
    </style>
</head>
<body>

    <!-- ── Login ── -->
    <div class="login-screen" id="loginScreen">
        <div class="login-card">
            <h1>Job Dashboard</h1>
            <p>Enter your password to access the dashboard.</p>
            <input type="password" id="loginPass" placeholder="Dashboard password" autofocus>
            <button onclick="doLogin()">Sign In</button>
            <div class="login-error" id="loginError">Invalid password. Try again.</div>
        </div>
    </div>

    <!-- ── Dashboard ── -->
    <div class="dashboard" id="dashApp">
        <header class="dash-header">
            <h1>Job Dashboard</h1>
            <a href="/" class="back-link">&larr; Back to portfolio</a>
        </header>

        <div class="dash-body">
            <!-- Stats -->
            <div class="stat-row" id="statsRow">
                <div class="stat-card"><div class="val" id="statTotal">-</div><div class="lbl">Total jobs</div></div>
                <div class="stat-card"><div class="val" id="statNew">-</div><div class="lbl">New</div></div>
                <div class="stat-card highlight"><div class="val" id="statStrong">-</div><div class="lbl">Strong</div></div>
                <div class="stat-card"><div class="val" id="statApplied">-</div><div class="lbl">Applied</div></div>
                <div class="stat-card"><div class="val" id="statAvg">-</div><div class="lbl">Avg score</div></div>
            </div>

            <!-- Filters -->
            <div class="filter-bar">
                <button class="filter-btn active" data-filter="all" onclick="setFilter('all', this)">All</button>
                <button class="filter-btn" data-filter="new" onclick="setFilter('new', this)">New</button>
                <button class="filter-btn" data-filter="reviewed" onclick="setFilter('reviewed', this)">Reviewed</button>
                <button class="filter-btn" data-filter="applied" onclick="setFilter('applied', this)">Applied</button>
                <button class="filter-btn" data-filter="rejected" onclick="setFilter('rejected', this)">Rejected</button>
            </div>

            <!-- Job list -->
            <div class="job-list" id="jobList">
                <div class="empty-state"><p>Loading jobs...</p></div>
            </div>
        </div>
    </div>

    <!-- ── Cover Letter Modal ── -->
    <div class="modal-overlay" id="coverModal">
        <div class="modal">
            <div class="modal-header">
                <h2 id="modalTitle">Cover Letter</h2>
                <button class="modal-close" onclick="closeModal()">&times;</button>
            </div>
            <div class="modal-body">
                <div class="cover-text" id="coverText">Loading...</div>
                <div class="modal-actions">
                    <button class="btn-copy" onclick="copyCover()">Copy to clipboard</button>
                    <button class="btn-regen" id="regenBtn" onclick="regenCover()">Regenerate</button>
                    <a class="btn-apply-link" id="modalApplyLink" href="#" target="_blank">Open job listing &#8599;</a>
                </div>
            </div>
        </div>
    </div>

    <script>
        let token = '';
        let allJobs = [];
        let currentFilter = 'all';
        let currentModalJobId = '';

        // ── Auth ──
        document.getElementById('loginPass').addEventListener('keydown', e => {
            if (e.key === 'Enter') doLogin();
        });

        async function doLogin() {
            const pw = document.getElementById('loginPass').value;
            try {
                const res = await fetch('/api/dash/login', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ password: pw })
                });
                const data = await res.json();
                if (data.success) {
                    token = data.token;
                    document.getElementById('loginScreen').style.display = 'none';
                    document.getElementById('dashApp').classList.add('active');
                    loadDashboard();
                } else {
                    document.getElementById('loginError').classList.add('show');
                }
            } catch {
                document.getElementById('loginError').textContent = 'Server error.';
                document.getElementById('loginError').classList.add('show');
            }
        }

        function authHeaders() {
            return { 'Content-Type': 'application/json', 'X-Dash-Token': token };
        }

        // ── Load dashboard ──
        async function loadDashboard() {
            await Promise.all([loadStats(), loadJobs()]);
        }

        async function loadStats() {
            try {
                const res = await fetch('/api/dash/stats', { headers: authHeaders() });
                const s = await res.json();
                document.getElementById('statTotal').textContent = s.total || 0;
                document.getElementById('statNew').textContent = s.new || 0;
                document.getElementById('statStrong').textContent = s.strong_matches || 0;
                document.getElementById('statApplied').textContent = s.applied || 0;
                document.getElementById('statAvg').textContent = s.avg_score || 0;
            } catch {}
        }

        async function loadJobs() {
            try {
                const res = await fetch('/api/dash/jobs', { headers: authHeaders() });
                const data = await res.json();
                allJobs = data.jobs || [];
                renderJobs();
            } catch {
                document.getElementById('jobList').innerHTML = '<div class="empty-state"><p>Failed to load jobs.</p></div>';
            }
        }

        // ── Filters ──
        function setFilter(f, btn) {
            currentFilter = f;
            document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            renderJobs();
        }

        // ── Render ──
        function scoreClass(s) {
            if (s >= 85) return 'excellent';
            if (s >= 70) return 'good';
            if (s >= 50) return 'fair';
            return 'low';
        }
        function scoreLabel(s) {
            if (s >= 85) return 'Excellent';
            if (s >= 70) return 'Good';
            if (s >= 50) return 'Fair';
            return 'Low';
        }

        function renderJobs() {
            const list = document.getElementById('jobList');
            let filtered = allJobs;
            if (currentFilter !== 'all') {
                filtered = allJobs.filter(j => (j.status || 'new') === currentFilter);
            }
            if (!filtered.length) {
                list.innerHTML = '<div class="empty-state"><p>No jobs match this filter.</p></div>';
                return;
            }
            list.innerHTML = filtered.map(job => {
                const s = job.score || 0;
                const st = job.status || 'new';
                const hasCover = !!job.cover_letter;
                return `
                <div class="job-card" id="card-${job.id}">
                    <div class="job-card-top">
                        <div class="job-card-main">
                            <div class="job-title">${esc(job.title)}</div>
                            <div class="job-meta">
                                <span>${esc(job.company)}</span>
                                <span>${esc(job.location)}</span>
                                <span>${esc(job.source)}</span>
                                <span>${esc(job.found_date || '')}</span>
                            </div>
                            ${job.reason ? `<div class="job-reason">${esc(job.reason)}</div>` : ''}
                        </div>
                        <div class="job-score">
                            <div class="score-badge ${scoreClass(s)}">${s}</div>
                            <div class="score-label">${scoreLabel(s)}</div>
                        </div>
                    </div>
                    <div class="job-actions">
                        <span class="status-badge ${st}">${st}</span>
                        ${job.url ? `<a class="action-btn view" href="${esc(job.url)}" target="_blank">View listing</a>` : ''}
                        <button class="action-btn cover" onclick="openCoverLetter('${job.id}')">${hasCover ? 'View' : 'Generate'} cover letter</button>
                        ${st !== 'applied' ? `<button class="action-btn apply" onclick="setStatus('${job.id}','applied')">Mark applied</button>` : ''}
                        ${st !== 'rejected' ? `<button class="action-btn reject" onclick="setStatus('${job.id}','rejected')">Reject</button>` : ''}
                        ${st === 'rejected' || st === 'applied' ? `<button class="action-btn view" onclick="setStatus('${job.id}','new')">Reset</button>` : ''}
                    </div>
                </div>`;
            }).join('');
        }

        function esc(s) {
            const d = document.createElement('div');
            d.textContent = s || '';
            return d.innerHTML;
        }

        // ── Actions ──
        async function setStatus(jobId, status) {
            try {
                await fetch('/api/dash/status', {
                    method: 'POST',
                    headers: authHeaders(),
                    body: JSON.stringify({ id: jobId, status })
                });
                const job = allJobs.find(j => j.id === jobId);
                if (job) job.status = status;
                renderJobs();
                loadStats();
            } catch {}
        }

        async function openCoverLetter(jobId) {
            currentModalJobId = jobId;
            const job = allJobs.find(j => j.id === jobId);
            if (!job) return;

            document.getElementById('modalTitle').textContent = `Cover Letter — ${job.title}`;
            document.getElementById('modalApplyLink').href = job.url || '#';
            document.getElementById('coverModal').classList.add('show');

            if (job.cover_letter) {
                document.getElementById('coverText').textContent = job.cover_letter;
            } else {
                document.getElementById('coverText').innerHTML = '<div class="loading-spinner"></div> Generating cover letter with AI...';
                await generateCoverLetter(jobId);
            }

            // Mark as reviewed if new
            if ((job.status || 'new') === 'new') {
                setStatus(jobId, 'reviewed');
            }
        }

        async function generateCoverLetter(jobId) {
            try {
                const res = await fetch('/api/dash/cover-letter', {
                    method: 'POST',
                    headers: authHeaders(),
                    body: JSON.stringify({ id: jobId })
                });
                const data = await res.json();
                if (data.cover_letter) {
                    document.getElementById('coverText').textContent = data.cover_letter;
                    const job = allJobs.find(j => j.id === jobId);
                    if (job) job.cover_letter = data.cover_letter;
                } else {
                    document.getElementById('coverText').textContent = 'Failed to generate cover letter. Try again.';
                }
            } catch {
                document.getElementById('coverText').textContent = 'Server error. Try again.';
            }
        }

        async function regenCover() {
            if (!currentModalJobId) return;
            document.getElementById('regenBtn').disabled = true;
            document.getElementById('regenBtn').innerHTML = '<span class="loading-spinner"></span>';
            document.getElementById('coverText').innerHTML = '<div class="loading-spinner"></div> Regenerating...';
            await generateCoverLetter(currentModalJobId);
            document.getElementById('regenBtn').disabled = false;
            document.getElementById('regenBtn').textContent = 'Regenerate';
        }

        function copyCover() {
            const text = document.getElementById('coverText').textContent;
            navigator.clipboard.writeText(text).then(() => {
                const btn = document.querySelector('.btn-copy');
                btn.textContent = 'Copied!';
                setTimeout(() => btn.textContent = 'Copy to clipboard', 2000);
            });
        }

        function closeModal() {
            document.getElementById('coverModal').classList.remove('show');
            currentModalJobId = '';
        }

        // Close modal on overlay click
        document.getElementById('coverModal').addEventListener('click', e => {
            if (e.target === document.getElementById('coverModal')) closeModal();
        });

        // ESC to close
        document.addEventListener('keydown', e => {
            if (e.key === 'Escape') closeModal();
        });
    </script>
</body>
</html>
HTMLEOF

success "Dashboard HTML page created."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6: Set permissions and restart services
# ══════════════════════════════════════════════════════════════════════════════
info "Setting permissions..."
chown -R www-data:www-data "${SITE_DIR}"
chown -R www-data:www-data "${API_DIR}"
chown -R www-data:www-data "${AGENT_DIR}"
chmod 755 "${SITE_DIR}/dashboard.html"

info "Restarting Flask API service..."
systemctl restart "${SERVICE_NAME}"
success "Service restarted."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7: Smoke test
# ══════════════════════════════════════════════════════════════════════════════
info "Waiting for service to stabilize..."
sleep 2

info "Testing dashboard page..."
DASH_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/dashboard.html)
if [[ "${DASH_CODE}" == "200" ]]; then
    success "Dashboard page — HTTP 200 OK!"
else
    warn "Dashboard page returned HTTP ${DASH_CODE}."
fi

info "Testing dashboard login API..."
LOGIN_RESULT=$(curl -s -X POST http://localhost/api/dash/login \
    -H "Content-Type: application/json" \
    -d "{\"password\":\"${DASHBOARD_PASSWORD}\"}" 2>/dev/null)
if echo "${LOGIN_RESULT}" | grep -q '"success"'; then
    success "Dashboard login API works!"
else
    warn "Dashboard login test result: ${LOGIN_RESULT}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# DONE
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "================================================================"
echo "  JOB DASHBOARD SETUP COMPLETE"
echo "================================================================"
echo ""
echo "  Dashboard URL:  http://localhost/dashboard.html"
echo "  Password:       (the one you set in DASHBOARD_PASSWORD)"
echo ""
echo "  How it works:"
echo "    1. Job agent runs daily at 7:00 AM"
echo "    2. New jobs are scored + cover letters auto-generated (65+)"
echo "    3. Visit the dashboard to review matches"
echo "    4. Click 'View cover letter' to see AI-written letter"
echo "    5. Copy the letter, click 'View listing', and apply"
echo "    6. Mark as 'Applied' or 'Reject' to track progress"
echo ""
echo "  To populate with test data, run the agent now:"
echo "      sudo -u www-data /opt/job-agent/run_agent.sh"
echo "      tail -f /var/log/job-agent.log"
echo ""
echo "  Dashboard API endpoints:"
echo "      POST /api/dash/login"
echo "      GET  /api/dash/jobs"
echo "      POST /api/dash/status"
echo "      POST /api/dash/cover-letter"
echo "      GET  /api/dash/stats"
echo "================================================================"
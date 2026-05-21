# AI Websites

A collection of Claude-powered web tools deployed on Debian with Apache + Flask + systemd.

---

## Scripts

| Script | Description |
|--------|-------------|
| `setup-alvin-site.sh` | Portfolio site for Alvin with Claude-powered resume chatbot |
| `run_agent.sh` | Job dashboard add-on for the Alvin site |
| `setup-okta-agent-site.sh` | Web UI for the Okta User Management Agent |
| `okta_agent.py` | Standalone CLI version of the Okta agent |

---

## Okta User Management Agent

Natural-language interface to the Okta API — type a request like:

> "Add Abe Ramo with email wof@theflux.net to the TheFlux group"

Claude parses the intent, calls the Okta API in the correct sequence (create user → find group → add to group), and returns a summary with each step's result.

### Prerequisites

- Debian 11+ with root/sudo
- An Okta org and an SSWS API token
- An Anthropic API key

### Deploy the website

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
export OKTA_API_TOKEN="your-okta-ssws-token"
export OKTA_DOMAIN="integrator-2383045.okta.com"

chmod +x setup-okta-agent-site.sh
sudo -E ./setup-okta-agent-site.sh
```

The script installs all dependencies, creates the Flask backend, configures Apache as a reverse proxy, and starts a systemd service. When it finishes, the site is live at `http://localhost`.

### What gets deployed

| Component | Location |
|-----------|----------|
| HTML frontend | `/var/www/okta-agent-site/` |
| Flask API | `/opt/okta-agent-site-api/app.py` |
| Systemd service | `okta-agent-site-api` (port 5001) |
| Apache vhost | Port 80 → proxies `/api/*` to Flask |

### API

```bash
# Run an agent request
curl -s -X POST http://localhost/api/okta \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "Add Abe Ramo with email wof@theflux.net to TheFlux group"}'

# Health check
curl http://localhost/api/health
```

Response shape:
```json
{
  "steps": [
    { "tool": "create_okta_user",       "input": {...}, "result": {"status_code": 200, "body": {...}} },
    { "tool": "find_okta_group",        "input": {...}, "result": {"status_code": 200, "body": {...}} },
    { "tool": "add_user_to_okta_group", "input": {...}, "result": {"status_code": 204, "success": true} }
  ],
  "summary": "User Abe Ramo was created and added to the TheFlux group successfully."
}
```

### How the agent works

Claude drives an agentic tool-use loop with four tools:

| Tool | Okta API call |
|------|---------------|
| `create_okta_user` | `POST /api/v1/users?activate=true` |
| `find_okta_user` | `GET /api/v1/users/{email}` — fallback on HTTP 409 |
| `find_okta_group` | `GET /api/v1/groups?search=profile.name eq "..."` |
| `add_user_to_okta_group` | `PUT /api/v1/groups/{groupId}/users/{userId}` |

Claude handles sequencing and error recovery (e.g. if the user already exists it looks them up rather than failing).

### Use the CLI instead

```bash
pip install anthropic requests

export ANTHROPIC_API_KEY="sk-ant-..."
export OKTA_API_TOKEN="your-token"
export OKTA_DOMAIN="integrator-2383045.okta.com"

python3 okta_agent.py "Add Abe Ramo with email wof@theflux.net to TheFlux group"
# or interactive:
python3 okta_agent.py
```

### Useful commands

```bash
# View live API logs
sudo journalctl -u okta-agent-site-api -f

# Restart the API
sudo systemctl restart okta-agent-site-api

# Restart Apache
sudo systemctl restart apache2
```

### Coexistence with the Alvin site

The Okta agent API runs on port **5001**; the Alvin resume chatbot API runs on port **5000**. Both can be deployed on the same machine without conflict.

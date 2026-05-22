# Okta Agent — Docker Deployment

Deploys the Okta User Management Agent as a Docker container via a GitHub Actions workflow running on a self-hosted runner.

---

## How it works

Every push to `main` triggers the workflow on the self-hosted runner. The runner builds the Docker image locally, stops the old container, and starts a fresh one with secrets injected as environment variables. No external registry is used.

```
push to main
     │
     ▼
GitHub Actions (self-hosted runner)
     │
     ├── docker build -t okta-agent:latest .
     ├── docker rm -f okta-agent
     ├── docker run -d -p 80:80 --env secrets ...
     └── curl http://localhost/api/health  ✓
```

Inside the container, **supervisord** manages two processes:

| Process | Command | Port |
|---------|---------|------|
| Apache2 | `apache2ctl -D FOREGROUND` | 80 (public) |
| Flask   | `python app.py` | 5001 (internal) |

Apache serves the static HTML frontend and reverse-proxies `/api/*` to the Flask backend on port 5001.

---

## Prerequisites

### On the runner server

- Docker installed and running
- GitHub Actions self-hosted runner registered to this repo
- Runner user in the `docker` group (so it can run Docker without sudo):

```bash
sudo usermod -aG docker <runner-user>
# log out and back in for the group change to take effect
```

### In the GitHub repository

Add three secrets under **Settings → Secrets and variables → Actions → New repository secret**:

| Secret name | Value |
|-------------|-------|
| `ANTHROPIC_API_KEY` | Your Anthropic API key (`sk-ant-...`) |
| `OKTA_API_TOKEN` | Your Okta SSWS API token |
| `OKTA_DOMAIN` | Your Okta domain (e.g. `yourorg.okta.com`) |

---

## Repository layout

```
.
├── Dockerfile                        # Full-stack image (Apache + Flask)
├── docker/
│   ├── app.py                        # Flask API — Okta agent backend
│   ├── index.html                    # HTML frontend
│   ├── vhost.conf                    # Apache virtual host config
│   └── supervisor.conf               # supervisord process config
└── .github/
    └── workflows/
        └── deploy.yml                # CI/CD workflow
```

---

## Triggering a deploy

**Automatic** — push or merge to `main`.

**Manual** — go to **Actions → Deploy Okta Agent → Run workflow**.

---

## Verifying the deployment

After the workflow completes, the health endpoint should return `{"status": "ok"}`:

```bash
curl http://<your-server>/api/health
```

Test the agent:

```bash
curl -s -X POST http://<your-server>/api/okta \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "Add Abe Ramo with email wof@theflux.net to TheFlux group"}'
```

---

## Container management

```bash
# View logs
docker logs okta-agent -f

# Restart the container
docker restart okta-agent

# Stop the container
docker stop okta-agent

# Inspect running processes inside the container
docker exec okta-agent supervisorctl status
```

---

## Updating the application

Edit any file under `docker/` (or the `Dockerfile`) and push to `main`. The workflow rebuilds the image from scratch and replaces the running container automatically.

---

## Ports

| Port | Bound to | Description |
|------|----------|-------------|
| 80   | `0.0.0.0:80` | Apache — serves the UI and proxies API calls |
| 5001 | `127.0.0.1` (container-internal) | Flask — not exposed outside the container |

If port 80 is already in use on the server (e.g. by another service), change the mapping in the workflow:

```yaml
# .github/workflows/deploy.yml — Start container step
-p 8080:80 \   # host port 8080 → container port 80
```

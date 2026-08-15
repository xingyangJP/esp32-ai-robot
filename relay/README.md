# RobotBrain cloud relay

Opaque WebSocket relay for **remote operation** (REMOTE.md). Pairs a phone and a
home bridge that sign in as the **same Firebase user** (uid = room) and forwards
messages (commands / JSON / JPEG) between them. It never interprets `CMD_*`.

```
iPhone ⇄WSS⇄  [ this relay, Cloud Run ]  ⇄WSS⇄ home bridge ⇄LAN TCP⇄ car
```

## Local test (no cloud, no Firebase)
```bash
python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt
AUTH_DISABLED=1 PORT=8080 python server.py        # auth off; room = hello.room
# then run relay/smoketest.py in another shell to verify forwarding
```

## Deploy to Cloud Run (project YOUR-GCP-PROJECT, Tokyo)
⚠️ Deploys to **your** GCP project (billing + public endpoint). Do this deliberately.
```bash
gcloud config set account you@example.com
gcloud config set project YOUR-GCP-PROJECT
gcloud run deploy robot-relay \
  --source . \
  --region asia-northeast1 \
  --allow-unauthenticated \          # app-level Firebase auth gates it (not IAM)
  --max-instances 1 \
  --min-instances 0 \
  --timeout 3600 \
  --cpu 1 --memory 256Mi
```
- `--allow-unauthenticated` = reachable without GCP IAM; **security is enforced in-app** via
  the Firebase ID token in the WS hello (`AUTH_DISABLED` unset in prod → tokens verified).
- The relay uses Cloud Run's default service account to verify Firebase ID tokens
  (project auto-detected). Enable **Firebase Authentication** on `YOUR-GCP-PROJECT` and a
  sign-in provider (Apple / email) first.
- Note the deployed URL, e.g. `wss://robot-relay-XXXX.a.run.app` — the app and bridge use it.

## Files
- `server.py` — the relay (auth + uid pairing + opaque forward).
- `Dockerfile`, `requirements.txt` — Cloud Run build (`--source .` uses them).
- `smoketest.py` — local forwarding test (run against `AUTH_DISABLED=1`).

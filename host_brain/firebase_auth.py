"""
firebase_auth.py — the home bridge's Firebase identity for REMOTE mode.

The Cloud Run relay pairs the phone and the bridge by the SAME Firebase uid
(room = verified uid). The phone signs in with Apple; the bridge can't do an
interactive Apple flow, so it authenticates as the SAME uid via a service-account
CUSTOM TOKEN, then exchanges it for a Firebase ID token (Identity Toolkit REST).

Tokens last ~1h; BridgeAuth caches and re-mints ~1 min before expiry. Custom-token
creation is a local RS256 signature with the SA key (no network); only the exchange
is one HTTPS call. See REMOTE.md §4.

Config ([remote] in config.toml):
  auth            = "firebase"
  owner_uid       = "<the phone user's Firebase uid, shown in the app after sign-in>"
  service_account = "service-account.json"   # bridge SA key (git-ignored)
  api_key         = "<a Firebase Web API key for the token exchange>"
"""
import json
import time
import urllib.request

import firebase_admin
from firebase_admin import auth as fb_auth
from firebase_admin import credentials

_EXCHANGE_URL = "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key={key}"


class BridgeAuth:
    def __init__(self, service_account: str, owner_uid: str, api_key: str):
        if not owner_uid:
            raise ValueError("remote.owner_uid is empty — set it to the uid the app "
                             "shows after Sign in with Apple.")
        if not api_key:
            raise ValueError("remote.api_key is empty — set a Firebase Web API key.")
        if not firebase_admin._apps:
            firebase_admin.initialize_app(credentials.Certificate(service_account))
        self.owner_uid = owner_uid
        self.api_key = api_key
        self._id_token = ""
        self._expires_at = 0.0

    def _exchange(self, custom_token) -> None:
        if isinstance(custom_token, bytes):
            custom_token = custom_token.decode("utf-8")
        body = json.dumps({"token": custom_token, "returnSecureToken": True}).encode()
        req = urllib.request.Request(
            _EXCHANGE_URL.format(key=self.api_key),
            data=body, headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
        self._id_token = data["idToken"]
        # refresh a minute early so a hello never carries an about-to-expire token
        self._expires_at = time.time() + int(data.get("expiresIn", "3600")) - 60

    def id_token(self) -> str:
        """Return a valid Firebase ID token for uid=owner_uid (blocking; call off
        the event loop). Cached until ~1 min before expiry."""
        if self._id_token and time.time() < self._expires_at:
            return self._id_token
        custom = fb_auth.create_custom_token(self.owner_uid)
        self._exchange(custom)
        return self._id_token

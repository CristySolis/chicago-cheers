"""Supabase implementations of the service's ports, over Supabase's REST APIs.

The only module that knows Supabase exists. A Google Cloud move replaces this
file with Cloud Storage and Firebase Auth equivalents.

Deliberately plain HTTP rather than Supabase's own Python client: the calls
are few, and each is a documented endpoint whose behaviour was checked against
a running stack.
"""

import httpx

from cheers.ports import Session


class SupabaseRecordingStore:

    def __init__(
        self, base_url: str, service_key: str, bucket: str, http: httpx.Client
    ):
        self._storage = f"{base_url.rstrip('/')}/storage/v1"
        self._bucket = bucket
        self._http = http
        self._headers = {
            "Authorization": f"Bearer {service_key}",
            "apikey": service_key,
        }

    def upload_url(self, path: str) -> str:
        # The token Supabase returns is scoped to this one path and signed with
        # upsert off, so a second upload is refused rather than replacing the
        # first.
        response = self._http.post(
            f"{self._storage}/object/upload/sign/{self._bucket}/{path}",
            headers=self._headers,
        )
        response.raise_for_status()
        return f"{self._storage}{response.json()['url']}"

    def exists(self, path: str) -> bool:
        # A missing object answers 400 here, not 404, so anything but success
        # counts as absent.
        response = self._http.get(
            f"{self._storage}/object/info/{self._bucket}/{path}",
            headers=self._headers,
        )
        return response.status_code == 200

    def download_url(self, path: str) -> str:
        response = self._http.post(
            f"{self._storage}/object/sign/{self._bucket}/{path}",
            headers=self._headers,
            json={"expiresIn": 3600},
        )
        response.raise_for_status()
        return f"{self._storage}{response.json()['signedURL']}"


class SupabaseIdentityVerifier:

    def __init__(self, base_url: str, anon_key: str, http: httpx.Client):
        self._user_endpoint = f"{base_url.rstrip('/')}/auth/v1/user"
        self._anon_key = anon_key
        self._http = http

    def runner_id(self, token: str) -> str | None:
        # Asking Supabase whose token this is, rather than checking the
        # signature locally, keeps this correct whichever signing keys the
        # project uses — at the cost of one request, which at this scale is
        # nothing.
        response = self._http.get(
            self._user_endpoint,
            headers={"Authorization": f"Bearer {token}", "apikey": self._anon_key},
        )
        if response.status_code != 200:
            return None
        runner = response.json().get("id")
        return runner if isinstance(runner, str) else None


class SupabaseRunnerSignIn:

    def __init__(self, base_url: str, anon_key: str, http: httpx.Client):
        self._token_endpoint = f"{base_url.rstrip('/')}/auth/v1/token"
        self._anon_key = anon_key
        self._http = http

    def sign_in(self, email: str, password: str) -> Session | None:
        # A wrong password answers 400 invalid_credentials, which is an
        # expected outcome here rather than a failure.
        return self._session("password", {"email": email, "password": password})

    def refresh(self, refresh_token: str) -> Session | None:
        return self._session("refresh_token", {"refresh_token": refresh_token})

    def _session(self, grant_type: str, body: dict[str, str]) -> Session | None:
        response = self._http.post(
            self._token_endpoint,
            params={"grant_type": grant_type},
            headers={"apikey": self._anon_key},
            json=body,
        )
        if response.status_code != 200:
            return None
        data = response.json()
        return Session(
            access_token=str(data["access_token"]),
            refresh_token=str(data["refresh_token"]),
            expires_in=int(data["expires_in"]),
        )

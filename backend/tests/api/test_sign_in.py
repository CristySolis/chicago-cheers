"""The runner signs in on her phone through the API, which checks with the login
provider on her behalf. The phone never talks to the provider itself."""

import uuid

import httpx
from fastapi.testclient import TestClient

from .conftest import ADMIN, LOCAL


def registered_runner() -> tuple[str, str]:
    """A runner with a known password: (email, password)."""
    email, password = f"runner-{uuid.uuid4()}@test.local", str(uuid.uuid4())
    httpx.post(
        f"{LOCAL['API_URL']}/auth/v1/admin/users",
        headers=ADMIN,
        json={"email": email, "password": password, "email_confirm": True},
    ).raise_for_status()
    return email, password


def sign_in(api: TestClient, email: str, password: str) -> httpx.Response:
    response: httpx.Response = api.post(
        "/api/runner/session", json={"email": email, "password": password}
    )
    return response


def events_with(api: TestClient, access_token: str) -> httpx.Response:
    response: httpx.Response = api.get(
        "/api/runner/events", headers={"Authorization": f"Bearer {access_token}"}
    )
    return response


def test_the_right_password_gives_a_session_that_works(api: TestClient) -> None:
    email, password = registered_runner()
    session = sign_in(api, email, password)
    assert session.status_code == 200, session.text
    assert events_with(api, session.json()["access_token"]).status_code == 200


def test_a_wrong_password_is_refused_plainly(api: TestClient) -> None:
    email, _ = registered_runner()
    refused = sign_in(api, email, "not the password")
    assert refused.status_code == 401
    assert refused.json()["error"] == "That email and password don't match."


def test_stray_spaces_around_the_email_dont_matter(api: TestClient) -> None:
    email, password = registered_runner()
    assert sign_in(api, f"  {email} ", password).status_code == 200


def test_a_refresh_gives_a_new_working_session_and_replaces_the_token(
    api: TestClient,
) -> None:
    email, password = registered_runner()
    first = sign_in(api, email, password).json()

    refreshed = api.post(
        "/api/runner/session/refresh", json={"refresh_token": first["refresh_token"]}
    )
    assert refreshed.status_code == 200, refreshed.text
    second = refreshed.json()
    assert second["refresh_token"] != first["refresh_token"]
    assert events_with(api, second["access_token"]).status_code == 200


def test_a_bogus_refresh_token_asks_to_sign_in_again(api: TestClient) -> None:
    refused = api.post(
        "/api/runner/session/refresh", json={"refresh_token": "not-a-real-token"}
    )
    assert refused.status_code == 401
    assert "sign in again" in refused.json()["error"]

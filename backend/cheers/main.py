"""The HTTP API. A standard ASGI app, so it runs as a Vercel function today and
in a Cloud Run container tomorrow without changes."""

import html
import os
from decimal import Decimal
from functools import lru_cache
from pathlib import Path
from typing import Annotated
from uuid import UUID

from fastapi import Depends, FastAPI, Header, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from pydantic import BaseModel

from cheers import service as svc
from cheers.config import Settings, build_service
from cheers.service import CheerService

app = FastAPI(title="Cheers")

# Only needed when the sender page is served from a different origin than the
# API, as in local development. Hosted together on Vercel they share one.
# Set at import time: Starlette refuses middleware once the app has started.
_origins = [
    o.strip() for o in os.environ.get("ALLOWED_ORIGINS", "").split(",") if o.strip()
]
if _origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=_origins,
        allow_methods=["GET", "POST"],
        allow_headers=["Authorization", "Content-Type"],
    )


@lru_cache
def settings() -> Settings:
    return Settings.from_env()


@lru_cache
def cheer_service() -> CheerService:
    return build_service(settings())


Service = Annotated[CheerService, Depends(cheer_service)]


# --- errors --------------------------------------------------------------------

_STATUS = {
    svc.EventNotFound: (404, "No such event."),
    svc.SubmissionsClosed: (409, "Cheers for this race are closed."),
    svc.NotASpot: (422, "That isn't a spot on this course."),
    svc.InvalidName: (422, "Please give a name between 1 and 60 characters."),
    svc.EventFull: (409, "Every spot has been taken."),
    svc.NoPendingClaim: (404, "That claim has expired or is already finished."),
    svc.RecordingMissing: (409, "The recording hasn't finished uploading."),
    svc.NotSignedIn: (401, "Please sign in."),
    svc.BadCredentials: (401, "That email and password don't match."),
    svc.SessionExpired: (401, "Your session has ended. Please sign in again."),
}


@app.exception_handler(svc.CheerError)
def _refused(_: Request, error: svc.CheerError) -> JSONResponse:
    status, message = _STATUS[type(error)]
    return JSONResponse({"error": message}, status_code=status)


# --- supporters ------------------------------------------------------------------

# The sender page is one static file. Served by the API rather than by the
# host's static hosting, so the page and the API it calls always share an
# origin, and moving hosts moves both together.
_WEB = Path(__file__).parent / "web"
_SENDER_PAGE = (_WEB / "sender.html").read_text()


@app.get("/cheer/{share_code}", include_in_schema=False)
def sender_page(share_code: str, request: Request, service: Service) -> HTMLResponse:
    # Whether the code is real is for the page to find out through the API,
    # so an unknown one gets the page's own friendly message — and a preview
    # that doesn't name anyone.
    try:
        runner = service.public_event(share_code).runner_name
    except svc.EventNotFound:
        runner = None
    page = _SENDER_PAGE.replace(
        "<!--link-preview-->", _link_preview(runner, _public_origin(request))
    )
    return HTMLResponse(page, headers={"Cache-Control": "no-cache"})


@app.get("/cheery-wordmark.svg", include_in_schema=False)
def wordmark() -> FileResponse:
    return FileResponse(
        _WEB / "cheery-wordmark.svg",
        media_type="image/svg+xml",
        headers={"Cache-Control": "public, max-age=86400"},
    )


@app.get("/cheer-preview.png", include_in_schema=False)
def preview_image() -> FileResponse:
    return FileResponse(
        _WEB / "preview.png",
        media_type="image/png",
        headers={"Cache-Control": "public, max-age=86400"},
    )


def _link_preview(runner: str | None, origin: str) -> str:
    """The tags chat apps read to show a card when the link is pasted. They
    don't run the page's script, so these have to arrive already filled in."""
    title = f"Record a cheer for {runner}" if runner else "Record a cheer"
    who = runner or "the runner"
    description = (
        f"Pick a mile of the Chicago Marathon and record up to 25 seconds: "
        f"{who} hears it right there. · Elige una milla y graba hasta 25 segundos."
    )
    tags = {
        "og:title": title,
        "og:description": description,
        "og:type": "website",
        "og:image": f"{origin}/cheer-preview.png",
        "og:image:width": "1200",
        "og:image:height": "630",
        "og:image:alt": "The Cheery logo above the words Record a cheer",
        "twitter:card": "summary_large_image",
    }
    lines = [f'<meta name="description" content="{html.escape(description)}">']
    lines += [
        f'<meta property="{key}" content="{html.escape(value)}">'
        for key, value in tags.items()
    ]
    return "\n".join(lines)


def _public_origin(request: Request) -> str:
    # Behind Vercel's proxy the app sees plain http; the forwarded headers say
    # what the visitor actually used, and chat apps want an https image link.
    scheme = request.headers.get("x-forwarded-proto", request.url.scheme)
    host = request.headers.get("x-forwarded-host", request.url.netloc)
    return f"{scheme}://{host}"


class SpotCount(BaseModel):
    slot: Decimal
    cheers: int


class PublicEventOut(BaseModel):
    name: str
    runner_name: str | None
    unit: str
    slots: list[Decimal]
    submissions_open: bool
    occupancy: list[SpotCount]


class ClaimIn(BaseModel):
    preferred: Decimal
    sender: str


class ClaimOut(BaseModel):
    cheer_id: UUID
    slot: Decimal
    upload_url: str


class CompleteOut(BaseModel):
    slot: Decimal


@app.get("/api/events/{share_code}")
def public_event(share_code: str, service: Service) -> PublicEventOut:
    event = service.public_event(share_code)
    return PublicEventOut(
        name=event.name,
        runner_name=event.runner_name,
        unit=event.unit,
        slots=event.slots,
        submissions_open=event.submissions_open,
        occupancy=[
            SpotCount(slot=s, cheers=n) for s, n in sorted(event.occupancy.items())
        ],
    )


@app.post("/api/events/{share_code}/claims")
def claim(share_code: str, body: ClaimIn, service: Service) -> ClaimOut:
    c = service.claim(share_code, str(body.preferred), body.sender)
    return ClaimOut(cheer_id=c.cheer_id, slot=c.slot, upload_url=c.upload_url)


@app.post("/api/claims/{cheer_id}/complete")
def complete(cheer_id: UUID, service: Service) -> CompleteOut:
    return CompleteOut(slot=service.complete(cheer_id))


# --- the runner ------------------------------------------------------------------


class RunnerEventOut(BaseModel):
    id: UUID
    name: str
    unit: str
    slots: list[Decimal]
    share_code: str


class RunnerCheerOut(BaseModel):
    id: UUID
    slot: Decimal
    sender_name: str
    download_url: str


class SignInIn(BaseModel):
    email: str
    password: str


class RefreshIn(BaseModel):
    refresh_token: str


class SessionOut(BaseModel):
    access_token: str
    refresh_token: str
    expires_in: int


@app.post("/api/runner/session")
def sign_in(body: SignInIn, service: Service) -> SessionOut:
    return SessionOut(**vars(service.sign_in(body.email, body.password)))


@app.post("/api/runner/session/refresh")
def refresh(body: RefreshIn, service: Service) -> SessionOut:
    return SessionOut(**vars(service.refresh(body.refresh_token)))


def _token(authorization: str | None) -> str | None:
    if authorization and authorization.lower().startswith("bearer "):
        return authorization[7:]
    return None


@app.get("/api/runner/events")
def runner_events(
    service: Service,
    authorization: Annotated[str | None, Header()] = None,
) -> list[RunnerEventOut]:
    return [
        RunnerEventOut(**vars(e)) for e in service.runner_events(_token(authorization))
    ]


@app.get("/api/runner/events/{event_id}/cheers")
def runner_cheers(
    event_id: UUID,
    service: Service,
    authorization: Annotated[str | None, Header()] = None,
) -> list[RunnerCheerOut]:
    return [
        RunnerCheerOut(**vars(c))
        for c in service.runner_cheers(_token(authorization), event_id)
    ]

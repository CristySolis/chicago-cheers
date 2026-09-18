"""The HTTP API. A standard ASGI app, so it runs as a Vercel function today and
in a Cloud Run container tomorrow without changes."""

import os
from decimal import Decimal
from functools import lru_cache
from typing import Annotated
from uuid import UUID

from fastapi import Depends, FastAPI, Header, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
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
}


@app.exception_handler(svc.CheerError)
def _refused(_: Request, error: svc.CheerError) -> JSONResponse:
    status, message = _STATUS[type(error)]
    return JSONResponse({"error": message}, status_code=status)


# --- supporters ------------------------------------------------------------------


class SpotCount(BaseModel):
    slot: Decimal
    cheers: int


class PublicEventOut(BaseModel):
    name: str
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

from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
from uuid import UUID


@dataclass(frozen=True)
class Event:
    id: UUID
    owner_id: str
    name: str
    unit: str
    slots: list[Decimal]
    submissions_open: bool
    share_code: str


@dataclass(frozen=True)
class Cheer:
    id: UUID
    event_id: UUID
    slot: Decimal
    seat: int
    sender_name: str
    audio_path: str | None
    created_at: datetime

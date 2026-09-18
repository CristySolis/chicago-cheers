"""Which seat a supporter gets.

Pure logic with no database or provider behind it, so the rules can be read
and tested on their own.

Every spot on the course has two seats: the first person, and whoever doubles
up once every spot is taken. When someone asks for a spot, candidate seats are
ranked by:

1. First seats before second — nobody doubles up while any spot is still free.
2. Spots at or after the one asked for before earlier ones, so a taken spot
   slides to the *next* free one.
3. Nearest first.
"""

from decimal import Decimal

Seat = tuple[Decimal, int]  # (spot, seat number)


def rank_seats(
    slots: list[Decimal],
    taken: set[Seat],
    preferred: Decimal,
) -> list[Seat]:
    """Every free seat on the course, best first."""
    free = [(slot, seat) for seat in (1, 2) for slot in slots if (slot, seat) not in taken]
    return sorted(
        free,
        key=lambda s: (s[1], s[0] < preferred, abs(s[0] - preferred)),
    )

"""The seat-ranking rules, without a database."""

from decimal import Decimal as D

from cheers.allocation import Seat, rank_seats

# Chicago: one spot per mile to 13, then one per half mile.
CHICAGO = [D(m) for m in range(1, 14)] + [D("13.5") + D("0.5") * i for i in range(26)]


def best(taken: set[Seat], preferred: int) -> Seat:
    return rank_seats(CHICAGO, taken, D(preferred))[0]


def test_chicago_has_39_spots_26_in_the_back_half() -> None:
    assert len(CHICAGO) == 39
    assert sum(1 for s in CHICAGO if s > 13) == 26


def test_a_free_spot_goes_to_whoever_asks() -> None:
    assert best(set(), 18) == (D(18), 1)


def test_a_taken_spot_slides_to_the_next_free_one_after_it() -> None:
    assert best({(D(18), 1)}, 18) == (D("18.5"), 1)


def test_with_nothing_free_after_it_the_nearest_before_is_used() -> None:
    assert best({(D(26), 1)}, 26) == (D("25.5"), 1)


def test_nobody_doubles_up_while_any_spot_is_free() -> None:
    everything_but_mile_1 = {(s, 1) for s in CHICAGO if s != 1}
    assert best(everything_but_mile_1, 20) == (D(1), 1)


def test_once_every_spot_is_held_the_next_doubles_up_where_it_asked() -> None:
    all_first_seats = {(s, 1) for s in CHICAGO}
    assert best(all_first_seats, 20) == (D(20), 2)


def test_a_full_course_has_no_seats_left() -> None:
    every_seat = {(s, seat) for s in CHICAGO for seat in (1, 2)}
    assert rank_seats(CHICAGO, every_seat, D(20)) == []

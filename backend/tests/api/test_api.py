"""The rules that matter on race day, through the same HTTP API the sender page
and the phone use, against a real local Supabase."""

from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal as D

import httpx

from .conftest import ADMIN, CHICAGO, LOCAL, age_claim, wav


def claim(api, event, preferred, sender="someone"):
    return api.post(
        f"/api/events/{event['share_code']}/claims",
        json={"preferred": str(preferred), "sender": sender},
    )


def claimed(api, event, preferred, sender="someone") -> dict:
    response = claim(api, event, preferred, sender)
    assert response.status_code == 200, response.text
    return response.json()


def cheer(api, web, event, preferred, sender) -> dict:
    """A complete cheer, the way the page makes one: claim, upload, finish."""
    c = claimed(api, event, preferred, sender)
    put = web.put(c["upload_url"], content=wav(), headers={"Content-Type": "audio/wav"})
    assert put.status_code == 200, put.text
    done = api.post(f"/api/claims/{c['cheer_id']}/complete")
    assert done.status_code == 200, done.text
    return c


def spot(c) -> D:
    return D(str(c["slot"]))


def runner_cheers(api, runner, event):
    return api.get(
        f"/api/runner/events/{event['id']}/cheers",
        headers={"Authorization": f"Bearer {runner[1]}"},
    )


# --- where a claim lands ----------------------------------------------------------


def test_a_free_spot_goes_to_whoever_asks_for_it(api, make_event):
    assert spot(claimed(api, make_event(), 18)) == 18


def test_a_taken_spot_slides_to_the_next_free_one_after_it(api, make_event):
    event = make_event()
    claimed(api, event, 18)
    assert spot(claimed(api, event, 18)) == D("18.5")


def test_with_nothing_free_after_it_the_nearest_before_is_used(api, make_event):
    event = make_event()
    claimed(api, event, 26)
    assert spot(claimed(api, event, 26)) == D("25.5")


def test_nobody_doubles_up_while_any_spot_is_free(api, make_event):
    event = make_event()
    for s in CHICAGO[1:]:
        claimed(api, event, s)
    assert spot(claimed(api, event, 20)) == 1


def test_once_every_spot_is_held_the_next_doubles_up_where_it_asked(api, make_event):
    event = make_event()
    for s in CHICAGO:
        claimed(api, event, s)
    assert spot(claimed(api, event, 20)) == 20


def test_simultaneous_claims_on_one_spot_never_share_a_seat(api, make_event):
    event = make_event()
    with ThreadPoolExecutor(max_workers=25) as pool:
        responses = list(
            pool.map(lambda i: claim(api, event, 20, f"racer {i}"), range(25))
        )
    assert all(r.status_code == 200 for r in responses), [r.text for r in responses]
    spots = [spot(r.json()) for r in responses]
    # 39 spots are free, so 25 people should land on 25 different ones.
    assert len(set(spots)) == 25, f"shared seats: {sorted(spots)}"
    assert D(20) in spots


def test_a_course_takes_two_people_per_spot_and_no_more(api, make_event):
    event = make_event()
    for s in CHICAGO * 2:
        claimed(api, event, s)
    refused = claim(api, event, 20)
    assert refused.status_code == 409
    assert "taken" in refused.json()["error"]


def test_a_spot_that_isnt_on_the_course_is_refused(api, make_event):
    assert claim(api, make_event(), "7.5").status_code == 422


def test_a_blank_name_is_refused(api, make_event):
    assert claim(api, make_event(), 5, "   ").status_code == 422


def test_closed_events_refuse_new_cheers(api, make_event):
    assert claim(api, make_event(submissions_open=False), 5).status_code == 409


def test_an_abandoned_claim_frees_its_spot_after_the_upload_window(api, make_event):
    event = make_event()
    abandoned = claimed(api, event, 10)
    age_claim(abandoned["cheer_id"], 20)
    assert spot(claimed(api, event, 10)) == 10


# --- anonymity ------------------------------------------------------------------------


def test_supporters_see_how_full_each_spot_is_but_never_who_is_in_it(
    api, web, make_event
):
    event = make_event()
    cheer(api, web, event, 18, "Mum")
    cheer(api, web, event, 20, "Tete")

    body = api.get(f"/api/events/{event['share_code']}").json()
    assert [(D(str(o["slot"])), o["cheers"]) for o in body["occupancy"]] == [
        (18, 1),
        (20, 1),
    ]
    assert "Mum" not in str(body) and "Tete" not in str(body)
    assert "owner_id" not in body


def test_supabases_own_api_cant_be_used_to_go_around_the_rules(make_event):
    make_event()
    direct = httpx.get(
        f"{LOCAL['API_URL']}/rest/v1/cheers?select=*",
        headers={
            "apikey": LOCAL["ANON_KEY"],
            "Authorization": f"Bearer {LOCAL['ANON_KEY']}",
        },
    )
    assert direct.json() == [] or direct.status_code >= 400, direct.text


def test_a_runner_sees_her_cheers_with_names_and_nobody_elses(
    api,
    web,
    make_event,
    her,
    other_runner,
):
    event = make_event()
    cheer(api, web, event, 18, "Mum")

    mine = runner_cheers(api, her, event)
    assert [c["sender_name"] for c in mine.json()] == ["Mum"]

    assert runner_cheers(api, other_runner, event).status_code == 404
    assert api.get(f"/api/runner/events/{event['id']}/cheers").status_code == 401


def test_only_finished_cheers_reach_the_runner(api, web, make_event, her):
    event = make_event()
    cheer(api, web, event, 18, "Mum")
    claimed(api, event, 20, "Still recording")
    assert [c["sender_name"] for c in runner_cheers(api, her, event).json()] == ["Mum"]


# --- recordings -----------------------------------------------------------------------


def test_an_upload_link_only_works_for_its_own_claim(api, web, make_event):
    event = make_event()
    c = claimed(api, event, 12)
    elsewhere = c["upload_url"].replace(
        c["cheer_id"], "00000000-0000-0000-0000-000000000000"
    )
    stray = web.put(elsewhere, content=wav(), headers={"Content-Type": "audio/wav"})
    assert stray.status_code >= 400, "uploaded somewhere the link wasn't for"


def test_a_finished_recording_cant_be_replaced(api, web, make_event):
    event = make_event()
    c = cheer(api, web, event, 12, "Mum")
    again = web.put(
        c["upload_url"], content=wav(), headers={"Content-Type": "audio/wav"}
    )
    assert again.status_code >= 400, "overwrote a finished recording"


def test_only_audio_can_be_uploaded(api, web, make_event):
    c = claimed(api, make_event(), 12)
    text = web.put(
        c["upload_url"], content=b"not audio", headers={"Content-Type": "text/plain"}
    )
    assert text.status_code >= 400


def test_a_claim_cant_be_finished_without_its_recording(api, make_event):
    c = claimed(api, make_event(), 12)
    assert api.post(f"/api/claims/{c['cheer_id']}/complete").status_code == 409


def test_only_the_events_runner_can_listen(api, web, make_event, her, other_runner):
    event = make_event()
    cheer(api, web, event, 12, "Mum")

    link = runner_cheers(api, her, event).json()[0]["download_url"]
    assert web.get(link).content == wav()

    path = link.split("/object/sign/cheers/")[1].split("?")[0]
    unsigned = web.get(
        f"{LOCAL['API_URL']}/storage/v1/object/cheers/{path}",
        headers={"apikey": LOCAL["ANON_KEY"]},
    )
    assert unsigned.status_code >= 400, "played a recording without a signed link"


def test_a_lapsed_claim_no_longer_counts_as_taken(api, make_event):
    event = make_event()
    c = claimed(api, event, 14)
    age_claim(c["cheer_id"], 20)
    assert api.get(f"/api/events/{event['share_code']}").json()["occupancy"] == []

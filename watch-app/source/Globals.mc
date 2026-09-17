import Toybox.Lang;

// Shared state between CheerApp (which receives messages from the phone)
// and CheerDataField (which displays them). Connect IQ apps run in a single
// process, so a module of plain variables is the simplest way to share
// state between the two without wiring up extra plumbing.
module Globals {

    // All cheers received this session, oldest first.
    // Each entry: { "id" => String, "sender" => String, "text" => String }
    var messageQueue as Array<Dictionary> = [];

    // Index into messageQueue of the next message CheerDataField hasn't
    // finished displaying yet. Equal to messageQueue.size() when caught up.
    var unreadIndex as Number = 0;

    // How many compute() ticks (~1/sec) we've held the current message on
    // screen. Used to auto-advance to the next unread message.
    var displayTicks as Number = 0;

    // How long to hold each unread message before auto-advancing.
    const HOLD_SECONDS = 6;

    // The unreadIndex value we last vibrated for, so we only buzz once per
    // new message rather than every compute() tick while it's on screen.
    var vibratedForIndex as Number = -1;

}

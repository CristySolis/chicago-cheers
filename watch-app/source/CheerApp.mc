import Toybox.Application;
import Toybox.Lang;
import Toybox.Background;
import Toybox.System;
import Toybox.WatchUi;

class CheerApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
        // Ask the system to wake CheerServiceDelegate whenever a phone
        // message arrives. Safe/idempotent to call on every start.
        if (!Background.getPhoneAppMessageEventRegistered()) {
            Background.registerForPhoneAppMessageEvent();
        }

        // Pick up anything the background process delivered while this
        // app instance wasn't running yet.
        var pending = Background.getBackgroundData();
        if (pending != null) {
            mergeMessage(pending as Dictionary);
        }
    }

    // Declares the background component. The system creates a fresh
    // CheerServiceDelegate instance for each background run.
    function getServiceDelegate() as Array<System.ServiceDelegate> {
        return [ new CheerServiceDelegate() ];
    }

    // Called on the foreground app whenever the background service calls
    // Background.exit(data) — this is how a message actually reaches the
    // visible Data Field, regardless of which screen is on-screen at the
    // time (CheerDataField.compute() picks it up from Globals every tick).
    function onBackgroundData(data as Application.PersistableType?) as Void {
        if (data instanceof Dictionary) {
            mergeMessage(data as Dictionary);
        }
    }

    private function mergeMessage(data as Dictionary) as Void {
        var id = data.get("id");
        if (id == null) {
            return;
        }
        for (var i = 0; i < Globals.messageQueue.size(); i++) {
            if (Globals.messageQueue[i].get("id").equals(id)) {
                return; // already have it — de-dupe
            }
        }
        Globals.messageQueue.add({
            "id" => id,
            "sender" => data.get("sender"),
            "text" => data.get("text"),
        });
    }

    function getInitialView() as Array<WatchUi.Views or WatchUi.InputDelegates>? {
        return [ new CheerDataField() ] as Array<WatchUi.Views or WatchUi.InputDelegates>;
    }

}

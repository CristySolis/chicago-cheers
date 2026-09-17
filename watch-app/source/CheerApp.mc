import Toybox.Application;
import Toybox.Lang;
import Toybox.Communications;
import Toybox.WatchUi;

class CheerApp extends Application.AppBase {

    private var _phoneMethod as Method(msg as PhoneAppMessage) as Void;

    function initialize() {
        AppBase.initialize();

        // Registered here rather than through a background service:
        // Background.registerForPhoneAppMessageEvent() requires Connect IQ
        // 3.2.0 and the Forerunner 935 is 3.1. This API has existed since
        // 1.4.0, and a data field only runs while an activity is recording,
        // which is the only time cheers matter anyway.
        _phoneMethod = method(:onPhone);
        if (Communications has :registerForPhoneAppMessages) {
            Communications.registerForPhoneAppMessages(_phoneMethod);
        }
    }

    // Called once per message. Anything that arrived before registration is
    // delivered immediately on registering, so nothing queued is lost.
    function onPhone(msg as PhoneAppMessage) as Void {
        var data = msg.data;
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
            var existing = Globals.messageQueue[i].get("id");
            if (existing != null && existing.equals(id)) {
                return; // already have it — de-dupe
            }
        }
        Globals.messageQueue.add({
            "id" => id,
            "sender" => data.get("sender"),
            "text" => data.get("text"),
        });
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        return [ new CheerDataField() ];
    }

}

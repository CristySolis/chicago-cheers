import Toybox.System;
import Toybox.Background;
import Toybox.Communications;
import Toybox.Lang;

// Background services are how a Data Field is allowed to touch the
// Communications API at all — a data field's own foreground class isn't
// permitted to (the compiler rejects "Communications" permission directly
// on a DATA_FIELD app). This class runs in a short-lived separate process
// that the system spins up specifically when a phone message arrives
// (registered via Background.registerForPhoneAppMessageEvent(), see
// CheerApp.onStart), independent of whatever screen is currently visible.
class CheerServiceDelegate extends System.ServiceDelegate {

    function initialize() {
        System.ServiceDelegate.initialize();
    }

    // Called by the system when a phoneAppMessage arrives from the iOS relay.
    function onPhoneAppMessage(msg as Communications.Message) as Void {
        var data = msg.data;
        if (data instanceof Dictionary) {
            // Hand off to the foreground app (CheerApp.onBackgroundData).
            // Background.exit() data must be a simple String/Number/Bool/
            // Array/Dictionary and under ~8KB — our {id, sender, text}
            // dictionary comfortably fits.
            Background.exit(data);
        } else {
            Background.exit(null);
        }
    }

}

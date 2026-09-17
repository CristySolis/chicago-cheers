import Toybox.WatchUi;
import Toybox.Lang;
import Toybox.Graphics;
import Toybox.Activity;
import Toybox.Attention;

class CheerDataField extends WatchUi.DataField {

    function initialize() {
        DataField.initialize();
    }

    // The system calls compute() roughly once per second WHILE THE
    // ACTIVITY IS RECORDING, regardless of whether this data field's
    // screen is the one currently visible (Garmin needs this to keep FIT
    // data current in the background). That's what lets us vibrate the
    // moment a cheer arrives even if you're looking at Runna's pace
    // screen instead of this one.
    function compute(info as Activity.Info) as Void {
        var total = Globals.messageQueue.size();

        if (Globals.unreadIndex < total) {
            if (Globals.vibratedForIndex != Globals.unreadIndex) {
                buzz();
                Globals.vibratedForIndex = Globals.unreadIndex;
                Globals.displayTicks = 0;
            } else {
                Globals.displayTicks += 1;
                if (Globals.displayTicks >= Globals.HOLD_SECONDS) {
                    Globals.unreadIndex += 1;
                    Globals.displayTicks = 0;
                }
            }
        }

        WatchUi.requestUpdate();
    }

    function buzz() as Void {
        if (Attention has :vibrate) {
            Attention.vibrate([ new Attention.VibeProfile(100, 500) ]);
        }
    }

    // Only called while THIS screen is the one visible.
    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var total = Globals.messageQueue.size();
        var w = dc.getWidth();
        var h = dc.getHeight();

        if (total == 0) {
            dc.drawText(w / 2, h / 2, Graphics.FONT_MEDIUM, "Waiting for cheers",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }

        var idx = Globals.unreadIndex < total ? Globals.unreadIndex : total - 1;
        var msg = Globals.messageQueue[idx] as Dictionary;
        var sender = msg.get("sender") as String;
        var text = msg.get("text") as String;

        dc.drawText(w / 2, h * 0.14, Graphics.FONT_MEDIUM, sender, Graphics.TEXT_JUSTIFY_CENTER);
        drawWrapped(dc, text, w, h);

        var remaining = total - idx - 1;
        if (remaining > 0) {
            dc.drawText(w / 2, h * 0.90, Graphics.FONT_XTINY, "+" + remaining + " more waiting",
                Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // Picks the largest font whose word-wrapped block still fits in the
    // middle of the screen, so short "GO GO GO" messages render huge and
    // longer ones shrink just enough to fit without truncation.
    function drawWrapped(dc as Graphics.Dc, text as String, w as Number, h as Number) as Void {
        var fonts = [
            Graphics.FONT_LARGE,
            Graphics.FONT_MEDIUM,
            Graphics.FONT_SMALL,
            Graphics.FONT_TINY,
            Graphics.FONT_XTINY,
        ];

        for (var f = 0; f < fonts.size(); f++) {
            var font = fonts[f];
            var lines = wrapText(dc, text, font, w * 0.9);
            var lineHeight = dc.getFontHeight(font);
            var blockHeight = lines.size() * lineHeight;
            var lastOption = (f == fonts.size() - 1);

            if (blockHeight <= h * 0.62 || lastOption) {
                var startY = (h * 0.55) - (blockHeight / 2);
                for (var i = 0; i < lines.size(); i++) {
                    dc.drawText(w / 2, startY + (i * lineHeight), font, lines[i],
                        Graphics.TEXT_JUSTIFY_CENTER);
                }
                return;
            }
        }
    }

    function wrapText(dc as Graphics.Dc, text as String, font, maxWidth as Float) as Array<String> {
        var words = text.split(" ", null);
        var lines = [] as Array<String>;
        var current = "";

        for (var i = 0; i < words.size(); i++) {
            var word = words[i];
            var candidate = (current.length() == 0) ? word : (current + " " + word);
            var dims = dc.getTextDimensions(candidate, font);
            if (dims[0] <= maxWidth || current.length() == 0) {
                current = candidate;
            } else {
                lines.add(current);
                current = word;
            }
        }
        if (current.length() > 0) {
            lines.add(current);
        }
        return lines;
    }

}

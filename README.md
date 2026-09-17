# Chicago Cheer Squad

Full-screen, big-text cheer messages on your Garmin watch during the marathon,
compatible with running Runna's guided workout.

```
Friends/family --> Google Form --> Google Sheet (published as CSV)
                                          |
                                    iOS CheerRelay app (polls every 15s)
                                          |
                              Garmin Connect IQ Mobile SDK (Bluetooth)
                                          |
                         "Cheer Squad" data field on your watch
                    (full-screen message + vibrate, lives inside
                     Runna's native Run activity screens)
```

This is a starting scaffold, not a tested build — neither the Connect IQ
simulator nor Xcode exist in the environment that wrote this, so **both
halves need to be opened, compiled, and iterated on their native tools**
before race day. Budget more than one evening for this.

---

## 1. Message intake: Google Form + Sheet

1. Go to [forms.google.com](https://forms.google.com), create a form named
   "Cheer for Cristy" with two **short answer** questions: `Name` and
   `Message`. Turn off "Collect email addresses."
2. Open the linked response Sheet (Responses tab → green Sheets icon).
3. In the Sheet: **File → Share → Publish to web**. Choose the responses
   sheet/tab, set format to **Comma-separated values (.csv)**, click Publish.
4. Copy the resulting URL — it looks like
   `https://docs.google.com/spreadsheets/d/e/<long id>/pub?output=csv`.
5. Paste it into `ios-app/CheerRelay/Config.swift` as `sheetCSVURL`.
6. Share the **Form** link (not the Sheet) with friends/family — a QR code
   on your bib or a group text works well.

The Sheet will have columns `Timestamp | Name | Message` in that order —
`SheetPoller.swift` expects exactly that.

## 2. Watch app (Connect IQ / Monkey C)

1. Install the [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/)
   and its VS Code extension ("Monkey C"). Make sure it's a recent SDK —
   your Forerunner 935 (`fr935` in the manifest) is an old device (Connect
   IQ API level 3.1, from 2017); older SDK releases sometimes drop support
   for it, so if the device doesn't show up as a build target, update the
   SDK's device list from within VS Code's Monkey C panel.
2. Open `watch-app/` as the project root in VS Code.
3. **Use the visual manifest editor for the background service part.**
   Open `manifest.xml` in VS Code's Monkey C manifest editor UI and confirm
   there's a "Background Service" toggle enabled for this app — I wrote a
   best-guess `<iq:background/>` element by hand since I couldn't verify
   the exact syntax against live docs; let the SDK regenerate it correctly
   if the editor shows something different or the build complains about it.
4. Regenerate the app UUID: run `uuidgen` (Mac terminal) and replace the
   `id="..."` value in `manifest.xml`. **Copy that same UUID** into
   `ios-app/CheerRelay/Config.swift`'s `watchAppId` — they must match exactly.
5. Build → Run in Simulator first (`Monkey C: Run` in VS Code), targeting
   the Forerunner 935 profile, to sanity check it draws without crashing
   (it'll show "Waiting for cheers"). This is also where you'll catch any
   API-level-3.1 incompatibilities I might have missed.
6. Build for device, connect your watch via USB, and copy the generated
   `.prg` into the watch's `GARMIN/APPS` folder (VS Code's "Build for
   Device" + "Export" does this, or drag-and-drop over USB).
7. On the watch: **Run → Workouts → Do Workout** (or a plain Run) →
   hold/press to edit data screens → add screen → find "Cheer Squad" →
   add it as its own full screen (pick the 1-field layout for max size).

## 3. iOS relay app

1. In Xcode: **File → New → Project → iOS App**, SwiftUI, name it
   `CheerRelay`, and replace the generated files with everything in
   `ios-app/CheerRelay/`.
2. Add the Connect IQ Mobile SDK: `pod install` using the included
   `Podfile` (needs CocoaPods — `sudo gem install cocoapods` if you don't
   have it), then open the generated `.xcworkspace`, not `.xcodeproj`.
3. Merge `Info.plist.snippet.xml`'s keys into the target's Info settings
   (URL scheme, `LSApplicationQueriesSchemes`, background fetch mode).
4. Double check `Config.watchAppId` matches the watch manifest's UUID (step
   2.3 above), and `sheetCSVURL` matches your published Sheet link.
5. Build to your iPhone (needs a free or paid Apple Developer account —
   free works fine for installing to your own device via Xcode).
6. Make sure Garmin Connect Mobile is installed and your watch is already
   paired to it (this app rides on that existing Bluetooth pairing).
7. Open CheerRelay, tap **Connect**, pick your watch from Garmin's device
   picker.

## 4. Test before race day — don't skip this

- [ ] Submit a test entry on the Google Form from a different phone; confirm
      it appears in CheerRelay's list within ~15s and the watch vibrates.
- [ ] Confirm the message renders full-screen, readable, on the actual watch
      (not just the simulator) — check both a short ("GO!") and a long
      (200+ character) message for wrapping/shrinking.
- [ ] Start an actual Runna workout on the watch, swipe to the Cheer Squad
      screen, send a test cheer from another screen, confirm the buzz still
      fires and the message is waiting when you swipe over.
- [ ] Leave CheerRelay running (screen off, phone in an armband/pocket) for
      30+ minutes and confirm messages still relay — iOS background timing
      is the least predictable part of this whole chain, and Chicago is a
      4+ hour day for most runners.
- [ ] Battery check: run a real ~90 minute test with GPS activity + Bluetooth
      relay running the whole time, watch both phone and watch battery drain.
- [ ] Send several cheers in a burst (friends/family will likely cluster
      messages at the same mile markers) and confirm the "+N more waiting"
      queue behaves and nothing gets dropped or overwrites unseen.

## Known limitations (by design, see earlier discussion)

- The message can't force itself onto whatever screen you're currently
  looking at — Connect IQ doesn't allow a data field to do that while
  Runna's native Run activity is in the foreground. You'll feel a buzz and
  need one swipe to see it. (Building your own full activity app instead of
  Runna's would remove this limitation, at the cost of losing Runna's
  on-watch guidance — a bigger project if you want to revisit it.)
- Forerunners don't support distinct vibration *patterns*, just a plain
  buzz, so "new cheer" feels the same as any other watch buzz.

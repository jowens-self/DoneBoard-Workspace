# DoneBoard

A macOS + iOS calendar of what you actually got done, plus a to-do list that feeds it.

`README.md` is the reference for what the app *does* and how the format works, and it is
kept accurate - read it rather than re-deriving. This file is for the things that are easy
to get wrong.

## Layout

```
Sources/Shared/   91% of the code - model, store, and every view
Sources/Mac/      App, ContentView, Platform, SettingsView
Sources/iOS/      App, ContentView, Platform, SettingsView
```

`Platform.swift` exists in two versions with identical names, so nothing in `Shared/` knows
which one it got. `Model.swift` and `Store.swift` import **no UI or platform framework** -
Foundation and Observation only. Keep it that way; that property is what makes another
client possible later, and `check-portable.sh` is what catches a slip.

## Building

| what | how |
| --- | --- |
| macOS app | `./build.sh` - Command Line Tools are enough |
| iOS simulator | `./build-ios.sh` - plain swiftc, no provisioning profile needed |
| physical iPhone | `xcodegen generate`, then the **DoneBoard (iPhone)** scheme - see `XCODE.md` |
| both SDKs type-check | `./check-portable.sh` - Mac and iPhone - **run after any `Sources/Shared` change** |
| data layer checks | `./test.sh` - **run after any `Model.swift` or `Store.swift` change** |

`check-portable.sh` takes a few seconds and exists because a green Mac build says nothing
about iOS - an AppKit import in `Store.swift` would otherwise go unnoticed for weeks.

The Xcode project is **build output**: XcodeGen generates it from `project.yml`, and it is
gitignored. Change the spec and regenerate - never edit the project - and regenerate after
adding or removing a source file. The signing team lives in `project.yml` for the same
reason: one picked in Xcode's Signing tab is discarded by the next regenerate, and device
builds then fail with "No profiles were found".

## Verifying

**`./test.sh` proves the data layer** - merging, the file format, editing, and two devices on one
file - in about ten seconds, with only Command Line Tools. Run it after any change to `Model.swift`
or `Store.swift`, and give anything new there a check in `Tests/`. There is no test target: it
compiles `Model.swift`, `Store.swift`, `SoundFile.swift` and `Diagnostics.swift` straight in with
the checks, and points `DONEBOARD_DATA` at a temporary folder, so the device copy and the
diagnostics log never touch the real ones. A store on a shared file answers in the background, so
`settle()` spins the main run loop until `isExchanging` is false before anything is checked.
Compare what a file holds rather than stamps in memory: the file keeps milliseconds, so a stamp can
differ from its own saved copy by a fraction of one. `SyncLocation` isn't covered - folder tests
need its `private init` opened up.

The views have no automated checks. Two harnesses cover them, and the pattern is worth reusing:

- **`NSHostingView` + `cacheDisplay` off-screen** for anything inside a `ScrollView` -
  which is both the board and the list. `ImageRenderer` cannot render `ScrollView` content
  or `TextField`.
- Screenshots in **both appearances**. The accent colour and the goal ring are easy to get
  subtly wrong in one of them.

Two traps in the hosting-view route. `cacheDisplay` never paints the window's own background,
so in dark mode the semantic colours land on white backing and the capture looks like a broken
app - wrap the view in `.background(Color(nsColor: .windowBackgroundColor))`. And a grouped
`Form` stays collapsed until its window is ordered in, so call `orderFrontRegardless()` with the
frame parked at x/y = -20000, where it never reaches a display.

When a capture comes out blank, render a *trivial* version of the same construct through the
same harness before believing the app is broken.

Synthesized single clicks don't fire a SwiftUI `Button` in a harness window (it is never key),
with or without anything over it; double-clicks and hit-testing are the usable signal there.
Hover can't be synthesized.

## Diagnosing a problem

Start with `Tools/diagnose.sh`. It pulls the phone app's `Diagnostics/` out of its container with
`devicectl` (no unlock needed), the phone's system crash logs for DoneBoard - an iOS watchdog kill
is an `.ips` there with `0x8badf00d` and the main thread's stack - the Mac app's folder and system
reports, and a `sample` of the running Mac app, then prints the notable lines.

- **`events.log`** is what the app did, with timings for anything that might stall. The launch
  line's "previous run" says how the last run ended; one killed while frozen says what it was
  inside and for how long. Every change is named as it is saved - `checking off a to-do onto
  2026-10-27, 5 there now` - before anything is written, and the exchange it sends says the same,
  so a freeze inside a save still shows what it was for. A celebration gets `celebrating the goal`,
  then `fireworks:` and `fireworks done:` with the frames drawn; a run with no `done` line is one
  the app didn't see through.
- **`Reports/`**: `freeze-*.txt` has the main thread's stack at 1, 3, 8 and 15s, each frame with
  its offset into its image and each image with its load address and UUID, for `atos`;
  `slow-*.txt` is the same for background work past 10s; `crash-*.txt` is a fatal signal's
  backtrace; `system-*.json` is MetricKit.
- **Which build is running:** the launch line and every report header carry the commit, stamped
  by `Tools/stamp-commit.sh`. A trailing `+` means uncommitted changes went into that build.
- **A freeze happening right now:** `sample DoneBoard 3` on the Mac. On the phone the app's own
  watchdog is already writing it down; pull it with `diagnose.sh` once it has had a few seconds.
- **A freeze of the whole phone** leaves nothing under DoneBoard's name. `diagnose.sh` keeps the
  phone's own reports from the last three days in `iphone/whole-phone/`, including any stackshot
  that lists DoneBoard - a watchdog ending some other process files one of every process, under
  that process's name - and says what DoneBoard was doing in each. The phone's full system log
  needs a sysdiagnose: `devicectl device sysdiagnose` fails over Wi-Fi (`DiagnoseError 0`), so
  hold both volume buttons and the side button for a second right after it happens, then copy it
  out of `systemCrashLogs` (`DiagnosticLogs/sysdiagnose/`).
- **Don't attach lldb to the phone app from the command line.** `device process attach --name`
  silently does nothing, `-p` attaches but leaves the app running so no thread can be read, and
  lldb exiting while attached kills the app - no crash report, just gone. The next launch's
  "previous run: ended unexpectedly" is what shows it.

Freeze lengths are lower bounds, measured from the first check-in that went unanswered, and a
freeze the system ends with SIGKILL has no final capture - its last word is the most recent one.
Two things in there must never allocate: the stretch between `thread_suspend` and
`thread_resume` in `StackTrace.capture`, and the fatal-signal handler in `CrashCapture`. Either can
run while the stopped or crashing thread holds the lock malloc needs. Code that looks allocation-free
isn't always: a Debug build - Xcode's Run - looks up a type's metadata the first time it meets it,
which allocates and locks. `StackTrace.warmUp` runs one full capture on a parked thread at launch so
that happens before any real thread is ever stopped; anything added to the capture is covered only
if the warm-up goes through it too.

## Things that will bite

**Text follows the phone's text size - use `.scaledFont(size:)`, not `.font(.system(size:))`.**
`TextSize.swift` keeps each size the design picked at the default setting and grows it with the
reader's setting; on the Mac it never changes. Where a size can't grow without breaking something,
cap it: the month grid and the goal ring stop at `.xxxLarge`, and at the accessibility sizes the
board's header and cards stack instead of sitting side by side. Check a layout change at
`xcrun simctl ui DoneBoard-iPhone content_size accessibility-extra-extra-extra-large` as well as
the default. An icon in a fixed `.frame` grows out of it, so give it `minWidth`/`minHeight`.

**VoiceOver reads what the colours mean.** A day in the calendar says its date, how much got done
and whether the goal was met (`DayCell.spoken`), because its colour is the only thing showing that;
the weekday letters are hidden since each day names its own. Decorative icons are hidden, icon-only
buttons are labelled, and the fireworks are hidden while the banner announces itself. The Mac's
SwiftUI accessibility tree can be read in-process: set `AXEnhancedUserInterface` on `NSApplication`
with `accessibilitySetValue`, then walk the hosting view's `accessibilityChildren()` - without that
the tree comes back empty.

**No Apple assets, ever.** `Resources/Sounds/` is empty *on purpose* and the picker is built from
whatever is in it at build time - so dropping files from `/System/Library/Sounds` in there puts
Apple's audio straight into the repo. Celebrations *reference* the system alert via
`NSSound(named:)` / `AudioServicesPlaySystemSound`, which redistributes nothing.

**Sync is a file, not a service.** Both devices read and write one JSON file and reconcile
it with `Archive.merged`. Storage is **local by default**; picking a folder is only for
sharing between devices, and any folder works.

**A sync folder is a bookmark, and two things about it are easy to get backwards.** Open the
picked URL's security scope *before* bookmarking it - iOS refuses otherwise. And never forget
the bookmark because it won't resolve: a share on a sleeping Mac is only away, and forgetting
it turns one launch away from home into sync ending for good. `SyncLocation` keeps it and
`connect()`s again on foreground, and on its own after a failed lookup (15s, doubling to a
minute) - a phone's first look after an install can fail with `NSFileProviderErrorDomain -1005`
and the next, half a minute later, work. To test that on a Mac, delete and recreate a folder - a
detached disk image is no stand-in, because resolving a bookmark remounts it by itself.

**Never touch the sync folder on the main thread.** Resolving its bookmark, and every
coordinated read or write of a file in it, waits on the network - and a share on a Mac with its
lid shut takes longer to give up than iOS lets an app stop answering. iOS kills the app for exactly
that (`0x8badf00d`: inside `URL(resolvingBookmarkData:)` at launch, or inside a coordinated read on
coming to the front). `SyncLocation` looks folders up on a global queue and hands the file over
through `fileChanged`; `Store` exchanges with a shared file on its `io` queue and merges what comes
back into whatever it holds by then. Only this device's own file is read and written in place.
Watch for file-system calls that don't look like them: `appendingPathComponent(_:)` without
`isDirectory:` asks the disk whether the result is a folder, and inside `SyncLocation.fileURL` on
the main thread that froze the phone for 16 seconds - `check-portable.sh` rejects the one-argument
form. `standardizedFileURL` stats the path too; compare URLs with `Store.samePlace`, and the same
check rejects the standardizing calls. **Nothing on the main thread is coordinated either, not even
this device's own file**: on the phone a coordinated call waits behind any coordination the app
still has out, on any file - adding a to-do once sat 20 seconds reading the local copy behind an
exchange with a share that wasn't answering. A Mac doesn't do this, so no check here can show it.
In-place reads and writes skip coordination unless `DONEBOARD_DATA` names the file
(`Store.coordinatesInPlace`). Every exchange holds background time through `Store.keepRunning`
(a UIKit background task on the phone) - an exchange without that time is suspended with the app,
leaving a change made just before leaving on the phone until it is next opened. To test it the way
the app experiences a sleeping Mac, hold a coordinated write claim on the shared file from another
thread and check the main thread never waits.

**A watcher hears this store's own writes, failed ones included.** An atomic write makes and
removes a temporary file beside the target, so a write the share refuses still changes the folder,
and reloading on that retries the write at once - a phone once did it every 0.65s, 71 times, until
iOS suspended it. `fileChanged` leaves the watcher's news to the retry while the last write failed,
and news that lands mid-exchange to one more read once it returns. The sync harness reproduces the
loop by `chflags uchg` on the shared file. Remote writes through a share aren't reliably heard at
all, which is why the apps also `checkIn()` every 30s while in front.

**An effect that fills the screen can freeze the whole phone, not just the app.** The system
draws its own screens - the power-off slider included - on the same GPU, so an overlay that
outruns it locks everything, and no watchdog of the app's notices, because the app's main thread
is fine. The fireworks are the one full-screen effect: at their heaviest, every spark its own
shape, over a thousand draws a frame at the peak, under a frosted banner blurred again on each
one. Count the draws a frame before adding to anything that animates full screen: shapes that
share a colour go in one path, `TimelineView` is held to 60 (the goal ring's small rainbow spin
is the exception), and no material sits over moving content. The iPhone build has never set
`CADisableMinimumFrameDurationOnPhone`, and without it an iPhone most likely holds the app's own
animations to 60 anyway. None of it shows on the Mac. The check is a device build: `events.log`
gets a `fireworks done:` line with the frames a run drew against its seconds, and a run with no
such line is one the app didn't outlive.

**Merge rules live in exactly one place.** `Archive.merged` is order-independent and its
tie-breaks are deliberate; the `Mergeable` comment warns that two copies of these rules is a
way to get two different answers. That is the standing argument against reimplementing them
in another language - it is why a web client was deferred.

**Every persisted field is optional on the way in.** A record with no `updatedAt` reads as
never edited, one with no `deletedAt` as live. Adding a field means decoding it with
`decodeIfPresent` and a fallback that reads an old file exactly as it was meant, so no
migration step is ever needed. Keep that.

**Saving merges and re-adopts.** `save()` merges with the file and replaces `records` and
`todos` wholesale - straight away for this device's own file, and whenever the background
exchange returns for a shared one. Any index taken *before* a save may point somewhere else
after it, and for a shared file "after" is any later turn of the main queue - look the record
up again rather than reusing the index.

**The iPhone icon comes from the asset catalog.** Current iOS reads the home-screen icon from
the compiled `Assets.car`, so `Resources/Assets.xcassets` is what a device build uses;
`Resources/iOSIcons` only feeds the simulator script. `Tools/make-icon.sh` rebuilds all of them
from one source - never hand-copy one. And count a generated image's pixels before trusting a
preview of it: the iPhone icons once shipped solid black, because a no-alpha
`NSBitmapImageRep` gets a nil graphics context and every draw into it goes nowhere.

## Commit messages

Prose that explains *why*, including tradeoffs and bugs found along the way.

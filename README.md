# DoneBoard

A calendar for what you actually got done.

Most task apps are lists of things you haven't done yet, and they're quietly demoralising -
the list never empties, and finishing something just makes room for the next thing. DoneBoard
runs the other way. There is no pending state and nothing to check off. You do something,
you throw it up on the board, and it stays there. At the end of the month the calendar is a
record of a month's work rather than a graveyard of intentions.

## The board

One day at a time, newest on top. Type what you did, press return, and it goes up. The field
keeps focus, so logging three things in a row is three sentences and three returns.

Nothing is *required* of an entry - no project, no estimate, no priority. The whole point is
that putting something on the board has to be cheaper than not bothering.

Right-click a card for everything you can do to it - edit, copy, move it to another day,
remove it - or hover it and use the `•••` button, which opens the same menu. Double-click a
card to fix its words or the time it was done, and the `✕` on hover removes it in one click.

Forgot to log yesterday? The `‹` `›` arrows walk back through the days and anything you add
lands on the day you're looking at. If you logged something on the wrong day you don't have
to retype it - move it, and it carries its clock time across, so it still reads as the hour
you did the thing rather than the hour you noticed the mistake. You can't move forward past
today, because a thing you haven't done yet isn't what this app is for.

Moving a card never sets off fireworks, even when it pushes a day past its goal. Corrections
aren't accomplishments.

## The to-do list

Deliberately not the front page - it's a tab on the phone and the second half of a switch
on the Mac. Nothing on it counts for anything: the calendar and the goal are still fed only
by work that actually happened. It runs newest first, so whatever you just typed sits
directly under the field you typed it into.

It exists because lining something up and recording that you did it are different acts, and
the app is about the second one. Checking a to-do off is the single bridge between them, and
it runs one way: the to-do disappears and the same words land on today's board with the time
you checked it. If that crosses your goal, the fireworks go off exactly as they would have
had you typed it in yourself.

Dropping something you're never going to do is a separate action from doing it, and leaves
nothing behind.

To-dos sync between devices on the same terms entries do, tombstones and all: check something
off on your phone and it is gone from the Mac's list, without a device that has never seen it
bringing it back.

## The calendar

The month sits in the sidebar. Days you did something are lit; the more you did, the stronger
the colour, and days where you hit your goal go gold. A good month is visible from across the
room without reading a single word. Click any day to put its board up.

Underneath: how much you did this month, your best day in it, and the all-time total.

## Fireworks

Set a daily goal in Settings (⌘,). The moment you cross it, real fireworks go off across the
window - shells that climb, burst, and drift down on the wind - with a banner and a sound.
Cross another whole multiple of the goal and you get an encore.

The app ships no audio of its own, so a celebration uses the platform's own alert -
referenced through `NSSound(named:)` and `AudioServicesPlaySystemSound`, never carried in
this repository. Drop files into `Resources/Sounds` and each becomes an option in Settings
automatically, on both platforms, with no code change; see the note in that folder.

Get **three times** the goal in one day and the ring stops being gold. That is all the
documentation that one gets.

## Keyboard

| | |
|---|---|
| ⌘N | jump to the entry field |
| ⌘T | back to today |
| ⌘[ / ⌘] | previous / next day |
| ⌘, | settings |
| return | put the entry up |
| double-click | edit a card |
| right-click | edit, copy, move or remove a card |

## Where your data lives

One readable JSON file:

```
~/Library/Application Support/DoneBoardWorkspace/doneboard.json
```

```json
{
  "version": 2,
  "dailyGoal": 5,
  "soundEnabled": true,
  "goalSound": "Default",
  "settingsUpdatedAt": "2026-08-24T20:00:00.000Z",
  "entries": [
    {
      "id": "27FA...",
      "text": "Fixed the dripping tap",
      "createdAt": "2026-08-24T21:12:04.412Z",
      "day": "2026-08-24",
      "updatedAt": "2026-08-24T21:12:04.412Z"
    }
  ],
  "todos": [
    {
      "id": "9C31...",
      "text": "Reconcile the card statement",
      "createdAt": "2026-08-24T19:02:11.006Z",
      "updatedAt": "2026-08-24T19:02:11.006Z"
    }
  ]
}
```

Every field past `id`, `text` and `createdAt` is optional on the way in, so a file written by
an older build still opens: a record with no `updatedAt` reads as never edited since it was
made. Deleting sets a `deletedAt` and leaves the row behind - see [Sync](#sync) for why.

Days are stored as plain `yyyy-MM-dd` strings rather than timestamps, so answering "what did
I do on the 3rd" needs no timezone arithmetic and the file reads as well by eye as it does by
machine. Writes are atomic. If the file is ever unreadable, the app keeps a copy of its bytes
beside it before writing a good one, so a bad parse can't cost you your history.

Set `DONEBOARD_DATA` to keep the file somewhere else - point it into a synced folder such as
Dropbox and the board follows you between machines:

```
DONEBOARD_DATA=~/Library/Mobile\ Documents/com~apple~CloudDocs/doneboard.json
```

## Icon

The art lives in `Calendar Task App Logos/`. `Resources/AppIcon.icns` is built from
`icon-accent-knockout.png` by `Tools/make-icon.sh`, which also handles one thing the raw art
doesn't: the source is full-bleed - the rounded square runs to all four edges - but a macOS
icon is expected to leave a margin so it sits the same size as its neighbours in the Dock.
Apple's grid puts an 824pt body on a 1024pt canvas, and shipped apps agree when you measure
them (Claude.app 82%, Comet 80.7%), so the art is inset to 80.5%.

The iPhone wants the opposite: full-bleed and opaque, because iOS applies its own rounded
mask. The same run of `make-icon.sh` draws that too - into `Resources/iOSIcons`, which the
simulator script copies in loose, and into `Resources/Assets.xcassets`, whose single 1024 is
what the device build compiles and generates every smaller size from. Current iOS reads the
home-screen icon from that compiled catalog, so a device build without it shows a blank icon.

To rebuild them, or to swap in one of the other variants:

```
./Tools/make-icon.sh                                     # the default, accent knockout
./Tools/make-icon.sh "Calendar Task App Logos/icon-dark-1024.png"
```

The knockout art is 480pt square, so the largest slot is upscaled 1.72x. Flat colour and
large simple shapes take that well and it holds up, but a 1024pt export would be sharper if
you ever regenerate the set.

The four icon variants - dark, light, monochrome and accent-knockout - line up with the
light/dark/tinted app icons macOS 26 supports through the `.icon` format. That format needs
Icon Composer, which ships with Xcode, so for now a classic `.icns` carries the dark one
alone and the rest are waiting for a toolchain that can use them.

## Building

The Mac app needs only Command Line Tools - no Xcode:

```
./build.sh
open build/DoneBoard.app
```

The iPhone app needs Xcode and an iOS simulator runtime. For the *simulator* it is still
plain `swiftc` into a hand-made bundle, which works because the simulator doesn't require a
provisioning profile - `DoneBoard.xcodeproj` is only involved when the target is a real
phone:

```
./build-ios.sh
```

That compiles, creates a simulator named `DoneBoard-iPhone` if there isn't one, installs and
launches. A build for a *physical* iPhone is where that trick runs out - device builds need
signing, and signing needs a project Xcode is willing to sign.

## Onto your own iPhone

`DoneBoard.xcodeproj` exists for this. XcodeGen generates it from `project.yml`, and it is not
checked in - `XCODE.md` has the details:

```
brew install xcodegen      # once
xcodegen generate
```

Regenerate after adding or removing a source file, and after any change to `project.yml`.
Never edit the project itself; the next regenerate replaces it.

Then, once:

1. `open DoneBoard.xcodeproj`
2. **Xcode ▸ Settings ▸ Accounts ▸ +**, and sign in with your Apple ID. A free account is
   enough; you do not need the paid Developer Program.
3. Put your team ID in `DEVELOPMENT_TEAM` in `project.yml` and regenerate - a team picked in
   Xcode's Signing tab doesn't survive the next regenerate. Xcode shows the ID under
   **Settings ▸ Accounts**, beside the team.
4. Plug the iPhone in **and unlock it**, then tap **Trust This Computer** and enter the
   passcode. Check it shows up under **Window ▸ Devices and Simulators** (⇧⌘2). A cable that
   only carries power is the usual reason nothing appears - it charges and never enumerates.
5. Turn on Developer Mode: **Settings ▸ Privacy & Security ▸ Developer Mode**, then restart
   the phone. After it reboots an alert asks again - **Turn On**, passcode. It is not enabled
   until that second prompt is answered.

   The row does not exist in Settings until the phone has been connected to a Mac running
   Xcode at least once, which is why looking for it first comes up empty. Do step 4, then
   this one.
6. Choose the **DoneBoard (iPhone)** scheme and your phone from the menus at the top of the
   Xcode window, and press ⌘R.
7. The first launch is refused with "Untrusted Developer". On the phone:
   **Settings ▸ General ▸ VPN & Device Management**, tap your Apple ID, **Trust**. Launch it
   again and it works.

Nothing in steps 4-7 is specific to this app - it is what any device build costs the first
time, and only the first time.

If the bundle identifier `com.example.doneboard` is already taken on the developer
portal, change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`, regenerate, and set the same value in
`Resources/Info-iOS.plist`.

**On a free account the app stops opening after seven days** and you re-run it from Xcode to
get another week. That is Apple's limit on free provisioning, not something the app can work
around; the paid Developer Program ($99/yr) raises it to a year. Your data is untouched by
this either way - it lives in the app's container and, if you have pointed both devices at a
shared folder, in the file they share.

## Mac and iPhone

```
Sources/Shared/   Model, Store, Fireworks, BoardView, CalendarView, Palette
Sources/Mac/      App, ContentView, Platform, SettingsView
Sources/iOS/      App, ContentView, Platform, SettingsView
```

`Shared/` is 91% of the code and both platforms compile it unchanged. That isn't luck - the
data layer imports nothing but Foundation, and everything platform-shaped lives behind
`Platform.swift`, which exists in two versions with identical names so nothing in `Shared/`
knows which one it got.

`./check-portable.sh` type-checks `Shared/` against both SDKs in about two seconds. It exists
because the Mac build staying green says nothing about whether the shared layer still
compiles for iOS - an AppKit import in `Store.swift` would otherwise go unnoticed for weeks.
Run it before committing.

`./test.sh` proves the data layer: merging stays order-independent and loses nothing, files
from every earlier version open as they were meant, a file that can't be read is never written
over, and two devices sharing one file end up with the same board. It compiles the model sources
straight in with the checks in `Tests/`, needs only Command Line Tools, and takes about ten
seconds. Run it after any change to `Model.swift` or `Store.swift`.

Where the two genuinely differ, they differ on purpose:

- **The calendar** is a sidebar next to the board on the Mac and a tab on the phone, because
  a phone has no room to show both.
- **Row controls** are revealed on hover with a pointer and simply always present under a
  finger. The quick-remove `✕` is Mac-only: beside a finger it is mostly a way to delete
  something by accident, and long-press already opens the menu.
- **The entry field takes focus on launch on the Mac** and deliberately doesn't on the phone,
  where the keyboard would slide up over the board and the tab bar before you'd seen either.
- **Celebrations carry haptics on iOS**, where the tap in your hand is most of the payoff.

## Sync

Two devices pointed at the same file converge. That works because of two things in the
format rather than anything clever in the app.

**Deletions are tombstones.** Removing an entry sets `deletedAt` and leaves the row in the
file. It has to, because a merge cannot otherwise tell "this device deleted B" from "this
device has not seen B yet" - both look like B simply being absent - and would resurrect
everything you ever deleted. The app filters tombstones out; you never see them.

**Every record carries `updatedAt`.** Merging resolves each record on its own, keeping
whichever copy was touched last, so an edit on one device and a deletion on the other settle
by time rather than by which file happened to be read second. Settings merge the same way on
their own timestamp. The merge is order-independent - `merged(a, b)` and `merged(b, a)` give
the same answer, including for exact ties - which matters because two devices merge the same
pair of files separately and have to agree.

Timestamps are written with milliseconds. Foundation's stock ISO 8601 truncates to whole
seconds, which would make two edits in the same second tie and hand the decision to a
tiebreak instead of the clock.

Nothing overwrites. Every save re-reads the file and merges before writing, so a change made
between your last read and this write survives, and the app watches its directory so another
device's write is picked up while you are looking at it.

Timestamps come from a **hybrid logical clock** rather than straight from the wall clock.
Plain last-write-wins quietly assumes two devices agree what "last" means, and they don't - a
device running an hour behind would lose every exchange, silently, forever. So after reading
another device's work, this clock never issues a stamp below what it just read: an edit made
*after* seeing someone else's always outranks it, whatever the clocks say. Wrong clocks can
still misorder two edits that genuinely never saw each other, which nothing can fix, but they
can no longer undo one you made with the other already in front of you.

### When things go wrong

Most of the care here is about the difference between *no file* and *a file I can't read*.
The first means write ours; the second must never lead to a write, because the likeliest
cause is an iCloud file that hasn't finished arriving, and overwriting one of those replaces
the other device's board with this one's. An unreadable file is left alone, the problem is
shown in Settings, and the save is retried.

- **A corrupt file keeps its bytes and its place.** The contents are copied to a sidecar and
  the board carries on in the original file. Moving the file aside would be fine for a
  private copy and disastrous for a shared one - the other devices would watch their board
  vanish.
- **The read, merge and write happen inside one coordination block**, so another process on
  the machine can't slip a write in between our reading the file and replacing it.
- **A failed write says so** instead of being swallowed, and tries again.
- **A file that hasn't downloaded yet is requested**, not mistaken for an empty board.

### Setting it up

Open Settings (⌘, on the Mac, the Settings tab on the phone), choose **Sync**, and pick a
folder every device can reach - one shared from a Mac over the network, or one in Dropbox. Do
the same on the other device, pointing at the same folder. That's it - the app keeps
`doneboard.json` inside it.

On an iPhone, connect to the Mac's share in the Files app first (**Browse ▸ ⋯ ▸ Connect to
Server**). In the folder picker the Mac then appears in the **Browse** list under its own name,
with an eject button beside it. Two look-alikes are easy to pick by mistake, and both sync
happily with nothing else: the **Shared** item there is iCloud's list of files shared with you,
and a folder under **On My iPhone** exists only on the phone. Settings names the folder in use,
and a folder that is really shared already has `doneboard.json` in it once the Mac has joined.

Whatever was already on each device is merged in rather than replaced, so it doesn't matter
which one you set up first, or that both have entries the other has never seen. Joining a
folder is just the first exchange; every one after it works the same way. **Stop syncing**
takes the shared board back to a local copy without losing anything.

A folder that can't be reached - a share on a Mac that's asleep, or on a network the phone
isn't on - is not forgotten, and nothing done in the meantime depends on it coming back soon.
While syncing, each device also keeps its own copy of the board, updated on every save. Away
from the folder, the board still shows everything it last saw, and anything added is written
to that copy, so it survives the app being closed. Settings says the folder can't be reached,
with a **Try again** button, and the app also tries on its own - whenever it comes to the front,
and every so often while it stays open, since the first look after a phone has sat idle can fail
and the next one work. Once the
folder is back, whatever was done in the meantime merges in like any other exchange,
deletions included.

None of that waiting happens where you would feel it. Everything that touches the folder -
finding it at launch, reading and writing the shared file, watching it - runs in the
background, and the board opens from this device's copy, so a Mac with its lid shut costs a
board that catches up a moment later rather than an app that hangs. It used to be otherwise:
the phone looked the folder up and read the file on its main thread, and iOS closes an app
that stops answering for 10 to 20 seconds, which is less time than a share on a sleeping Mac
takes to give up. If the shared file hasn't answered after a few seconds, Settings says it is
still waiting.

Leaving the app straight after a change doesn't strand it on the phone. Each exchange asks iOS
for time to finish, and if the last attempt failed, the app tries again as you leave rather
than when it is next opened.

A folder is picked rather than a file because there's nothing to point at until an archive
exists, and folder permission covers the file the app creates inside it. That permission is
kept as a security-scoped bookmark, which is what lets it survive a relaunch - a bare path
would not, inside a sandbox. The folder's security scope is opened before the bookmark is
made, because iOS won't bookmark a folder outside the app's container otherwise. It needs no
developer account and no entitlement.

On a Mac you can still set `DONEBOARD_DATA` instead, which overrides everything and is handy
for tests.

### How changes get noticed

Reads and writes are coordinated through `NSFileCoordinator`, because a file in iCloud Drive
has a second writer - the sync daemon - and an uncoordinated read can catch it half-replaced.

The store keeps two watches on the file, because the two ways it can change look nothing
alike to the kernel. A sync daemon, and the app's own atomic save, *replace* the file: that
is a change to the directory, and the inode you were holding is no longer the file anyone
will write to. A writer that edits in place is the exact reverse - the directory never
changes at all. Watching only the directory misses the second case, which is easy to believe
you have covered until you try it.

Through a network share neither watch can be counted on to hear the other device, so while the
app is in front it also looks at the file every half minute. And the watches hear this device's
own writes too, failed ones included - an atomic write makes and removes a temporary file beside
the target. After a failed write, what they report is left to the retry, which waits five seconds
and doubles up to a minute; answering it at once once had a phone retrying a write the share was
refusing every 0.65 seconds.

## Diagnostics

The app keeps a record of what it has been doing, on the device, so that when something goes
wrong there is more to go on than "it froze".

- **An event log.** Launches, the app coming to the front and leaving it, the sync folder being
  found or not, every exchange with a shared file and how long it took - written as it happens,
  from a queue of its own, so it is still being written while the app is stuck. Two files of a
  megabyte each, oldest dropped first. The same lines go to the system log under
  `com.example.doneboard`, where Console shows them live.
- **Freeze reports.** A background thread checks on the main thread twice a second. When it
  stops answering, the main thread's stack is written down at one, three, eight and fifteen
  seconds, with the name of whatever timed work it was inside. Background work that runs for ten
  seconds - a read of a share that isn't answering - is written down the same way.
- **How the last run ended.** A session file says whether the app quit, went to the background,
  or was frozen when it stopped, which is how a phone app the system killed for freezing is still
  known about afterwards.
- **Crash reports.** An exception nothing caught is logged with its reason, and a fatal signal
  writes a backtrace before the process ends; the system still writes its own report as well.
  Reports the system hands over later through MetricKit are kept whole.
- **Which build.** Every build is stamped with the commit it came from, and the log and every
  report print it.

It all lives in `Diagnostics/` beside the data file - `~/Library/Application
Support/DoneBoardWorkspace/Diagnostics` on a Mac. **Settings ▸ Diagnostics** says how the last run ended
and names the newest report, and **Prepare diagnostics to share** gathers everything into one
text file for the share sheet. Nothing leaves the device any other way.

On a Mac with the phone paired, `Tools/diagnose.sh` collects it from both devices - the phone's
log straight out of the app's container, and the phone's own crash logs, which is where an iOS
watchdog kill shows up - demangles the Swift names, and prints what matters. A freeze that is
happening right now needs nothing extra: the app is already writing it down.

## Windows and Android

Not started. The format is the part that matters, and it is plain documented JSON that any
client on any platform can read, write and merge - the merge rules above are a few dozen
lines and depend on nothing Apple-specific. Nothing about your history is locked to this app.

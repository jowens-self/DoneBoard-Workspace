# Building with Xcode

`build.sh` and `build-ios.sh` are still the fast path for day-to-day work: plain `swiftc`
into a hand-made bundle, Command Line Tools only, a couple of seconds, no signing.

What they cannot do is sign, and three things need it:

- running on a physical iPhone,
- submitting to the App Store,
- notarizing a Mac build so it opens without a Gatekeeper warning.

Those go through a real Xcode project, generated from `project.yml`.

## Generating the project

```
brew install xcodegen      # once
xcodegen generate
open DoneBoard.xcodeproj
```

The project is build output, not source. It is gitignored, so there is no 2,000-line
`pbxproj` to review or merge. Change `project.yml` and regenerate - never edit the
generated project, because the next `xcodegen generate` replaces it wholesale. Adding or
removing a source file needs a regenerate too: the targets list folders, and a folder's
contents are read when the project is generated.

Two schemes come out of it, **DoneBoard (iPhone)** and **DoneBoard (Mac)**, both building
the same `Sources/Shared` the scripts do.

## Signing

`DEVELOPMENT_TEAM` in `project.yml` holds the team the builds are signed with. It ships empty:
put your own team ID there. It has to live there rather than in Xcode's Signing tab: a team
picked in Xcode is thrown away by the next regenerate, and device builds then fail with "No
profiles were found".

A free Apple ID is enough for the phone. Free profiles last seven days, after which the app
stops opening until it is built again. The paid Developer Program is what the App Store,
notarization, a year-long profile and CloudKit all need.

From the command line, with the phone plugged in and unlocked:

```
xcodebuild -project DoneBoard.xcodeproj -scheme "DoneBoard (iPhone)" \
  -destination 'id=<device UDID>' -allowProvisioningUpdates build
```

## The Mac target is sandboxed

`Resources/DoneBoard.entitlements` turns on the App Sandbox, plus the two file-access
entitlements the sync folder needs. User-selected read-write is what makes the chosen folder
readable after the open panel closes; app-scope bookmarks are what make that permission
survive a relaunch. Without the second one, sync silently stops on the second launch.

The sandbox also gives the app its own container. A Mac app built here therefore starts
without the data or the sync folder of the `build.sh` app, which is unsandboxed - pick the
sync folder again and the folder's contents merge in, with nothing lost on either side.
`ENABLE_HARDENED_RUNTIME` is on because notarization requires it.

## Icons

The iPhone icon comes from `Resources/Assets.xcassets`: current iOS reads the home-screen
icon from the compiled catalog, and Xcode generates every size from its single 1024.
`Resources/Info-iOS.plist` still lists the loose PNGs in `Resources/iOSIcons`; those are for
`build-ios.sh`, which copies files rather than compiling a catalog, and the two coexist
without complaint. `Tools/make-icon.sh` rebuilds all of them from one source.

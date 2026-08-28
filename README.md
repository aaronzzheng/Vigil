# Vigil

Keep your Mac awake on your terms, and see what else is keeping it awake. Menu bar
only — no Dock icon, no window, no dependencies, no App Store paperwork.

Requires macOS 14+ and Swift 5.9+.

## Build & run

```bash
./build-app.sh --install     # release build, copy to /Applications, launch
./build-app.sh               # just produce ./Vigil.app
./build-app.sh --universal   # arm64 + x86_64
```

The bundle is ad-hoc signed (`codesign --sign -`). No developer account, provisioning
profile, or notarization is involved. Vigil needs no privacy permissions at all.

## Using it

The menu bar cup fills in when Vigil is holding the Mac awake, and the tooltip says
why. Inside:

- **Keep awake** — a manual hold, indefinitely or for 30 minutes / 1 hour / 4 hours.
  A timed hold releases itself.
- **Keep display on too** — adds a display assertion. Off by default, because usually
  you want the screen to sleep even when the machine must not.
- **Also stay awake while an app `is frontmost` / `is running`** — pick any apps.
  `is running` is the one for long builds and downloads; `is frontmost` is for apps
  you want awake only while you are actually looking at them.
- **Keeping this Mac awake** — every process currently holding a sleep-preventing
  assertion, longest-held first. This is the "why won't my Mac sleep?" answer, and
  it is often something you forgot was open.

## There is deliberately no "while audio is playing" option

It was the first thing this app was going to do, and it turned out to be a placebo.
`coreaudiod` already takes a `PreventUserIdleSystemSleep` assertion on behalf of any
process with an active audio-out context, so your Mac already will not idle-sleep
while something is playing. Check it yourself:

```bash
pmset -g assertions
```

Look for `coreaudiod` holding `...context.preventuseridlesleep` with an `audio-out`
resource while music plays. An option here would have looked like it worked while
doing nothing.

## How it works

`Sources/Vigil/`

- **`VigilApp.swift`** — `@main`, `AppDelegate`, status item, popover, and the
  `SMAppService` login-item switch.
- **`SleepGuard.swift`** — the conditions, the `IOPMAssertion` hold/release, and the
  assertion inspector.
- **`PopoverView.swift`** — the SwiftUI popover.

Conditions are re-evaluated every 2 seconds. When one holds, Vigil takes an
`IOPMAssertionCreateWithName` assertion named after the reason, so Vigil shows up
legibly in anyone else's `pmset -g assertions` output too. The inspector reads
`IOPMCopyAssertionsByProcess` and credits assertions that `runningboardd` holds on
behalf of another process to the app that actually caused them.

## Known limits

- Conditions are ORed. Any one of them holds the Mac awake; there is no way to
  require several at once.
- Vigil prevents *idle* sleep. It cannot stop you closing the lid, and it does not
  override a forced sleep from the Apple menu.
- The blocker list shows what is asserting, not why it is a good idea. It has no way
  to release another process's assertion — that is the owning app's business.
- Watched apps are stored by bundle identifier, so two copies of the same app are
  indistinguishable.

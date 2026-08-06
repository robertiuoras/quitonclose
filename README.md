# QuitOnClose

A tiny macOS menu-bar utility that quits an app the moment you close its last window. Free, open source, no trial, ~300 lines of Swift.

It is a drop-in replacement for the paid FixRed ($4.99): per-app opt-in, launch at login, native universal binary (Apple Silicon + Intel), macOS 13 Ventura or later.

## Install

```bash
git clone https://github.com/robertiuoras/quitonclose.git
cd quitonclose
./build.sh --install
```

That builds `QuitOnClose.app`, ad-hoc signs it, copies it to `/Applications` and launches it. `./build.sh` on its own builds into `build/` without installing.

Then grant one permission: **System Settings > Privacy & Security > Accessibility** and switch **QuitOnClose** on. The app cannot see window counts without it, and without it, it never quits anything.

## Use

Click the menu-bar icon. Every running app is listed; tick the ones that should quit when their last window closes. The list is saved, so an app stays ticked after a reboot. Apps you ticked that are not running now appear under "Enabled but not running" so you can untick them.

"Open at Login" registers the app with `SMAppService`, macOS's supported login-item API.

## How it works

Every 0.5s it reads `kAXWindowsAttribute` for each ticked app and counts elements whose role is `AXWindow`. When that count goes from above zero to zero for two consecutive polls, it calls `terminate()` on the app, the same graceful quit as Cmd-Q, so an app with unsaved work still gets to ask you.

Deliberate choices:

- **Accessibility API, not `CGWindowListCopyWindowInfo`.** Minimized windows and windows on other Spaces stay in the Accessibility window list, so minimizing a window or switching Space is never mistaken for "no windows left".
- **An app must have shown a window under our watch before it can be quit**, so a background-only or just-launched app is left alone.
- **A three-second grace period after launch**, and a two-poll streak before quitting, so apps that briefly have no window while swapping one for another (Xcode, Safari moving a tab to a window) survive.
- **If an app does not answer the Accessibility query in 300ms, that poll is ignored**, never read as zero windows.
- Finder, Dock, Control Center, SystemUIServer, Notification Center and the login window can never be ticked.

## Verify it works

```bash
/Applications/QuitOnClose.app/Contents/MacOS/QuitOnClose --selftest
```

Opens TextEdit on a scratch file, presses that window's close button through the Accessibility API, and waits for QuitOnClose to terminate TextEdit. Prints `PASS` with the measured delay, or `FAIL` with the reason. It uses a temporary in-memory setting, so your saved app list is untouched.

`Tests/axprobe.swift` is a smaller probe that just prints the window count seen for every running app.

## Notes

- The build is ad-hoc signed. macOS ties Accessibility permission to the code signature, so after a rebuild you may have to remove and re-add QuitOnClose in the Accessibility list.
- Not sandboxed and not notarized, so `spctl -a` reports `rejected`. It still launches without any Gatekeeper dialog because a binary you compile locally carries no `com.apple.quarantine` attribute, and Gatekeeper's launch check applies to quarantined items. Measured on macOS 26.5 with SIP enabled: no quarantine attribute after `./build.sh --install`, app launched and ran. If you instead download a prebuilt copy from the internet, it *will* be quarantined and Gatekeeper will block it.

## License

MIT

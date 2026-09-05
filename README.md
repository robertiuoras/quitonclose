<img src="Assets/icon-1024.png" alt="" width="128" align="right">

# QuitOnClose

A tiny macOS menu-bar utility that quits an app the moment you close its last window. Free, open source, no trial, ~300 lines of Swift.

It is a drop-in replacement for the paid FixRed ($4.99): per-app opt-in, launch at login, native universal binary (Apple Silicon + Intel), macOS 13 Ventura or later.

[![Latest release](https://img.shields.io/github/v/release/robertiuoras/quitonclose?style=flat-square&color=F05138&label=release)](https://github.com/robertiuoras/quitonclose/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/robertiuoras/quitonclose/total?style=flat-square&color=475569&label=downloads)](https://github.com/robertiuoras/quitonclose/releases)
[![Platform](https://img.shields.io/badge/macOS%2013%2B-universal-475569?style=flat-square)](https://github.com/robertiuoras/quitonclose/releases/latest)
[![License](https://img.shields.io/github/license/robertiuoras/quitonclose?style=flat-square&color=475569)](LICENSE)


## Download

[**⬇ Download QuitOnClose.zip**](https://github.com/robertiuoras/quitonclose/releases/latest) — unzip, drag `QuitOnClose.app` into `/Applications`, open it.

macOS will say the app is from an unidentified developer the first time: right-click it in `/Applications` and choose **Open**, then **Open** again. That is a one-time step for any app that is not notarized by a paid Apple developer account.

Then grant one permission: **System Settings › Privacy & Security › Accessibility** and switch **QuitOnClose** on. Without it the app cannot see window counts and will never quit anything.

## Use

Click the menu-bar icon and switch **Intelligent closing** on. Supported everyday apps, including Messages, WhatsApp and Finder, get a 30-minute timer measured from their last foreground use. Switching to an app with Cmd-Tab resets its timer. You can choose 5, 15, 30 or 60 minutes.

Switch Intelligent closing off for **manual mode**. Each app has a submenu with Keep open, After the last window closes, and the same inactivity timers. Manual choices are saved separately and restored when you switch back. Existing ticked apps retain their last-window rule in manual mode, subject to the protections below. Intelligent mode starts off on existing installations so an update does not silently change how your apps close.

Finder closes its ordinary windows and keeps the desktop process running. Windows App can close after its last window disappears and its inactivity timer expires. Any remaining Windows App window protects it by default because a remote connection can remain active without local input or CPU use. Its submenu has an explicit **Allow idle closing with windows open** option if you want that behavior; enabling it can disconnect a remote session.

## Protections

- The foreground app is never closed. Each newly monitored app gets a full inactivity interval; switching modes or changing a rule restarts the timers.
- Quit requests are graceful, equivalent to Cmd-Q. Unsaved work can prompt you, and an app that refuses is not asked again until you reopen a window.
- Dialogs and save sheets prevent idle closure. Missing window or CPU information cannot authorize an idle close.
- Music and communication apps are held while system audio is active. A manually selected last-window rule for these apps waits at least five minutes after use or audio stops. The audio signal is system-wide, so unrelated audio may keep them open too.
- AI tools, terminals, browsers, development tools, sync clients, VPNs and virtual machines remain protected. Low CPU cannot prove remote work, a transfer, or a session has finished. Unknown apps require a manual rule.
- Finder is never terminated. Other essential macOS services cannot be selected.

## Startup and permission

**Open at Login** uses macOS's login-item service. The app also takes an exclusive process lock, so repeated launches create only one monitor and one menu icon. The installer retires the older `com.robert.quitonclose` LaunchAgent, preserving its plist as a dated disabled backup.

The menu shows a warning while Accessibility is unavailable. The app is ad-hoc signed, so installing a rebuilt binary can invalidate its previous grant even if System Settings still shows a tick. Remove the old QuitOnClose row in **System Settings > Privacy & Security > Accessibility**, add the installed app again and enable it.

A terminal can lend its Accessibility grant to a test binary. Check the actual GUI app separately:

```bash
open -n -g -a /Applications/QuitOnClose.app --args --permcheck
cat ~/Library/Logs/QuitOnClose-permcheck.log
```

The log must contain `true`. A passing terminal integration test does not establish the installed app's permission.

## Build and test

```bash
./build.sh
./build/QuitOnClose.app/Contents/MacOS/QuitOnClose --locktest
./build/QuitOnClose.app/Contents/MacOS/QuitOnClose --policytest
./build/QuitOnClose.app/Contents/MacOS/QuitOnClose --menutest
bash Tests/idle-integration.sh
./build.sh --install
```

`--locktest` needs no running copy of the new app. `--policytest` exercises the policy and native menu actions, then restores the settings it touched. `--menutest` retains the legacy last-window decision and row-interaction checks. The integration test creates disposable Cocoa apps and passes only those processes to the real monitor. It verifies a windowed idle app, an app that never opens a window, and an app that refuses to quit. The decision clock advances during the test; Accessibility scanning, CPU sampling and graceful quit requests remain real.

The app targets macOS 13 and builds arm64 plus x86_64 when the SDK supports both. It requires no cloud service or AI subscription.

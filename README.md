# InputDeck for macOS

**InputDeck** is a lightweight, open-source keystroke and live trackpad-contact overlay for macOS. Use it directly on your desktop or as a transparent OBS Browser Source. Built with Swift/AppKit and a small C bridge; no online accounts, dependencies, or cloud servers.

> **Status: v0.2.2 beta / Continuous Preview.** GitHub Actions builds both Apple Silicon and Intel macOS apps. Finger tracking and input permission behavior still need real-world testing on additional Mac models. Feedback and bug reports are welcome.

## Features

- **Custom key layout**: 1–24 selected physical keys, arranged automatically in four columns.
- **Global show/hide shortcut**: defaults to **Option + Shift + K**; customize modifier pair and key in Preferences.
- **Trackpad finger positions**: live dots representing finger contacts, where Apple's private MultitouchSupport API is available.
- **Trackpad ripples**: expanding waves at first touch and on mouse/trackpad click, plus subtle fading pulses along the path each finger followed; rendered in the native overlay and OBS.
- **Customizable opacity**, trackpad display, and click-through mode.
- **Saved settings and position** between launches.
- **OBS integration** via a local, transparent Browser Source on `127.0.0.1:8787`.
- Works offline and does not record or upload keyboard input.

## Download prebuilt app (no development tools needed)

For the **newest development build** (automatically refreshed after each successful push to `main`), use **[InputDeck Continuous Preview](https://github.com/N29dev/InputDeck/releases/tag/continuous)**. For numbered, versioned betas use **[GitHub Releases](https://github.com/N29dev/InputDeck/releases)**. Expand **Assets** to download:

- `InputDeck-macOS-AppleSilicon.zip` — M1/M2/M3/M4/M5 Macs.
- `InputDeck-macOS-Intel.zip` — Intel Macs.

Unzip the file, drag `InputDeck.app` into **Applications**, and open it. Grant **Input Monitoring** in **System Settings → Privacy & Security** when prompted, then restart InputDeck if the keys don't light up.

**Important:** This beta is **ad-hoc signed, not Apple Developer ID signed or notarized**. Depending on your security settings, macOS may refuse the first launch. If you trust the code from this repository, open the app from Finder using Control-click → **Open**, or use the **Open Anyway** option under **System Settings → Privacy & Security** after a blocked launch. Do not disable Gatekeeper globally.

**Continuous Preview:** The [macOS Build workflow](.github/workflows/build.yml) compiles both architectures on pushes to `main`, verifies their ad-hoc signatures, and only then refreshes the two ZIPs attached to the reusable `continuous` GitHub prerelease. Its tag intentionally moves to the tested commit. This makes the download URL permanent without creating a new beta for every minor change. Never treat `continuous` as an immutable version or cite it as a fixed source revision.

**Versioned betas:** Pushing an explicit `v*` tag still creates a separate, immutable-by-convention numbered prerelease through [the release workflow](.github/workflows/release.yml). These releases do not update when `main` changes.

### Maintainer: publish a numbered beta

After committing changes to `main`, tag the version you want to release:

```bash
git pull --ff-only
git tag v0.2.3-beta.1
git push origin v0.2.3-beta.1
```

The tag triggers [the release workflow](.github/workflows/release.yml). Confirm both build jobs pass in GitHub Actions before sharing the Releases link. Do not create a GitHub release manually for the same tag while the workflow is publishing it. Ordinary changes merged into `main` need **no manual tagging** to update Continuous Preview.

## Install from source

Requires **macOS 12+**, Mac hardware with a trackpad for finger visualization, and Xcode Command Line Tools (or Xcode). Both Apple Silicon and Intel builds are intended but still require testing.

```bash
xcode-select --install  # only if needed
./build.sh
open build/InputDeck.app
```

If you downloaded the ZIP and macOS prevents the script from running, open Terminal in the extracted folder and use `bash build.sh`. You can move `build/InputDeck.app` to `/Applications` after building.

**Permissions:** InputDeck needs **System Settings → Privacy & Security → Input Monitoring** to observe key states and its global shortcut. If it doesn't work after granting permission, restart the app, and use **Retry keyboard permission** in the menu bar. Some systems may request Accessibility permission as well. macOS may restrict overlays in certain fullscreen or secure-input contexts.

## Keyboard not highlighting? (Troubleshooting)

1. **Quit InputDeck fully** from its menu bar menu (don't just close the overlay).
2. Open **System Settings → Privacy & Security → Input Monitoring** and enable the current `InputDeck.app`. If you have rebuilt or moved the app, remove stale duplicates and use **+** to select the current app.
3. Relaunch InputDeck, open its menu bar menu, and check **Keyboard: active**. If it says **permission needed**, allow Input Monitoring. If it says **listener unavailable**, select **Retry keyboard permission**, then restart the app.
4. Hold **W** or **Space** for one second in TextEdit or Finder to verify the highlight, then check Roblox. Test the native overlay first; OBS uses the same input state.
5. If the native overlay works but OBS doesn't, ensure there is only one InputDeck instance (only one can bind to port 8787), and refresh the OBS Browser Source.

The overlay uses both passive event notifications and a 60fps current-key-state check for *only your selected keys*. It does not record or persist a history of typed keys. macOS may block monitoring during secure input and in some fullscreen/game environments.

## Preferences

Click the **keyboard icon** in the macOS menu bar → **Preferences…**.

- **Tracked keys:** comma-separated, for example `Q, W, E, R, A, S, D, F, Shift, Ctrl, C, V, Space`. You may choose different letters, digits, arrows, F1–F12, modifiers, or common special keys (up to 24 distinct keys).
- **Global shortcut:** select a two-modifier combination and a letter or function key. Default: `Option + Shift + K`. The shortcut toggles **only the native overlay**; the OBS Browser Source remains live.
- **Show trackpad:** uncheck to use only the keyboard overlay.
- **Opacity:** adjust the background opacity from 40% to 100%.

**Position and Preferences:** New installs center the overlay by default; its menu includes **Position: center** and four corner positions. Existing custom positions are preserved. Opening **Preferences** temporarily hides the overlay so settings are never covered; closing or saving restores the overlay if it was enabled. Use **Toggle click-through (to drag)** to drag the overlay anywhere without affecting gameplay. Position and settings are saved automatically.

Settings are stored in macOS `UserDefaults` for bundle ID `kz.n29.inputdeck`. No key history is persisted.

**Keyboard layouts:** Keys are based on US ANSI *physical key codes*, not letters under your current input language. ISO keyboard differences may require a future key-recording mode.

## OBS Browser Source

1. Start InputDeck.
2. Open OBS Studio → **Sources → + → Browser**.
3. Set the URL to `http://127.0.0.1:8787/`.
4. Set the source width to **503** (or **266** if trackpad is hidden).
5. Set the source height using `max(224, 52 + ceil(number_of_keys / 4) * 43)` pixels. With the default 13-key layout, use **224**. For 24 keys, use **310**.
6. Position and resize the Browser Source in your OBS canvas as desired.

Note: The Browser Source's dimensions are set manually in OBS. If you change the number of selected keys, increase its height as needed to avoid clipping. Hide the desktop overlay without hiding your OBS input feed.

Open `http://127.0.0.1:8787/?demo=1` in a browser for a demo animation **when the live app isn't connected**.

Touch ripples are local visual effects only, not saved input histories. Each touch is associated with its contact identifier so multiple fingers leave independent trails; a physical click produces an extra bright pulse when a finger is on the trackpad. OBS uses the same coordinates via the localhost stream. The effects need an active, compatible trackpad connection and the click effect needs keyboard/mouse Input Monitoring access.

## Privacy & security

- The app listens to **macOS global key events** to determine whether configured keys are down and to recognize the visibility shortcut. It does not persist keystrokes or typed text, and does not read clipboard contents.
- Only the **current state of the selected keys and trackpad contacts** is sent to the local OBS page. If you choose keys used in passwords, their press states may be visible in a recording: choose keys responsibly.
- The HTTP server binds to `127.0.0.1` only. Cross-origin access to the live feed is not enabled, so arbitrary websites cannot fetch it via normal cross-origin browser requests.
- Finger locations use **Apple's undocumented/private MultitouchSupport framework**. This might fail after OS updates, may not work on every trackpad, and is not Mac App Store compatible as currently implemented. The app shows “Trackpad unavailable” when it cannot initialize this feature.
- This is a source release, ad-hoc signed by the local build script. It is **not notarized**. Gatekeeper may show a warning when distributing a binary; review code before granting Input Monitoring access.

## Project layout

- `main.swift`: AppKit overlay, preferences, keyboard monitoring and global hotkey.
- `Bridge.c` / `Bridge.h`: multitouch callback and localhost HTTP Server-Sent Events (SSE) streaming.
- `overlay.html`: OBS transparent page.
- `Info.plist`: macOS bundle metadata.
- `build.sh` / `Launch-InputDeck.command`: builds a local `.app` with native Apple tooling.
- `.github/workflows/build.yml`: macOS GitHub Actions compile check and temporary downloadable build artifact.
- `.github/workflows/release.yml`: prebuilt Apple Silicon / Intel `.app` ZIPs and automatic tagged GitHub Releases.

## Publishing to GitHub

When you have installed and authenticated [GitHub CLI](https://cli.github.com/):

```bash
gh auth login
gh repo create N29dev/InputDeck --public --source=. --remote=origin --push
```

Run this **from the project folder**. If the repository already exists, use regular `git remote` and `git push` commands instead. A `git init` and initial commit are required for GitHub CLI to push (see `publish-github.sh`).

## Contributing

Pull requests and issues are welcome. Please report macOS version, hardware model (Apple Silicon/Intel), whether keyboard input works, whether trackpad finger dots appear, and any error output. Avoid attaching private input recordings. Keep the app local-first and avoid adding analytics or key logging.

## License

MIT, see [LICENSE](LICENSE).

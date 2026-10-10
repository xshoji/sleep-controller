# Development guide

Keep README.md focused on users. Put implementation, build, and verification details here. Write both documents in English.

## Project layout

- `App.swift`: sleep-state parsing, administrator commands, AppKit menus, and self-tests.
- `Info.plist`: bundle metadata and menu-bar-only configuration (no Dock icon).
- `build.sh`: compilation, app bundle assembly, and ad-hoc signing.

The app uses Swift, AppKit, and AppleScript without an Xcode project or external runtime. There is no privileged helper, persistent root daemon, or launch-at-login feature.

## Build

Install Apple's Command Line Tools with `xcode-select --install` if needed. Quit the running app before rebuilding.

```bash
./build.sh
open build/SleepController.app
```

The script compiles with `swiftc -O -warnings-as-errors` for the current CPU architecture, targeting macOS 13. It signs the completed bundle with `codesign --force --sign -`; no certificate or Apple ID is needed. Developer ID signing and notarization are not performed.

Pass `arm64` or `x86_64` to `build.sh` to target that architecture explicitly.

## Release

`.github/workflows/release.yml` runs when a tag such as `1.2.3` is pushed (no `v` prefix). It builds arm64 and x86_64 app bundles, packages them as `SleepController-arm64.zip` and `SleepController-x86_64.zip`, and creates a GitHub Release with generated release notes. Builds use ad-hoc signing without notarization. Before building, the workflow sets `CFBundleShortVersionString` in `Info.plist` to the tag name. `CFBundleVersion` stays unchanged; the workflow does not commit the version change back to the repository.

The previous README listed macOS 26.7.1 / Apple M5 / Swift 6.4 as its verification environment. Treat that as a historical report, not a compatibility guarantee. Older macOS versions and Intel Macs remain unverified.

## Behavior and constraints

- Change only the system-wide setting with `/usr/bin/pmset -a disablesleep 1` or `0`. Do not change idle-sleep timeouts.
- Read state with `pmset -g` at startup, when the menu opens, after operations, and every 15 seconds.
- Require the `System-wide power settings:` and `Currently in use:` headers. A single `SleepDisabled 1` means ON; `0` means OFF. A missing key in otherwise valid output means OFF, matching Apple's default. Failed reads, duplicate keys, invalid values, and malformed output mean unknown.
- Read back after a successful change. Report an error if the requested state is not observed. Authentication cancellation is silent and triggers a refresh; normal ON/OFF operations have no confirmation or success dialogs.
- Every user-requested mode change runs the administrator command, even when `SleepDisabled` already matches. Switching between normal ON and Keep Display On must not bypass authentication. AppleScript may reuse authorization as described below.
- Do not automatically restore the startup setting: another app may have changed it. Apps using the same setting cannot distinguish ownership. OFF clears their setting too, but not separate assertions such as `caffeinate`.
- When quitting while ON or unknown, offer OFF and quit, cancel, or quit with the setting unchanged. Failed OFF authentication or readback prevents quitting. Forced termination may bypass this prompt.
- Never assume that setting readback proves lid-closed operation. `disablesleep` is not fully documented in the public macOS manual, and behavior may vary by hardware and OS.
- Keep Display On holds a `ProcessInfo.beginActivity` token with `.idleDisplaySleepDisabled`, separately from the system-wide setting. Enable it only after ON succeeds; release it on normal ON, successful OFF, observed external OFF, or termination. Failed authentication/readback preserves the display mode unless OFF is observed. It starts disabled at launch, uses no child process or extra administrator command, and does not alter display timeouts or lock settings.
- A held token indicates a requested display assertion, not proof of display or automatic lock behavior. Do not promise prevention of screen savers, manual locks, or managed locks.

## Administrator authentication

If `/etc/pam.d/sudo_local` contains an active `auth sufficient pam_tid.so` entry, run fixed commands through `/usr/bin/sudo -k -S -p ''` using `Process`. Set stdin to `/dev/null`; the app must not collect passwords. `-k` ignores and does not update sudo's credential cache. Set `LC_ALL=C` so failure messages can be classified.

If Touch ID cancellation or unavailability falls back to password input, closed stdin prevents entry. Treat `sudo: no password was provided` as cancellation and do not retry through password authentication.

Without that PAM entry, use AppleScript's `do shell script ... with administrator privileges`. macOS may reuse authentication, so a prompt is not guaranteed for every operation. AppleScript error `-128` means cancellation.

Run only fixed commands, not the whole app, as root. Do not modify sudoers, PAM, or SIP, or add a root daemon. The app does not send Apple Events to other apps and does not depend on permission to automate them.

User-facing Touch ID setup is documented in [README.md](README.md#optional-touch-id-setup). Apple's implementation does not require a TTY, but GUI authentication still needs testing on the target Mac.

## Targeted checks

These commands do not change power settings:

```bash
build/SleepController.app/Contents/MacOS/SleepController --self-test
build/SleepController.app/Contents/MacOS/SleepController --status
```

Self-tests cover state parsing, PAM entry detection, and administrator result classification. `--status` prints `Sleep Prevented`, `Sleep Allowed`, or `Unknown` and exits with code 1 for unknown.

To check GUI administrator authentication without changing power settings, quit the normal app first:

```bash
open build/SleepController.app --args --auth-check
```

A reported UID of `0` means `/usr/bin/id -u` ran as root. Cancellation is silent; failure shows a dialog.

## Manual integration checks

These steps change system power settings and require administrator authentication. Leave sleep prevention OFF when finished.

1. Record the initial `pmset -g` output and compare it with the menu state.
2. Cancel authentication for ON and confirm that the setting stays unchanged. Then approve it and check that the UI and `SleepDisabled 1` agree.
3. Disconnect external displays, place the Mac on a ventilated desk, and start a heartbeat process:

   ```bash
   while :; do date '+%Y-%m-%d %H:%M:%S'; sleep 2; done > /tmp/sleepcontroller-heartbeat.log
   ```

4. Close the lid for about two minutes, reopen it, and inspect `tail -n 80 /tmp/sleepcontroller-heartbeat.log` in another terminal. Continuous entries roughly two seconds apart indicate that the process kept running under those conditions; a gap matching the closed-lid interval indicates failure. Test AC and battery power separately.
5. Turn OFF and repeat with no other sleep-prevention apps or clamshell conditions. Confirm that entries pause. Stop the heartbeat with Control-C and delete its log.
6. While the app is running, change `sudo pmset -a disablesleep 1` and `0` in Terminal. Check that the menu follows when reopened or within 15 seconds. Exercise each quit option while ON, then restore OFF.
7. Select **Prevent Sleep & Keep Display On** and check `pmset -g assertions` for a `PreventUserIdleDisplaySleep` assertion named `SleepController Keep Display On`. Switch to **Prevent Sleep** and confirm that this assertion disappears while `SleepDisabled` stays `1`. Confirm that switching in either direction requests administrator authentication and that cancellation preserves the original mode. Repeat strong ON followed by OFF, and external OFF followed by a refresh. Check that cancelling OFF authentication preserves strong ON.
8. With strong ON active and the lid open, leave the Mac untouched longer than its configured display sleep and screen saver delays. Check display sleep, screen saver activation, and automatic lock separately on AC and battery power. Confirm that manual lock still works. Quit with **Quit Without Changes**: the display assertion must disappear while `SleepDisabled` stays `1`. Relaunch and confirm normal ON, then restore OFF. Test forced termination separately to check assertion cleanup.

Use `pmset -g log` Sleep/Wake records as supporting evidence. Setting readback alone does not verify lid-closed behavior or protect against battery depletion, thermal protection, network failures, service limits, or process termination.

## References

- [Apple TN2065](https://developer.apple.com/library/archive/technotes/tn2065/_index.html): archived documentation on AppleScript administrator authentication and error handling.
- [Apple pmset source](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m): setting and displaying system-wide `SleepDisabled`.
- [Apple powerd settings](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmconfigd/PMSettings.m): treating a missing key as false.
- [Apple pam_tid source](https://github.com/apple-oss-distributions/pam_modules/blob/main/modules/pam_tid/pam_tid.c): Aqua-session checks and sudo Touch ID authentication.
- [Sleepless](https://github.com/Aboudjem/Sleepless): MIT-licensed reference. Its author reports lid-closed operation on macOS 26.3; this is not a guarantee for this app or M5 hardware. No code was copied, and its sudoers approach is not used here.

# SleepController

A small macOS menu bar app for keeping local processes running with your MacBook's lid closed.

It changes the system-wide sleep setting. Lid-closed behavior may vary by Mac model and macOS version; verify it on your Mac before relying on it.

## Get started

Requires macOS 13 or later and Apple's Command Line Tools (`xcode-select --install`). Older macOS versions and Intel Macs have not been verified.

```bash
./build.sh
open build/SleepController.app
```

No Xcode project, Apple ID, or paid developer membership is required.

### About code signing & Gatekeeper

Local builds and GitHub Releases use ad-hoc signing, not Developer ID signing, and are not notarized by Apple. Gatekeeper may block a downloaded app from opening.

If this happens, open **System Settings → Privacy & Security**, click **Open Anyway** for SleepController, and confirm the prompt. Only override the warning if you trust the app.

Alternatively, remove the quarantine attribute from the app bundle using Terminal. This bypasses Gatekeeper's quarantine-based launch check; it does not notarize the app. Only run this command if you trust the app. Replace the path if you installed it elsewhere:

```bash
xattr -dr com.apple.quarantine /Applications/SleepController.app
```

## Usage

1. Click the **Zzz** menu bar icon and choose **Prevent Sleep**.
2. Approve the macOS administrator prompt. Touch ID is used if configured for sudo; otherwise, macOS requests administrator authentication.
3. Choose **Allow Sleep (Default)** when finished. This restores normal sleep behavior; it does not put your Mac to sleep immediately.

The icon shows **Zzz** when sleep is allowed, **Zzz with a prohibition mark** when sleep is prevented, and a **question mark** when the state is unknown. Menu checkmarks and the tooltip also show the current state. The app version appears above **Quit SleepController**.

When quitting while sleep is prevented or the state is unknown, choose **Allow Sleep and Quit**, **Cancel**, or **Quit Without Changes**. Cancelling authentication leaves the setting unchanged.

### Optional Touch ID setup

On macOS 14 or later, you can enable Touch ID for sudo. **This changes authentication for all sudo commands, not just this app.** The app does not configure it automatically.

If `/etc/pam.d/sudo_local` does not exist, copy the standard template. The copy command does not overwrite an existing file. Then open the configuration; initial setup requires an administrator password.

```bash
sudo cp -n /etc/pam.d/sudo_local.template /etc/pam.d/sudo_local
sudo nano /etc/pam.d/sudo_local
```

Uncomment this line and save, preserving any existing configuration:

```text
auth       sufficient     pam_tid.so
```

You need an enrolled fingerprint and a local GUI login session. If Touch ID is unavailable, the app does not fall back to password authentication; use the Terminal command under [Recovery and removal](#recovery-and-removal) to restore sleep. To undo this setup, comment out the line you enabled.

## Important

- **Quitting does not automatically restore sleep.** The setting may persist after a crash, logout, or restart. There is no automatic timeout or battery monitoring.
- **Allow Sleep** also clears the same setting enabled by other apps. It does not stop separate sleep-prevention mechanisms such as `caffeinate`, or change your idle-sleep timeout.
- Keep your Mac ventilated. Do not run it with the lid closed inside a bag or enclosed space; sustained work increases heat and battery use.
- Sleep prevention cannot protect against battery depletion, protective shutdowns, network failures, or processes exiting.

## Recovery and removal

If the app crashes or cannot restore normal sleep, reopen it and choose **Allow Sleep (Default)**, or run:

```bash
sudo /usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -g
```

Check for `SleepDisabled 0` under `System-wide power settings:`. An absent `SleepDisabled` key in that section also means OFF.

To uninstall, allow sleep, quit the app, and delete `build/SleepController.app`.

Development and verification details are in [AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE).

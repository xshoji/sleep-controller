import AppKit

private enum SleepSetting: String {
    case on = "Sleep Prevented"
    case off = "Sleep Allowed"
    case unknown = "Unknown"

    var value: Int {
        self == .on ? 1 : 0
    }
}

private let pmsetPath = "/usr/bin/pmset"
private let touchIDConfig = "/etc/pam.d/sudo_local"
private let refreshInterval: TimeInterval = 15
private let userCancelled = -128

private func statusImage(_ setting: SleepSetting) -> NSImage {
    if setting == .unknown {
        return NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Sleep status unknown")!
    }

    let iconSize: CGFloat = 18
    let strokeWidth: CGFloat = 0.75
    let sleep = NSImage(systemSymbolName: "zzz", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 14, weight: .bold))!
    let image = NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: false) { bounds in
        sleep.draw(in: bounds.insetBy(dx: 2, dy: 2))
        guard setting == .on else { return true }

        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        circle.lineWidth = strokeWidth
        NSColor.black.setStroke()
        circle.stroke()

        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: 3.5, y: 14.5))
        slash.line(to: NSPoint(x: 14.5, y: 3.5))
        slash.lineWidth = strokeWidth
        slash.stroke()
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = setting == .on ? "Sleep prevented" : "Sleep allowed"
    return image
}

private func parseSetting(_ output: String) -> SleepSetting {
    let lines = output.split(whereSeparator: \.isNewline)
        .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
    guard lines.contains(["System-wide", "power", "settings:"]),
          lines.contains(["Currently", "in", "use:"]) else { return .unknown }

    let settings = lines.filter { $0.first == "SleepDisabled" }
    // powerd treats an absent SleepDisabled key as false. Reject malformed output.
    guard !settings.isEmpty else { return .off }
    guard settings.count == 1, settings[0].count == 2 else { return .unknown }

    switch settings[0][1] {
    case "1": return .on
    case "0": return .off
    default: return .unknown
    }
}

private func readSetting() -> SleepSetting {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: pmsetPath)
    process.arguments = ["-g"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return .unknown }
        return parseSetting(output)
    } catch {
        return .unknown
    }
}

private enum AdminResult: Equatable {
    case success(String)
    case cancelled
    case failure(String)

    init(status: Int32, output: String) {
        if status == 0 {
            self = .success(output.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        // Cancelled/unavailable Touch ID falls back to our closed stdin.
        if output.contains("sudo: no password was provided") {
            self = .cancelled
            return
        }
        self = .failure("Administrator command failed.\n\(output)")
    }
}

private func hasTouchID(_ config: String) -> Bool {
    config.split(whereSeparator: \.isNewline).contains { line in
        let fields = line.split(whereSeparator: \.isWhitespace)
        return fields.count >= 3 && fields[0] == "auth"
            && fields[1] == "sufficient" && fields[2] == "pam_tid.so"
    }
}

private func runAdmin(_ arguments: [String]) -> AdminResult {
    let config = (try? String(contentsOfFile: touchIDConfig, encoding: .utf8)) ?? ""
    if hasTouchID(config) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // -k ignores and does not update sudo's credential cache. PAM supplies the UI.
        process.arguments = ["-k", "-S", "-p", ""] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, value in value }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            guard process.terminationReason == .exit else {
                return .failure("Administrator command failed.\n\(output)")
            }
            return AdminResult(status: process.terminationStatus, output: output)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // Only fixed commands constructed below reach this function; no user input.
    let command = arguments.joined(separator: " ")
    guard let script = NSAppleScript(source:
        "do shell script \"\(command)\" with administrator privileges") else {
        return .failure("Could not create AppleScript.")
    }

    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    guard let error else { return .success(result.stringValue ?? "") }
    let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
    if number == userCancelled { return .cancelled }

    let message = error[NSAppleScript.errorMessage] as? String ?? "Administrator command failed."
    return .failure("\(message)\nError code: \(number.map(String.init) ?? "Unknown")")
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let onItem = NSMenuItem(title: "Prevent Sleep", action: #selector(turnOn), keyEquivalent: "")
    private let offItem = NSMenuItem(title: "Allow Sleep (Default)", action: #selector(turnOff), keyEquivalent: "")
    private var setting = SleepSetting.unknown
    private var busy = false
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        for item in [onItem, offItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let versionItem = NSMenuItem(title: "Version \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let quit = NSMenuItem(title: "Quit SleepController…", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        refresh()

        timer = Timer(timeInterval: refreshInterval, target: self,
                      selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)

        if CommandLine.arguments.contains("--auth-check") {
            DispatchQueue.main.async { self.checkAuth() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    @objc private func refresh() {
        guard !busy else { return }
        setting = readSetting()
        render()
    }

    private func render() {
        onItem.isEnabled = !busy && setting != .on
        offItem.isEnabled = !busy && setting != .off
        onItem.state = setting == .on ? .on : .off
        offItem.state = setting == .off ? .on : .off
        statusItem.button?.image = statusImage(setting)
        statusItem.button?.toolTip = busy ? "Updating sleep setting…" : setting.rawValue
    }

    private func alert(_ title: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    @objc private func turnOn() {
        _ = change(.on)
    }

    @objc private func turnOff() {
        _ = change(.off)
    }

    private func change(_ requested: SleepSetting) -> Bool {
        guard !busy, requested != .unknown else { return false }
        refresh()
        guard setting != requested else { return true }

        busy = true
        render()
        NSApp.activate(ignoringOtherApps: true)
        let result = runAdmin([pmsetPath, "-a", "disablesleep", String(requested.value)])
        busy = false
        refresh()

        switch result {
        case .cancelled:
            return false
        case .failure(let message):
            alert("Could not change sleep setting", "\(message)\nCurrent status: \(setting.rawValue)")
            return false
        case .success:
            guard setting == requested else {
                alert("Could not verify sleep setting",
                      "Current status: \(setting.rawValue)\nCheck for conflicts with other apps or compatibility with this macOS version. To allow sleep, run sudo pmset -a disablesleep 0 in Terminal.")
                return false
            }
            return true
        }
    }

    private func checkAuth() {
        busy = true
        render()
        NSApp.activate(ignoringOtherApps: true)
        let result = runAdmin(["/usr/bin/id", "-u"])
        busy = false
        refresh()
        switch result {
        case .success(let output):
            alert("Administrator authentication check", "UID: \(output) (0 means root)\nPower settings were not changed.")
        case .cancelled:
            return
        case .failure(let message):
            alert("Administrator authentication failed", message)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !busy else { return .terminateCancel }
        refresh()
        guard setting != .off else { return .terminateNow }

        NSApp.activate(ignoringOtherApps: true)
        let warning = NSAlert()
        warning.messageText = "Quit without allowing sleep?"
        warning.informativeText = "Current status: \(setting.rawValue)\nQuitting does not restore sleep. Allowing sleep also clears this setting if another app enabled it. An unknown status may mean sleep is still prevented."
        warning.addButton(withTitle: "Allow Sleep and Quit")
        warning.addButton(withTitle: "Cancel")
        warning.addButton(withTitle: "Quit Without Changes")
        switch warning.runModal() {
        case .alertFirstButtonReturn: return change(.off) ? .terminateNow : .terminateCancel
        case .alertThirdButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }
}

private func selfTest() {
    let header = "System-wide power settings:\n"
    let live = "Currently in use:\n sleep 1 (sleep prevented by powerd)\n"
    let cases: [(String, SleepSetting)] = [
        (header + " SleepDisabled\t1\n" + live, .on),
        (header + " SleepDisabled 0\n" + live, .off),
        (header + live, .off),
        ((header + " SleepDisabled 1\n" + live).replacingOccurrences(of: "\n", with: "\r"), .on),
        ("", .unknown),
        (live, .unknown),
        (header, .unknown),
        (header + " SleepDisabled 2\n" + live, .unknown),
        (header + " SleepDisabled\n" + live, .unknown),
        (header + " SleepDisabled 1 extra\n" + live, .unknown),
        (header + " SleepDisabled 0\n SleepDisabled 1\n" + live, .unknown)
    ]
    for (output, expected) in cases {
        precondition(parseSetting(output) == expected, "Unexpected state for: \(output)")
    }
    precondition(hasTouchID("# comment\nauth sufficient pam_tid.so\n"))
    precondition(hasTouchID("auth\tsufficient\tpam_tid.so # Touch ID"))
    precondition(!hasTouchID("#auth sufficient pam_tid.so"))
    precondition(!hasTouchID("auth sufficient pam_tid.so.fake"))
    precondition(!hasTouchID(""))
    precondition(AdminResult(status: 0, output: "0\n") == .success("0"))
    precondition(AdminResult(status: 1, output: "sudo: no password was provided\nsudo: a password is required") == .cancelled)
    precondition(AdminResult(status: 1, output: "pmset: invalid argument")
        == .failure("Administrator command failed.\npmset: invalid argument"))
    print("\(cases.count) state checks, 5 PAM config checks and 3 admin result checks passed")
}

if CommandLine.arguments.contains("--self-test") {
    selfTest()
} else if CommandLine.arguments.contains("--status") {
    let setting = readSetting()
    print(setting.rawValue)
    if setting == .unknown { exit(EXIT_FAILURE) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

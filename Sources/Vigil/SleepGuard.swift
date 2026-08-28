import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.pwr_mgt
import IOKit.ps

/// Holds power assertions while a condition says the Mac should stay awake, and
/// reports who else is holding one.
///
/// Deliberately absent: a "while audio is playing" condition. `coreaudiod`
/// already takes `PreventUserIdleSystemSleep` for any process with an active
/// audio-out context, so such an option would look like it worked while doing
/// nothing. Check for yourself with `pmset -g assertions`.
final class SleepGuard: ObservableObject {

    enum Duration: String, CaseIterable, Identifiable {
        case indefinitely = "Indefinitely"
        case thirtyMinutes = "For 30 minutes"
        case oneHour = "For 1 hour"
        case fourHours = "For 4 hours"

        var id: String { rawValue }
        var seconds: TimeInterval? {
            switch self {
            case .indefinitely: return nil
            case .thirtyMinutes: return 30 * 60
            case .oneHour: return 60 * 60
            case .fourHours: return 4 * 60 * 60
            }
        }
    }

    /// Whether a watched app counts when merely running, or only when in front.
    enum Trigger: String, CaseIterable, Identifiable {
        case frontmost = "is frontmost"
        case running = "is running"
        var id: String { rawValue }
    }

    struct Blocker: Identifiable {
        let id: String
        let processName: String
        let type: String
        let detail: String
        let since: Date?

        var friendlyType: String {
            switch type {
            case "PreventUserIdleSystemSleep", "NoIdleSleepAssertion": return "system sleep"
            case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": return "display sleep"
            case "PreventSystemSleep": return "sleep entirely"
            default: return type
            }
        }
    }

    /// Assertion types that actually keep a Mac from sleeping; everything else
    /// reported by IOKit is noise for our purposes.
    private static let sleepPreventingTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "NoIdleSleepAssertion",
        "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion",
        "PreventSystemSleep",
    ]

    @Published var isManuallyOn = false { didSet { manualChanged() } }
    @Published var duration: Duration = .indefinitely { didSet { manualChanged() } }
    @Published var keepDisplayOn = false { didSet { persist(); evaluate() } }
    @Published var trigger: Trigger = .frontmost { didSet { persist(); evaluate() } }
    @Published var watchedBundleIDs: [String] = [] { didSet { persist(); evaluate() } }
    @Published var staysActive = false { didSet { persist(); staysActiveChanged() } }
    @Published var scheduleEnabled = false { didSet { persist(); evaluate() } }
    @Published var scheduleStart = 9 { didSet { persist(); evaluate() } }
    @Published var scheduleEnd = 17 { didSet { persist(); evaluate() } }
    /// On by default: a forgotten hold flattening a laptop in a bag is the one
    /// failure mode of this app that actually costs you something.
    @Published var batteryFloorEnabled = true { didSet { persist(); evaluate() } }
    @Published var batteryFloor = 20 { didSet { persist(); evaluate() } }

    /// Why we are currently holding the Mac awake, or nil when we are not. May
    /// also explain why we have deliberately stopped.
    @Published private(set) var reason: String?
    /// Distinct from `reason`: a battery pause sets a reason while holding nothing.
    @Published private(set) var isHoldingAwake = false
    @Published private(set) var manualExpiry: Date?
    @Published private(set) var blockers: [Blocker] = []

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var timer: Timer?
    private var hasRequestedAccessibility = false

    /// Teams and Slack go idle after several minutes, so nudging well inside that
    /// keeps them green while injecting as few events as possible.
    private static let idleNudgeThreshold: Double = 25

    private let defaults = UserDefaults.standard

    // MARK: Lifecycle

    init() {
        watchedBundleIDs = defaults.stringArray(forKey: "Vigil.watched") ?? []
        keepDisplayOn = defaults.bool(forKey: "Vigil.keepDisplayOn")
        if let raw = defaults.string(forKey: "Vigil.trigger"),
           let value = Trigger(rawValue: raw) { trigger = value }
        staysActive = defaults.bool(forKey: "Vigil.staysActive")
        scheduleEnabled = defaults.bool(forKey: "Vigil.scheduleEnabled")
        if defaults.object(forKey: "Vigil.scheduleStart") != nil {
            scheduleStart = defaults.integer(forKey: "Vigil.scheduleStart")
            scheduleEnd = defaults.integer(forKey: "Vigil.scheduleEnd")
        }
        if defaults.object(forKey: "Vigil.batteryFloorEnabled") != nil {
            batteryFloorEnabled = defaults.bool(forKey: "Vigil.batteryFloorEnabled")
            batteryFloor = defaults.integer(forKey: "Vigil.batteryFloor")
        }
    }

    func start() {
        evaluate()
        refreshBlockers()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.evaluate()
            self?.nudgeIfIdle()
            self?.refreshBlockers()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        release()
    }

    private func persist() {
        defaults.set(watchedBundleIDs, forKey: "Vigil.watched")
        defaults.set(keepDisplayOn, forKey: "Vigil.keepDisplayOn")
        defaults.set(trigger.rawValue, forKey: "Vigil.trigger")
        defaults.set(staysActive, forKey: "Vigil.staysActive")
        defaults.set(scheduleEnabled, forKey: "Vigil.scheduleEnabled")
        defaults.set(scheduleStart, forKey: "Vigil.scheduleStart")
        defaults.set(scheduleEnd, forKey: "Vigil.scheduleEnd")
        defaults.set(batteryFloorEnabled, forKey: "Vigil.batteryFloorEnabled")
        defaults.set(batteryFloor, forKey: "Vigil.batteryFloor")
    }

    // MARK: Limits

    /// Gates the automatic conditions only. Flipping "Keep awake" by hand at
    /// midnight is an explicit act and is honoured regardless.
    var isWithinSchedule: Bool {
        guard scheduleEnabled else { return true }
        let parts = Calendar.current.dateComponents([.hour, .weekday], from: Date())
        guard let hour = parts.hour, let weekday = parts.weekday else { return true }
        guard (2...6).contains(weekday) else { return false }   // 1 == Sunday
        if scheduleStart <= scheduleEnd { return hour >= scheduleStart && hour < scheduleEnd }
        return hour >= scheduleStart || hour < scheduleEnd      // window crossing midnight
    }

    /// Non-nil when the battery is low enough that we should stop holding at all.
    private func batteryPause() -> String? {
        guard batteryFloorEnabled,
              let state = Self.batteryState(),
              state.isOnBattery, state.percent < batteryFloor
        else { return nil }
        return "Paused — battery at \(state.percent)%"
    }

    static func batteryState() -> (isOnBattery: Bool, percent: Int)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
                as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            let onBattery = (description[kIOPSPowerSourceStateKey] as? String)
                == kIOPSBatteryPowerValue
            return (onBattery, Int((Double(capacity) / Double(maximum) * 100).rounded()))
        }
        return nil
    }

    // MARK: Conditions

    private func manualChanged() {
        if isManuallyOn {
            manualExpiry = duration.seconds.map { Date().addingTimeInterval($0) }
        } else {
            manualExpiry = nil
        }
        evaluate()
    }

    /// The list is short and the watched app is usually absent, so this is a
    /// cheap thing to run on a timer.
    private func evaluate() {
        // A timed manual hold releases itself.
        if isManuallyOn, let expiry = manualExpiry, Date() >= expiry {
            isManuallyOn = false
            return
        }

        // A low battery overrides everything, including a manual hold.
        if let pause = batteryPause() {
            release()
            isHoldingAwake = false
            if reason != pause { reason = pause }
            return
        }

        var assertionReason: String?
        if isManuallyOn {
            assertionReason = manualExpiry == nil
                ? "Keeping awake"
                : "Keeping awake until \(Self.timeFormatter.string(from: manualExpiry!))"
        } else if isWithinSchedule, let app = matchingWatchedApp() {
            assertionReason = "\(app) \(trigger.rawValue)"
        }

        if let assertionReason {
            hold(named: assertionReason)
        } else {
            release()
        }

        // Staying active holds no assertion — it resets the idle clock instead —
        // but it does keep the Mac up, so it belongs in the status line.
        var display = assertionReason
        var active = assertionReason != nil
        if staysActive {
            if !isWithinSchedule {
                display = display ?? "Staying active — outside your hours"
            } else {
                let label = AXIsProcessTrusted() ? "Staying active"
                                                 : "Staying active (needs Accessibility)"
                display = display.map { "\($0) · \(label)" } ?? label
                active = true
            }
        }
        if display != reason { reason = display }
        if active != isHoldingAwake { isHoldingAwake = active }
    }

    // MARK: Staying active

    private func staysActiveChanged() {
        if staysActive, !AXIsProcessTrusted() { requestAccessibility() }
        evaluate()
    }

    /// Posts a mouse-moved event at the cursor's *current* position. It is a real
    /// HID event, so the idle clock resets, but the pointer does not move — unlike
    /// a jiggler, it never fights you for the cursor.
    ///
    /// `IOPMAssertionDeclareUserActivity` looks like the right call here and is
    /// not: it returns success while the idle counters keep climbing, so apps
    /// reading idle time never see it.
    private func nudgeIfIdle() {
        guard staysActive, isWithinSchedule, AXIsProcessTrusted() else { return }
        guard batteryPause() == nil else { return }
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= Self.idleNudgeThreshold else { return }

        let position = CGEvent(source: nil)?.location ?? .zero
        CGEvent(mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: position,
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func requestAccessibility() {
        guard !hasRequestedAccessibility else { return }
        hasRequestedAccessibility = true

        let alert = NSAlert()
        alert.messageText = "Vigil needs Accessibility access to stay active"
        alert.informativeText = "Resetting the idle clock means posting a real input event, "
            + "which macOS only allows apps you have trusted. Nothing else in Vigil needs it."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    private func matchingWatchedApp() -> String? {
        guard !watchedBundleIDs.isEmpty else { return nil }
        let watched = Set(watchedBundleIDs)
        switch trigger {
        case .frontmost:
            guard let front = NSWorkspace.shared.frontmostApplication,
                  let bundleID = front.bundleIdentifier, watched.contains(bundleID)
            else { return nil }
            return front.localizedName ?? bundleID
        case .running:
            for app in NSWorkspace.shared.runningApplications {
                if let bundleID = app.bundleIdentifier, watched.contains(bundleID) {
                    return app.localizedName ?? bundleID
                }
            }
            return nil
        }
    }

    // MARK: Assertions

    private func hold(named name: String) {
        if systemAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Vigil: \(name)" as CFString,
                &systemAssertion)
        }
        if keepDisplayOn, displayAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Vigil: \(name)" as CFString,
                &displayAssertion)
        }
        if !keepDisplayOn, displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
    }

    private func release() {
        if systemAssertion != 0 {
            IOPMAssertionRelease(systemAssertion)
            systemAssertion = 0
        }
        if displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
    }

    // MARK: Who else is keeping us awake

    private func refreshBlockers() {
        var out: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&out) == kIOReturnSuccess,
              let byProcess = out?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var found: [Blocker] = []
        for (pid, assertions) in byProcess {
            for assertion in assertions {
                guard let type = assertion["AssertType"] as? String,
                      Self.sleepPreventingTypes.contains(type)
                else { continue }

                let name = assertion["Process Name"] as? String ?? "pid \(pid)"
                // runningboardd holds assertions for other processes; credit those.
                var owner = name
                if let behalf = assertion["AssertionOnBehalfOfPID"] as? Int,
                   let real = NSRunningApplication(processIdentifier: pid_t(behalf))?.localizedName {
                    owner = real
                }
                if pid.int32Value == ownPID { owner += " (this app)" }

                found.append(Blocker(
                    id: String(describing: assertion["GlobalUniqueID"] ?? UUID().uuidString),
                    processName: owner,
                    type: type,
                    detail: assertion["AssertName"] as? String ?? "",
                    since: assertion["AssertStartWhen"] as? Date))
            }
        }
        // Longest-held first: those are the ones worth knowing about.
        let sorted = found.sorted { ($0.since ?? .distantFuture) < ($1.since ?? .distantFuture) }
        blockers = sorted
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}

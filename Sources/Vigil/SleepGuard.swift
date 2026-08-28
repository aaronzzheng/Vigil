import AppKit
import IOKit.pwr_mgt

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

    /// Why we are currently holding the Mac awake, or nil when we are not.
    @Published private(set) var reason: String?
    @Published private(set) var manualExpiry: Date?
    @Published private(set) var blockers: [Blocker] = []

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var timer: Timer?

    private let defaults = UserDefaults.standard

    var isHoldingAwake: Bool { reason != nil }

    // MARK: Lifecycle

    init() {
        watchedBundleIDs = defaults.stringArray(forKey: "Vigil.watched") ?? []
        keepDisplayOn = defaults.bool(forKey: "Vigil.keepDisplayOn")
        if let raw = defaults.string(forKey: "Vigil.trigger"),
           let value = Trigger(rawValue: raw) { trigger = value }
    }

    func start() {
        evaluate()
        refreshBlockers()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.evaluate()
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

        var newReason: String?
        if isManuallyOn {
            newReason = manualExpiry == nil
                ? "Keeping awake"
                : "Keeping awake until \(Self.timeFormatter.string(from: manualExpiry!))"
        } else if let app = matchingWatchedApp() {
            newReason = "\(app) \(trigger.rawValue)"
        }

        if let newReason {
            hold(named: newReason)
        } else {
            release()
        }
        if newReason != reason { reason = newReason }
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

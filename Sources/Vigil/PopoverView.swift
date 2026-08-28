import SwiftUI

struct PopoverView: View {
    @ObservedObject var guard_: SleepGuard
    @ObservedObject var loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            manualSection
            Divider()
            watchSection
            Divider()
            limitsSection
            Divider()
            blockerSection
            Divider()
            footer
        }
        .frame(width: 330)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(guard_.isHoldingAwake ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(guard_.reason ?? "Sleeping normally")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Manual hold

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Keep awake", isOn: $guard_.isManuallyOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 12))

            HStack(spacing: 8) {
                Picker("", selection: $guard_.duration) {
                    ForEach(SleepGuard.Duration.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 150)
                .disabled(!guard_.isManuallyOn)

                Spacer()
            }

            Toggle("Keep display on too", isOn: $guard_.keepDisplayOn)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 2)

            Toggle("Stay active", isOn: $guard_.staysActive)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 12))
            Text("Resets the idle clock so Teams and Slack stay green. "
                 + "The pointer never moves.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Watched apps

    private var watchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Also stay awake while an app")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("", selection: $guard_.trigger) {
                    ForEach(SleepGuard.Trigger.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }

            HStack(spacing: 6) {
                Menu {
                    ForEach(selectableApps, id: \.bundleID) { app in
                        Button {
                            toggle(app.bundleID)
                        } label: {
                            Text(guard_.watchedBundleIDs.contains(app.bundleID)
                                 ? "✓  \(app.name)" : "    \(app.name)")
                        }
                    }
                } label: {
                    Text("Choose apps")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Text(watchedSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(guard_.watchedBundleIDs.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Everything currently running, plus anything already watched that has quit —
    /// otherwise a watched app you closed becomes impossible to deselect.
    private var selectableApps: [(bundleID: String, name: String)] {
        var seen = Set<String>()
        var apps: [(bundleID: String, name: String)] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, seen.insert(bundleID).inserted else { continue }
            apps.append((bundleID, app.localizedName ?? bundleID))
        }
        for bundleID in guard_.watchedBundleIDs where seen.insert(bundleID).inserted {
            apps.append((bundleID, bundleID))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var watchedSummary: String {
        guard !guard_.watchedBundleIDs.isEmpty else { return "none selected" }
        let names = guard_.watchedBundleIDs.map { bundleID in
            selectableApps.first { $0.bundleID == bundleID }?.name ?? bundleID
        }
        return names.joined(separator: ", ")
    }

    private func toggle(_ bundleID: String) {
        if let index = guard_.watchedBundleIDs.firstIndex(of: bundleID) {
            guard_.watchedBundleIDs.remove(at: index)
        } else {
            guard_.watchedBundleIDs.append(bundleID)
        }
    }

    // MARK: Limits

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle("Weekdays only, from", isOn: $guard_.scheduleEnabled)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.system(size: 11))
                Picker("", selection: $guard_.scheduleStart) {
                    ForEach(0..<24, id: \.self) { Text(Self.hour($0)).tag($0) }
                }
                .labelsHidden().controlSize(.small).fixedSize()
                .disabled(!guard_.scheduleEnabled)
                Text("to").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $guard_.scheduleEnd) {
                    ForEach(0..<24, id: \.self) { Text(Self.hour($0)).tag($0) }
                }
                .labelsHidden().controlSize(.small).fixedSize()
                .disabled(!guard_.scheduleEnabled)
            }

            HStack(spacing: 6) {
                Toggle("Pause on battery below", isOn: $guard_.batteryFloorEnabled)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.system(size: 11))
                Picker("", selection: $guard_.batteryFloor) {
                    ForEach([10, 15, 20, 30, 40, 50], id: \.self) { Text("\($0)%").tag($0) }
                }
                .labelsHidden().controlSize(.small).fixedSize()
                .disabled(!guard_.batteryFloorEnabled)
            }

            Text("Hours gate the automatic conditions. A manual Keep awake always wins, "
                 + "except on low battery.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private static func hour(_ value: Int) -> String {
        switch value {
        case 0: return "12 AM"
        case 12: return "12 PM"
        case ..<12: return "\(value) AM"
        default: return "\(value - 12) PM"
        }
    }

    // MARK: Who else is holding the Mac awake

    private var blockerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Keeping this Mac awake")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            if guard_.blockers.isEmpty {
                Text("Nothing — it can sleep on schedule")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(guard_.blockers.prefix(5)) { blocker in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(blocker.processName)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Text(blocker.friendlyType)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 4)
                        if let since = blocker.since {
                            Text(Self.elapsed(since))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .help(blocker.detail)
                }
                if guard_.blockers.count > 5 {
                    Text("+ \(guard_.blockers.count - 5) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private static func elapsed(_ since: Date) -> String {
        let seconds = Int(max(0, Date().timeIntervalSince(since)))
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Toggle("Launch at login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Spacer()

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

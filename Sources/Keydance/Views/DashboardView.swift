import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var state: AppState

    private var snapshot: LiveSessionSnapshot { state.liveSession }
    private var visibleSentenceSpeeds: [SentenceSpeedSample] {
        Array(snapshot.sentenceSpeeds.suffix(5))
    }
    private var visibleAccuracySamples: [SentenceAccuracySample] {
        Array(snapshot.sentenceAccuracySamples.suffix(5))
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if state.trackerState == .permissionRequired { permissionCard }
                    sessionCard
                    overviewCards
                    recentActivity
                }
                .frame(maxWidth: 980)
                .padding(.horizontal, 26)
                .padding(.vertical, 24)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("KEYDANCE")
                    .font(.caption.weight(.bold))
                    .tracking(1.8)
                    .foregroundStyle(.secondary)
                Text("Your typing, at a glance")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("A quiet view of your current session.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TrackerPill(state: state.trackerState, color: statusColor, icon: statusIcon)
        }
    }

    private var permissionCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.open.rotation")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Input Monitoring is off")
                    .font(.headline)
                Text("Allow Keydance to observe timing so your session can update live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Allow access") { state.requestPermission() }
                .buttonStyle(.borderedProminent)
        }
        .dashboardCard()
    }

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current session")
                        .font(.headline)
                    Text(sessionMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(status: simpleStatus)
            }

            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(simpleStatus.title)
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(simpleStatus.color)
                    Text("Live status")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(speed(snapshot.rawWordsPerMinute))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("WPM")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                SessionStat(title: "Characters", value: "\(snapshot.printableCount)", icon: "character.cursor.ibeam")
                SessionStat(title: "Accuracy", value: accuracyValue, icon: "checkmark.seal")
                SessionStat(title: "Session", value: duration(snapshot.elapsed), icon: "clock")
            }

            HStack {
                Text(snapshot.hmm.modelStatus)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Finish session") { state.finishCurrentSession() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!snapshot.hasActiveSession)
                Button("Discard") { state.discardCurrentSession() }
                    .buttonStyle(.bordered)
                    .disabled(!snapshot.hasActiveSession)
            }
        }
        .dashboardCard(tint: simpleStatus.color)
    }

    private var overviewCards: some View {
        HStack(alignment: .top, spacing: 16) {
            metricCard(
                title: "Speed",
                subtitle: "Your pace in this session",
                icon: "gauge.with.dots.needle.67percent",
                color: .blue
            ) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(speed(snapshot.rawWordsPerMinute))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("WPM")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text("Based on your timed typing bursts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            metricCard(
                title: "Accuracy",
                subtitle: "Words and corrections",
                icon: "checkmark.circle",
                color: .green
            ) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(accuracyValue)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("overall")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text("\(snapshot.accuracyTotals.errorCharacters) recorded errors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent activity")
                        .font(.headline)
                    Text("A simple history of this session's bursts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !visibleSentenceSpeeds.isEmpty {
                    Text("\(visibleSentenceSpeeds.count) bursts")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if visibleSentenceSpeeds.isEmpty && visibleAccuracySamples.isEmpty {
                EmptyActivityView()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleSentenceSpeeds.enumerated()), id: \.element.id) { index, sample in
                        BurstRow(sample: sample)
                        if index < visibleSentenceSpeeds.count - 1 {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .dashboardCard()
    }

    private func metricCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    private var simpleStatus: SimpleStatus {
        guard snapshot.hasActiveSession else { return .unclear }
        if snapshot.hmm.currentPrintableCount > 0
            || snapshot.hmm.currentDeletionCount > 0
            || snapshot.hmm.currentBoundaryCount > 0 {
            return .typing
        }
        if snapshot.hmm.latestSentenceState == .likelyComplete {
            return .complete
        }
        return .unclear
    }

    private var sessionMessage: String {
        switch simpleStatus {
        case .typing: "Keydance is measuring this burst."
        case .complete: "That thought looks complete."
        case .unclear: snapshot.hasActiveSession ? "Keep typing to build a clear signal." : "Start typing to begin a session."
        }
    }

    private var accuracyValue: String {
        snapshot.accuracyTotals.sentenceCount > 0
            ? String(format: "%.1f%%", snapshot.accuracyTotals.accuracy * 100)
            : "—"
    }

    private func speed(_ value: Double) -> String {
        value > 0 ? String(format: "%.1f", value) : "—"
    }

    private func duration(_ value: TimeInterval) -> String {
        guard value > 0 else { return "—" }
        if value < 60 { return String(format: "%.0fs", value) }
        return String(format: "%.1fm", value / 60)
    }

    private var statusIcon: String {
        switch state.trackerState {
        case .running: "circle.fill"
        case .paused: "pause.fill"
        case .permissionRequired: "lock.trianglebadge.exclamationmark"
        case .secureInput: "lock.fill"
        case .interrupted: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        state.trackerState == .running ? .green : .orange
    }
}

private enum SimpleStatus {
    case typing
    case complete
    case unclear

    var title: String {
        switch self {
        case .typing: "Typing"
        case .complete: "Complete"
        case .unclear: "Unclear"
        }
    }

    var color: Color {
        switch self {
        case .typing: .green
        case .complete: .purple
        case .unclear: .orange
        }
    }
}

private struct TrackerPill: View {
    let state: TrackerState
    let color: Color
    let icon: String

    var body: some View {
        Label(state == .running ? "Tracking" : state.title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct StatusBadge: View {
    let status: SimpleStatus

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.bold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(status.color.opacity(0.12), in: Capsule())
    }
}

private struct SessionStat: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct BurstRow: View {
    let sample: SentenceSpeedSample

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: sample.isComplete ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(sample.isComplete ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(sample.isComplete ? "Completed burst" : "Current burst")
                    .font(.subheadline.weight(.medium))
                Text("\(sample.characterCount) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(sample.rawWordsPerMinute, specifier: "%.1f") WPM")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                Text(sample.intentionalWordsPerMinute.map { "\($0, specifier: "%.1f") focused" } ?? "calculating")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 13)
    }
}

private struct EmptyActivityView: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing to show yet")
                    .font(.subheadline.weight(.medium))
                Text("Your first burst will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
}

private extension View {
    func dashboardCard(tint: Color? = nil) -> some View {
        padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke((tint ?? Color.primary).opacity(tint == nil ? 0.08 : 0.18), lineWidth: 1)
            }
    }
}

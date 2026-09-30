import AppKit
import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    let onOpenTypingInsights: () -> Void
    @State private var showingDetails = false
    @State private var hoveringDetails = false
    @State private var hoveredMetricTitle: String?
    @State private var hoveredStatisticTitle: String?
    @State private var hoveredHeatmapCell: String?
    @State private var showingEditDistanceInfo = false
    @State private var shortTermInsightFlipped = false

    init(onOpenTypingInsights: @escaping () -> Void = {}) {
        self.onOpenTypingInsights = onOpenTypingInsights
    }

    private var snapshot: LiveSessionSnapshot { state.liveSession }
    private var historyPoints: [HistoricalMetricPoint] { state.store.historicalPoints }

    var body: some View {
        ZStack {
            DashboardBackground()

            ScrollView {
                VStack {
                    VStack(alignment: .leading, spacing: 30) {
                        if state.trackerState == .permissionRequired { permissionNotice }
                        header
                        primaryMetrics
                        detailedStatistics
                        graphs
                        visualAnalytics
                        insights
                    }
                    .frame(maxWidth: 1060, alignment: .top)
                    .padding(.horizontal, 46)
                    .padding(.vertical, 32)
                }
                .frame(maxWidth: .infinity, minHeight: 690, alignment: .top)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            (Text("Your typing")
                .foregroundStyle(DashboardTheme.text)
             + Text(" at a glance")
                .foregroundStyle(
                    LinearGradient(
                        colors: [DashboardTheme.blue, DashboardTheme.purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                ))
                .font(.system(size: 44, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.leading)
    }

    private var permissionNotice: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Input Monitoring is off")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DashboardTheme.text)
                Text("Allow access to update the numbers live.")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(DashboardTheme.muted)
            }

            Spacer()

            Button("Allow access") { state.requestPermission() }
                .buttonStyle(.borderedProminent)
                .tint(DashboardTheme.blue)
        }
        .padding(.vertical, 4)
    }

    private var primaryMetrics: some View {
        HStack(spacing: 0) {
            primaryMetric(
                title: "WPM",
                value: speed(snapshot.accuracyAdjustedWordsPerMinute),
                unit: "WPM",
                color: DashboardTheme.blue
            )

            Rectangle()
                .fill(DashboardTheme.divider)
                .frame(width: 1, height: 106)
                .padding(.horizontal, 34)

            primaryMetric(
                title: "Accuracy",
                value: accuracy(snapshot),
                unit: "%",
                color: DashboardTheme.purple
            )
        }
        .frame(maxWidth: .infinity, minHeight: 170)
        .threeSidedBorder()
    }

    private func primaryMetric(
        title: String,
        value: String,
        unit: String,
        color: Color
    ) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(spacing: 9) {
                Text(title)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DashboardTheme.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    MetricValueText(value: value, color: color, size: 64, dimDecimals: true, decimalScale: 0.62)
                }

                Text(unit)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(DashboardTheme.secondary)
            }

            if hoveredMetricTitle == title {
                Text(metricExplanation(for: title))
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(DashboardTheme.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(width: 190, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .contentShape(Rectangle())
        .scaleEffect(hoveredMetricTitle == title ? 1.035 : 1)
        .offset(x: hoveredMetricTitle == title ? -14 : 0)
        .animation(.easeOut(duration: 0.16), value: hoveredMetricTitle == title)
        .onHover { isHovering in
            hoveredMetricTitle = isHovering ? title : nil
        }
    }

    private func metricExplanation(for title: String) -> String {
        switch title {
        case "WPM":
            return "Your typing speed with respect to accuracy. The more words you misspell, the lower your WPM becomes."
        case "Accuracy":
            return "Your accuracy calculated using a combination of machine learning and dictionary-search algorithms. Whitelist names and acronyms in the typing insights panel."
        default:
            return ""
        }
    }

    private var detailedStatistics: some View {
        VStack(spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingDetails.toggle()
                }
            } label: {
                VStack(spacing: 5) {
                    HStack(spacing: 8) {
                        if hoveringDetails {
                            Image(systemName: showingDetails ? "chevron.up" : "chevron.down")
                        }
                        Text(showingDetails ? "Hide details" : "Show more details")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                        if hoveringDetails {
                            Image(systemName: showingDetails ? "chevron.up" : "chevron.down")
                        }
                    }
                    .transition(.opacity)
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(DashboardTheme.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 5)
            .onHover { hoveringDetails = $0 }
            .animation(.easeOut(duration: 0.14), value: hoveringDetails)

            if showingDetails {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                    statistic("Raw WPM", value: speed(snapshot.rawWordsPerMinute))
                    statistic("Backspaces clicked", value: "\(snapshot.deletionCount)")
                    statistic("Misspelled words", value: "\(estimatedMisspelledWords)")
                    statistic("Characters typed", value: "\(snapshot.printableCount)")
                    statistic("Focused WPM", value: speed(snapshot.intentionalWordsPerMinute))
                    statistic("Session duration", value: duration(snapshot.elapsed))
                    statistic("Model confidence", value: confidence(snapshot))
                }
                .frame(maxWidth: 660)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func statistic(_ title: String, value: String) -> some View {
        VStack(spacing: 5) {
            MetricValueText(value: value, color: DashboardTheme.text, size: 22, dimDecimals: false)
            Text(title)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(DashboardTheme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .scaleEffect(hoveredStatisticTitle == title ? 1.06 : 1)
        .animation(.easeOut(duration: 0.16), value: hoveredStatisticTitle == title)
        .onHover { isHovering in
            hoveredStatisticTitle = isHovering ? title : nil
        }
    }

    private var graphs: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 22) {
                SpeedGraph(points: historyPoints)
                AccuracyGraph(points: historyPoints)
            }
            VStack(spacing: 22) {
                SpeedGraph(points: historyPoints)
                AccuracyGraph(points: historyPoints)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var insights: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Insights")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(DashboardTheme.secondary)

            HStack(alignment: .top, spacing: 14) {
                speedInsight
                accuracyInsight
                shortTermInsight
            }
        }
    }

    private var visualAnalytics: some View {
        HStack(alignment: .top, spacing: 22) {
            timeOfDayHeatmap
            correctionProfileView
        }
        .frame(maxWidth: .infinity)
    }

    private var timeOfDayHeatmap: some View {
        let cells = timeOfDayCells
        return VStack(alignment: .leading, spacing: 12) {
            chartHeader(
                title: "Performance by time",
                color: DashboardTheme.mint,
                refresh: refreshAnalytics
            )

            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 6) {
                    Spacer().frame(height: 18)
                    ForEach(timeBucketLabels, id: \.self) { label in
                            Text(label)
                            .font(.system(size: 8, design: .rounded))
                            .foregroundStyle(DashboardTheme.muted)
                            .frame(width: 44, height: 26, alignment: .trailing)
                    }
                }

                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(weekdayLabels.indices, id: \.self) { index in
                            Text(weekdayLabels[index])
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(DashboardTheme.muted)
                                .frame(maxWidth: .infinity)
                        }
                    }

                    ForEach(0..<timeBucketLabels.count, id: \.self) { bucket in
                        HStack(spacing: 6) {
                            ForEach(1...7, id: \.self) { weekday in
                                let cell = cells.first { $0.weekday == weekday && $0.bucket == bucket }
                                heatmapCell(cell)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 7) {
                Text("Lower")
                ForEach(0..<5, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DashboardTheme.mint.opacity(0.14 + Double(step) * 0.18))
                        .frame(width: 18, height: 8)
                }
                Text("Higher")
            }
            .font(.system(size: 9, design: .rounded))
            .foregroundStyle(DashboardTheme.muted)
        }
        .padding(14)
        .background(DashboardTheme.panel.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .threeSidedBorder()
    }

    private var correctionProfileView: some View {
        let profile = state.store.correctionProfile
        let segments: [(String, Int, Color)] = [
            ("Backspaces", profile.backspaces, DashboardTheme.orange),
            ("Spelling", profile.spellingErrors, DashboardTheme.blue),
            ("Context", profile.contextualErrors, DashboardTheme.purple)
        ]
        let total = max(1, segments.reduce(0) { $0 + $1.1 })

        return VStack(alignment: .leading, spacing: 14) {
            chartHeader(
                title: "Correction profile",
                color: DashboardTheme.orange,
                refresh: refreshAnalytics
            )

            GeometryReader { geometry in
                HStack(spacing: 3) {
                    ForEach(segments, id: \.0) { segment in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(segment.2.opacity(segment.1 == 0 ? 0.12 : 0.82))
                            .frame(width: max(8, geometry.size.width * CGFloat(segment.1) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 18)

            HStack(alignment: .top, spacing: 12) {
                ForEach(segments, id: \.0) { segment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(segment.2)
                                .frame(width: 6, height: 6)
                            Text(segment.0)
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(DashboardTheme.muted)
                        }
                        Text("\(segment.1)")
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(DashboardTheme.text)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    MetricValueText(
                        value: String(format: "%.1f", profile.averageEditDistance),
                        color: DashboardTheme.orange,
                        size: 30,
                        dimDecimals: false
                    )
                    Text("avg. edit distance")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(DashboardTheme.muted)
                }

                Spacer()

                Button {
                    showingEditDistanceInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DashboardTheme.secondary)
                }
                .buttonStyle(.plain)
                .help("What is average edit distance?")
                .popover(isPresented: $showingEditDistanceInfo, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Average edit distance")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(DashboardTheme.text)
                        Text("The average number of single-character insertions, deletions, or substitutions needed to turn a flagged word into its likely correction.")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(DashboardTheme.secondary)
                        Text("0 means no character changes. 1 means one change per flagged word on average. It only includes words flagged for spelling or contextual errors; backspaces are tracked separately.")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(DashboardTheme.muted)
                    }
                    .frame(width: 270, alignment: .leading)
                    .padding(16)
                    .preferredColorScheme(.dark)
                }
            }
        }
        .padding(14)
        .background(DashboardTheme.panel.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .threeSidedBorder()
    }

    private let weekdayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private let timeBucketLabels = ["12a–6a", "6a–12p", "12p–6p", "6p–12a"]

    private var timeOfDayCells: [TimeOfDayCell] {
        let calendar = Calendar.current
        var values: [String: [Double]] = [:]

        for session in state.store.sessions {
            let weekday = calendar.component(.weekday, from: session.endedAt)
            let bucket = calendar.component(.hour, from: session.endedAt) / 6
            let adjustedWPM = max(0, session.wpm * session.accuracy)
            values["\(weekday)-\(bucket)", default: []].append(adjustedWPM)
        }

        return (0..<timeBucketLabels.count).flatMap { bucket in
            (1...7).map { weekday in
                let samples = values["\(weekday)-\(bucket)"] ?? []
                return TimeOfDayCell(
                    weekday: weekday,
                    bucket: bucket,
                    value: samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count),
                    sessionCount: samples.count
                )
            }
        }
    }

    private var heatmapMaximum: Double {
        timeOfDayCells.compactMap(\.value).max() ?? 0
    }

    @ViewBuilder
    private func heatmapCell(_ cell: TimeOfDayCell?) -> some View {
        if let cell {
            RoundedRectangle(cornerRadius: 5)
                .fill(heatmapColor(for: cell.value))
                .overlay {
                    if hoveredHeatmapCell == cell.id {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(DashboardTheme.text.opacity(0.75), lineWidth: 1)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .scaleEffect(hoveredHeatmapCell == cell.id ? 1.08 : 1)
                .animation(.easeOut(duration: 0.14), value: hoveredHeatmapCell == cell.id)
                .help(cell.value.map { String(format: "%.1f WPM · %d sessions", $0, cell.sessionCount) } ?? "No sessions")
                .onHover { isHovering in
                    hoveredHeatmapCell = isHovering ? cell.id : nil
                }
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(DashboardTheme.panel.opacity(0.22))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
        }
    }

    private func heatmapColor(for value: Double?) -> Color {
        guard let value, heatmapMaximum > 0 else {
            return DashboardTheme.panel.opacity(0.24)
        }
        let intensity = min(1, max(0, value / heatmapMaximum))
        return DashboardTheme.mint.opacity(0.14 + intensity * 0.76)
    }

    private func refreshAnalytics() {
        do {
            try state.store.refresh()
        } catch {
            state.lastError = "Could not refresh analytics: \(error.localizedDescription)"
        }
    }

    private var speedInsight: some View {
        insightCard(
            title: "Focused speed",
            color: DashboardTheme.blue,
            message: comparisonMessage(for: historyPoints.map(\.wpm), unit: "WPM", percentThreshold: 10)
        ) {
            if let point = historyPoints.last {
                insightMetric(value: String(format: "%.1f WPM", point.wpm), color: DashboardTheme.blue, progress: min(1, point.wpm / 160))
            } else {
                insightUnavailable(color: DashboardTheme.blue)
            }
        }
    }

    private var accuracyInsight: some View {
        insightCard(
            title: "Focused accuracy",
            color: DashboardTheme.purple,
            message: comparisonMessage(for: historyPoints.map { $0.accuracy * 100 }, unit: "percentage points", percentThreshold: 2)
        ) {
            if let point = historyPoints.last {
                insightMetric(value: String(format: "%.1f%%", point.accuracy * 100), color: DashboardTheme.purple, progress: point.accuracy)
            } else {
                insightUnavailable(color: DashboardTheme.purple)
            }
        }
    }

    private var shortTermInsight: some View {
        Button {
            onOpenTypingInsights()
        } label: {
            ZStack {
                shortTermInsightFront
                    .opacity(shortTermInsightFlipped ? 0 : 1)
                    .rotation3DEffect(
                        .degrees(shortTermInsightFlipped ? 180 : 0),
                        axis: (x: 0, y: 1, z: 0)
                    )

                shortTermInsightBack
                    .opacity(shortTermInsightFlipped ? 1 : 0)
                    .rotation3DEffect(
                        .degrees(shortTermInsightFlipped ? 0 : -180),
                        axis: (x: 0, y: 1, z: 0)
                    )
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(14)
            .background(DashboardTheme.panel.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            .threeSidedBorder()
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { isHovering in
            withAnimation(.easeInOut(duration: 0.35)) {
                shortTermInsightFlipped = isHovering
            }
        }
        .help("Open typing insights")
    }

    private var shortTermInsightFront: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Short-term insight")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DashboardTheme.secondary)

            HStack(spacing: 16) {
                if topKeyLabel != "—" {
                    shortTermMetric(value: topKeyLabel, label: "top key", color: DashboardTheme.mint)
                }
                if insightMisspellingCount > 0 {
                    shortTermMetric(value: "\(insightMisspellingCount)", label: "spelling flags", color: DashboardTheme.blue)
                }
                if insightPatternCount > 0 {
                    shortTermMetric(value: "\(insightPatternCount)", label: "friction signals", color: DashboardTheme.purple)
                }
                if topKeyLabel == "—", insightMisspellingCount == 0, insightPatternCount == 0 {
                    Text("Collecting your first useful signals")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(DashboardTheme.muted)
                }
            }
        }
    }

    private var shortTermInsightBack: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Explore your typing patterns")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(DashboardTheme.text)
                Text("Click to visit Typing insights for the full heatmap, word signals, and whitelist.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(DashboardTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(DashboardTheme.mint)
        }
    }

    private func shortTermMetric(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 21, weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(DashboardTheme.muted)
        }
    }

    private var topKeyLabel: String {
        let key = state.store.keyAggregates
            .flatMap(\.keyStats)
            .max { $0.activity < $1.activity }?.key
        return key?.uppercased() ?? "—"
    }

    private var insightMisspellingCount: Int {
        insightWordData
            .filter { $0.kind == .misspelling }
            .reduce(0) { $0 + $1.count }
    }

    private var insightPatternCount: Int {
        insightWordData
            .filter { $0.kind == .slowWord || $0.kind == .doubleLetter }
            .reduce(0) { $0 + $1.count }
    }

    private var insightWordData: [WordInsight] {
        state.store.recentWordInsights.isEmpty ? state.store.wordInsights : state.store.recentWordInsights
    }

    private func insightCard<Visual: View>(
        title: String,
        color: Color,
        message: String,
        @ViewBuilder visual: () -> Visual
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DashboardTheme.secondary)
            visual()
            Text(message)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(DashboardTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(14)
        .background(
            DashboardTheme.panel.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .threeSidedBorder()
    }

    private func insightMetric(value: String, color: Color, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MetricValueText(value: value, color: color, size: 23, dimDecimals: false)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .strokeBorder(DashboardTheme.divider, lineWidth: 1)
                    Capsule()
                        .fill(color.opacity(0.75))
                        .frame(width: max(0, geometry.size.width * min(max(progress, 0), 1) - 4))
                        .padding(2)
                }
            }
            .frame(height: 8)
        }
    }

    private func insightUnavailable(color: Color) -> some View {
        Text("-")
            .font(.system(size: 26, weight: .regular, design: .rounded))
            .foregroundStyle(color)
            .frame(height: 22, alignment: .leading)
    }

    private func comparisonMessage(for values: [Double], unit: String, percentThreshold: Double) -> String {
        guard values.count >= 2, let current = values.last, let previous = values.dropLast().last, previous > 0 else {
            return "Build another recorded day to compare your trend."
        }

        let difference = current - previous
        let relativeDifference = abs(difference / previous * 100)
        let significant = unit == "percentage points"
            ? abs(difference) >= percentThreshold
            : relativeDifference >= percentThreshold
        if !significant {
            return "About the same as your previous recorded day."
        }

        let direction = difference > 0 ? "higher" : "lower"
        let formattedDifference = unit == "percentage points"
            ? String(format: "%.1f", abs(difference))
            : String(format: "%.0f%%", relativeDifference)
        let suffix = unit == "percentage points" ? " points" : ""
        return "\(formattedDifference)\(suffix) \(direction) than your previous recorded day."
    }

    private var estimatedMisspelledWords: Int {
        let liveCandidates = snapshot.accuracyTrace.currentText.isEmpty
            ? 0
            : snapshot.accuracyTrace.spellingCandidates.count + snapshot.accuracyTrace.contextCandidates.count
        return snapshot.accuracyTotals.spellingErrorWords + snapshot.accuracyTotals.contextErrorWords + liveCandidates
    }

    private func speed(_ value: Double) -> String {
        guard snapshot.printableCount > 0, value > 0 else { return "—" }
        return String(format: "%.1f", value)
    }

    private func accuracy(_ value: LiveSessionSnapshot) -> String {
        guard value.printableCount > 0 else { return "—" }
        return String(format: "%.1f", value.liveAccuracy * 100)
    }

    private func confidence(_ value: LiveSessionSnapshot) -> String {
        guard value.hmm.completedFrameCount > 0 else { return "—" }
        return String(format: "%.0f%%", value.hmm.latestPredictionConfidence * 100)
    }

    private func duration(_ value: TimeInterval) -> String {
        guard value > 0 else { return "—" }
        if value < 60 { return String(format: "%.0fs", value) }
        return String(format: "%.1fm", value / 60)
    }
}

private struct SpeedGraph: View {
    let points: [HistoricalMetricPoint]
    @State private var hoveredPoint: HistoricalMetricPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            chartHeader(title: "Speed over time", color: DashboardTheme.blue)

            chartContainer {
                if points.isEmpty {
                    graphPlaceholder(title: "No speed data yet", message: "Finish a typing burst to see your pace here.", color: DashboardTheme.blue)
                } else {
                    Chart {
                        RuleMark(y: .value("Baseline", 0))
                            .foregroundStyle(DashboardTheme.divider)
                        ForEach(points) { point in
                            LineMark(
                                x: .value("Day", point.day),
                                y: .value("WPM", point.wpm)
                            )
                            .foregroundStyle(DashboardTheme.blue)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                            PointMark(
                                x: .value("Day", point.day),
                                y: .value("WPM", point.wpm)
                            )
                            .foregroundStyle(DashboardTheme.blue)
                            .symbolSize(32)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let hoveredPoint {
                            chartTooltip(
                                day: hoveredPoint.day,
                                value: String(format: "%.1f WPM", hoveredPoint.wpm),
                                sessionCount: hoveredPoint.sessionCount
                            )
                            .padding(8)
                            .allowsHitTesting(false)
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case let .active(location):
                                        guard let plotFrame = proxy.plotFrame else { return }
                                        let plotRect = geometry[plotFrame]
                                        guard plotRect.contains(location) else {
                                            hoveredPoint = nil
                                            return
                                        }
                                        let plotX = location.x - plotRect.minX
                                        guard let date: Date = proxy.value(atX: plotX) else { return }
                                        hoveredPoint = points.min {
                                            abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date))
                                        }
                                    case .ended:
                                        hoveredPoint = nil
                                    }
                                }
                        }
                    }
                    .chartYScale(domain: 0...max(60, (points.map(\.wpm).max() ?? 0) * 1.2))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                                .foregroundStyle(DashboardTheme.divider)
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                .foregroundStyle(DashboardTheme.secondary.opacity(0.75))
                                .font(.system(size: 10, design: .rounded))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                                .foregroundStyle(DashboardTheme.divider)
                            AxisValueLabel()
                                .foregroundStyle(DashboardTheme.secondary.opacity(0.75))
                                .font(.system(size: 10, design: .rounded))
                            }
                        }
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccuracyGraph: View {
    let points: [HistoricalMetricPoint]
    @State private var hoveredPoint: HistoricalMetricPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            chartHeader(title: "Accuracy over time", color: DashboardTheme.purple)

            chartContainer {
                if points.isEmpty {
                    graphPlaceholder(title: "No accuracy data yet", message: "Complete a sentence to plot your accuracy.", color: DashboardTheme.purple)
                } else {
                    Chart {
                        RuleMark(y: .value("Perfect", 100))
                            .foregroundStyle(DashboardTheme.divider)
                        ForEach(points) { point in
                            LineMark(
                                x: .value("Day", point.day),
                                y: .value("Accuracy", point.accuracy * 100)
                            )
                            .foregroundStyle(DashboardTheme.purple)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                            PointMark(
                                x: .value("Day", point.day),
                                y: .value("Accuracy", point.accuracy * 100)
                            )
                            .foregroundStyle(DashboardTheme.purple)
                            .symbolSize(32)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let hoveredPoint {
                            chartTooltip(
                                day: hoveredPoint.day,
                                value: String(format: "%.1f%%", hoveredPoint.accuracy * 100),
                                sessionCount: hoveredPoint.sessionCount
                            )
                            .padding(8)
                            .allowsHitTesting(false)
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case let .active(location):
                                        guard let plotFrame = proxy.plotFrame else { return }
                                        let plotRect = geometry[plotFrame]
                                        guard plotRect.contains(location) else {
                                            hoveredPoint = nil
                                            return
                                        }
                                        let plotX = location.x - plotRect.minX
                                        guard let date: Date = proxy.value(atX: plotX) else { return }
                                        hoveredPoint = points.min {
                                            abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date))
                                        }
                                    case .ended:
                                        hoveredPoint = nil
                                    }
                                }
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                                .foregroundStyle(DashboardTheme.divider)
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                .foregroundStyle(DashboardTheme.secondary.opacity(0.75))
                                .font(.system(size: 10, design: .rounded))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                                .foregroundStyle(DashboardTheme.divider)
                            AxisValueLabel()
                                .foregroundStyle(DashboardTheme.secondary.opacity(0.75))
                                .font(.system(size: 10, design: .rounded))
                            }
                        }
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func chartHeader(
    title: String,
    color: Color,
    refresh: (() -> Void)? = nil
) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(title)
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(color)
        Spacer()
        if let refresh {
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DashboardTheme.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
    }
}

private func chartContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
        .frame(maxWidth: .infinity, minHeight: 176)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            DashboardTheme.panel.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .threeSidedBorder()
}

private func graphPlaceholder(title: String, message: String, color: Color) -> some View {
    VStack(spacing: 8) {
        Text("-")
            .font(.system(size: 30, weight: .regular, design: .rounded))
            .foregroundStyle(color)
        Text(title)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(DashboardTheme.secondary)
        Text(message)
            .font(.system(size: 11, weight: .regular, design: .rounded))
            .foregroundStyle(DashboardTheme.secondary.opacity(0.72))
            .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, minHeight: 154)
}

private func chartTooltip(day: Date, value: String, sessionCount: Int) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(day, format: .dateTime.month(.abbreviated).day())
            .font(.system(size: 10, weight: .regular, design: .rounded))
            .foregroundStyle(DashboardTheme.muted)
        Text(value)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(DashboardTheme.text)
        Text("\(sessionCount) \(sessionCount == 1 ? "session" : "sessions")")
            .font(.system(size: 10, weight: .regular, design: .rounded))
            .foregroundStyle(DashboardTheme.muted)
    }
    .padding(8)
    .background(DashboardTheme.background.opacity(0.96), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(DashboardTheme.divider, lineWidth: 1)
    }
}

private struct TimeOfDayCell: Identifiable {
    let weekday: Int
    let bucket: Int
    let value: Double?
    let sessionCount: Int

    var id: String { "\(weekday)-\(bucket)" }
}

struct DashboardLogo: View {
    let width: CGFloat

    var body: some View {
        logoImage
            .resizable()
            .scaledToFit()
            .frame(width: width, height: width)
            .shadow(color: DashboardTheme.blue.opacity(0.18), radius: 10)
    }

    private var logoImage: Image {
        if let url = Bundle.main.url(forResource: "keydance", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return Image(nsImage: image)
        }
        if let url = Bundle.module.url(forResource: "keydance", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return Image(nsImage: image)
        }
        return Image(systemName: "keyboard.fill")
    }
}

private struct ThreeSidedBorder: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(DashboardTheme.divider)
                    .frame(height: 1)
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(DashboardTheme.divider)
                    .frame(width: 1)
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(DashboardTheme.divider)
                    .frame(width: 1)
            }
    }
}

private extension View {
    func threeSidedBorder() -> some View {
        modifier(ThreeSidedBorder())
    }
}

private struct MetricValueText: View {
    let value: String
    let color: Color
    let size: CGFloat
    let dimDecimals: Bool
    let decimalScale: CGFloat

    init(value: String, color: Color, size: CGFloat, dimDecimals: Bool = true, decimalScale: CGFloat = 1) {
        self.value = value
        self.color = color
        self.size = size
        self.dimDecimals = dimDecimals
        self.decimalScale = decimalScale
    }

    var body: some View {
        if let decimalIndex = value.firstIndex(of: ".") {
            let firstDecimalDigit = value.index(after: decimalIndex)
            let decimalEnd = value[firstDecimalDigit...].firstIndex(where: { !$0.isNumber }) ?? value.endIndex
            (Text(value[..<decimalIndex])
                .font(.system(size: size, weight: .regular, design: .rounded))
                .foregroundColor(color)
                + Text(value[decimalIndex..<decimalEnd])
                    .font(.system(size: size * decimalScale, weight: .regular, design: .rounded))
                    .foregroundColor(dimDecimals ? color.opacity(0.42) : color)
                + Text(value[decimalEnd...])
                    .font(.system(size: size, weight: .regular, design: .rounded))
                    .foregroundColor(color))
                .monospacedDigit()
        } else {
            Text(value)
                .font(.system(size: size, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}

enum DashboardTheme {
    static let background = Color(red: 0.012, green: 0.018, blue: 0.035)
    static let panel = Color.white.opacity(0.065)
    static let divider = Color.white.opacity(0.12)
    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.78)
    static let muted = Color.white.opacity(0.68)
    static let faint = Color.white.opacity(0.5)
    static let blue = Color(red: 0.38, green: 0.62, blue: 1.0)
    static let purple = Color(red: 0.72, green: 0.48, blue: 1.0)
    static let mint = Color(red: 0.35, green: 0.9, blue: 0.7)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.28)
}

struct DashboardBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    DashboardTheme.background,
                    Color(red: 0.025, green: 0.04, blue: 0.08),
                    Color(red: 0.02, green: 0.015, blue: 0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(DashboardTheme.blue.opacity(0.1))
                .frame(width: 520, height: 520)
                .blur(radius: 120)
                .offset(x: -430, y: -330)

            Circle()
                .fill(DashboardTheme.purple.opacity(0.1))
                .frame(width: 460, height: 460)
                .blur(radius: 120)
                .offset(x: 430, y: 360)
        }
        .ignoresSafeArea()
    }
}

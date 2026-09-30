import SwiftUI

struct TypingInsightsView: View {
    @EnvironmentObject private var state: AppState
    @State private var isRefreshing = false

    private let keyboardRows = [
        Array("qwertyuiop"),
        Array("asdfghjkl"),
        Array("zxcvbnm")
    ]

    private var insights: [WordInsight] { state.store.wordInsights }
    private var recentInsights: [WordInsight] { state.store.recentWordInsights }

    private func insights(for kind: WordInsightKind) -> [WordInsight] {
        let recent = recentInsights.filter { $0.kind == kind }
        return recent.isEmpty ? insights.filter { $0.kind == kind } : recent
    }

    private var misspellings: [WordInsight] {
        insights(for: .misspelling).filter { !state.whitelistedWords.contains($0.word) }
    }
    private var repeatableMisspelling: WordInsight? {
        misspellings.first { $0.count >= 5 }
    }
    private var slowWords: [WordInsight] { insights(for: .slowWord) }
    private var doubleLetters: [WordInsight] { insights(for: .doubleLetter) }
    private var repeatablePattern: WordInsight? {
        repeatableMisspelling ?? doubleLetters.first { $0.count >= 5 }
    }
    private var frequentWords: [WordInsight] { insights(for: .frequentWord).prefix(8).map { $0 } }

    private var patternSignals: [PatternSignal] {
        var signals: [PatternSignal] = []
        if let first = frequentWords.first {
            signals.append(PatternSignal(id: "frequent", icon: "textformat.abc", title: "Frequent words", value: "\(first.word) · \(first.count)", color: DashboardTheme.blue))
        }
        if let first = slowWords.first {
            signals.append(PatternSignal(id: "slow", icon: "timer", title: "Words that take longer", value: "\(first.word) · \(format(seconds: first.averageDuration))", color: DashboardTheme.orange))
        }
        if let first = doubleLetters.first {
            signals.append(PatternSignal(id: "double", icon: "repeat", title: "Double-letter friction", value: "\(first.word) in \(first.suggestion)", color: DashboardTheme.purple))
        }
        return signals
    }

    private var keyActivity: [String: Int] {
        state.store.keyAggregates
            .flatMap(\.keyStats)
            .reduce(into: [:]) { result, item in result[item.key.lowercased(), default: 0] += item.activity }
    }

    private var keyMaximum: Int { keyActivity.values.max() ?? 0 }

    var body: some View {
        ZStack {
            DashboardBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    profileStatusCard

                    HStack(alignment: .top, spacing: 16) {
                        keyboardCard
                        patternCard
                    }

                    HStack(alignment: .top, spacing: 16) {
                        wordListCard
                        whitelistCard
                    }

                    retentionNote
                }
                .frame(maxWidth: 1060, alignment: .topLeading)
                .padding(.horizontal, 46)
                .padding(.vertical, 32)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Typing insights")
                    .font(.system(size: 28, weight: .regular, design: .rounded))
                    .foregroundStyle(DashboardTheme.text)
                Text("A small, local map of where your typing gets interesting.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(DashboardTheme.muted)
            }

            Spacer()

            Button {
                refreshInsights()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isRefreshing ? 180 : 0))
                    Text("Refresh insights")
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DashboardTheme.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(DashboardTheme.panel.opacity(0.25), in: Capsule())
                .overlay { Capsule().strokeBorder(DashboardTheme.divider, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .help("Refresh the heatmap, word signals, and patterns")
        }
    }

    private var profileStatusCard: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(DashboardTheme.mint)
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(repeatablePattern == nil ? "Your profile is still taking shape" : "A repeatable pattern is showing up")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(DashboardTheme.text)
                Text(opportunityMessage)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(DashboardTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .background(DashboardTheme.panel.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .insightBorder()
    }

    private var opportunityMessage: String {
        if let first = repeatablePattern {
            if first.kind == .misspelling {
                return "You’ve typed “\(first.word)” \(first.count) times; “\(first.suggestion)” is the likely correction. Keep it if it’s a name, acronym, or intentional spelling."
            }
            return "Double-letter pauses around “\(first.word)” are the first pattern worth watching. Keep typing for a little longer to turn signals into a reliable story."
        }
        return "Finish a few typing bursts and Keydance will look for repeatable spelling, rhythm, key, and word patterns. Nothing is inferred from a single keystroke."
    }

    private func refreshInsights() {
        withAnimation(.easeInOut(duration: 0.25)) { isRefreshing = true }
        do {
            try state.store.refresh()
        } catch {
            state.lastError = "Could not refresh insights: \(error.localizedDescription)"
        }
        withAnimation(.easeInOut(duration: 0.25)) { isRefreshing = false }
    }

    private var keyboardCard: some View {
        insightPanel(title: "Keyboard heatmap", subtitle: "Most-used letters, aggregated locally") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(keyboardRows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 6) {
                        Spacer().frame(width: CGFloat(rowIndex) * 13)
                        ForEach(row, id: \.self) { key in
                            let value = keyActivity[String(key)] ?? 0
                            Text(String(key).uppercased())
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(value > 0 ? DashboardTheme.text : DashboardTheme.muted)
                                .frame(width: 29, height: 29)
                                .background(heatColor(for: value), in: RoundedRectangle(cornerRadius: 6))
                                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DashboardTheme.divider, lineWidth: 1) }
                                .help(value > 0 ? "\(value) hits" : "No data yet")
                        }
                    }
                }
                HStack(spacing: 7) {
                    Text("less")
                    Capsule().fill(DashboardTheme.blue.opacity(0.22)).frame(width: 32, height: 6)
                    Capsule().fill(DashboardTheme.mint.opacity(0.82)).frame(width: 32, height: 6)
                    Text("more")
                }
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(DashboardTheme.muted)
                .padding(.top, 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var patternCard: some View {
        insightPanel(title: "Patterns to watch", subtitle: "Signals become useful with repetition") {
            if patternSignals.isEmpty {
                emptyRow(icon: "waveform.path.ecg", text: "Collecting repeatable patterns.")
            } else {
                HStack(alignment: .top, spacing: 22) {
                    ForEach(patternSignals) { signal in
                        patternStat(signal)
                    }
                }
            }
        }
    }

    private var wordListCard: some View {
        insightPanel(title: "Possible misspellings", subtitle: "Whitelist anything that is actually yours") {
            if misspellings.isEmpty {
                emptyRow(icon: "checkmark.circle", text: "No repeated spelling signals yet.")
            } else {
                VStack(spacing: 0) {
                    ForEach(misspellings.prefix(6)) { item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.word)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(DashboardTheme.text)
                                Text("likely \(item.suggestion) · \(item.count)×")
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundStyle(DashboardTheme.muted)
                            }
                            Spacer()
                            Button("Keep") { state.whitelistWord(item.word) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(DashboardTheme.blue)
                        }
                        .padding(.vertical, 9)
                        if item.id != misspellings.prefix(6).last?.id { patternDivider }
                    }
                }
            }
        }
    }

    private var whitelistCard: some View {
        insightPanel(title: "Your whitelist", subtitle: "Names, acronyms, and words to ignore") {
            if state.whitelistedWords.isEmpty {
                emptyRow(icon: "plus.circle", text: "Nothing ignored yet. Use Keep when a flag is a false positive.")
            } else {
                FlowLayout(items: Array(state.whitelistedWords).sorted()) { word in
                    HStack(spacing: 5) {
                        Text(word)
                        Button { state.removeWhitelistedWord(word) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(DashboardTheme.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(DashboardTheme.panel.opacity(0.25), in: Capsule())
                }
            }
        }
    }

    private var retentionNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(DashboardTheme.mint)
            Text("Privacy shape: Keydance keeps only top daily counters (up to 96 word patterns plus key totals), never sentences or ordered key history. Your current retention setting removes these aggregates with the rest of analytics.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(DashboardTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(DashboardTheme.panel.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func insightPanel<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DashboardTheme.text)
                Text(subtitle)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(DashboardTheme.muted)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .background(DashboardTheme.panel.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .insightBorder()
    }

    private func patternStat(_ signal: PatternSignal) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: signal.icon)
                .foregroundStyle(signal.color)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(signal.title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DashboardTheme.secondary)
                Text(signal.value)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(DashboardTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var patternDivider: some View { Rectangle().fill(DashboardTheme.divider).frame(height: 1) }

    private func emptyRow(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(DashboardTheme.muted)
            .padding(.vertical, 16)
    }

    private func heatColor(for value: Int) -> Color {
        guard value > 0, keyMaximum > 0 else { return DashboardTheme.panel.opacity(0.28) }
        let intensity = Double(value) / Double(keyMaximum)
        return DashboardTheme.blue.opacity(0.18 + intensity * 0.74)
    }

    private func format(seconds: TimeInterval) -> String {
        String(format: "%.1fs", seconds)
    }
}

private struct FlowLayout<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self, content: content)
        }
    }
}

private struct PatternSignal: Identifiable {
    let id: String
    let icon: String
    let title: String
    let value: String
    let color: Color
}

private struct InsightBorder: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { Rectangle().fill(DashboardTheme.divider).frame(height: 1) }
            .overlay(alignment: .leading) { Rectangle().fill(DashboardTheme.divider).frame(width: 1) }
            .overlay(alignment: .trailing) { Rectangle().fill(DashboardTheme.divider).frame(width: 1) }
    }
}

private extension View {
    func insightBorder() -> some View { modifier(InsightBorder()) }
}

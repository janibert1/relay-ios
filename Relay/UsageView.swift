import SwiftUI

/// Real usage/quota view across ALL providers — Claude, Codex, Gemini
/// (subscription %), and OpenRouter (free-tier daily requests + paid
/// balance) — in one place. Built 2026-09-22: the backend endpoint
/// (`GET /api/usage`) and client method (`RelayAPIClient.getUsage`)
/// already existed, but nothing in the app ever actually called or
/// displayed it — Jan couldn't see usage anywhere despite the plumbing
/// being there. `check-usage.py` itself also didn't cover OpenRouter at
/// all until this same pass (its own real `/api/v1/key` endpoint has
/// free-tier + balance info, added there first).
///
/// 2026-09-23: `/api/usage` only ever returns a raw preformatted text
/// blob (`UsageInfo.text`, `check-usage.py`'s own stdout) — there's no
/// structured per-provider JSON on the backend, and rewriting that isn't
/// worth the risk since other tooling depends on that script's exact
/// output shape. Rather than change the contract, this parses the
/// existing "<label>: NN% used, <caption>" / "N/M requests" lines
/// client-side into real progress bars, and falls back to showing any
/// line it can't confidently parse as plain monospace text — nothing is
/// ever hidden or lost, just rendered nicer when it can be.
struct UsageView: View {
    let apiClient: RelayAPIClient
    @Environment(\.dismiss) private var dismiss

    @State private var usage: UsageInfo?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let backgroundColor = Color(red: 0.039, green: 0.039, blue: 0.039)
    private let cardBackground = Color(red: 0.102, green: 0.102, blue: 0.102)
    private let cardBorder = Color(red: 0.165, green: 0.165, blue: 0.165)
    private let primaryTextColor = Color(red: 0.949, green: 0.949, blue: 0.949)
    private let dimTextColor = Color(red: 0.541, green: 0.541, blue: 0.541)
    private let dangerColor = Color(red: 1.0, green: 0.420, blue: 0.420)
    private let accentColor = Color(red: 74 / 255, green: 222 / 255, blue: 128 / 255)
    private let warningColor = Color(red: 250 / 255, green: 176 / 255, blue: 5 / 255)

    init(apiClient: RelayAPIClient = .shared) {
        self.apiClient = apiClient
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundColor(dangerColor)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(cardBackground)
                            .cornerRadius(10)
                    }

                    if let usage {
                        ForEach(parseUsageSections(usage.text)) { section in
                            UsageSectionCard(
                                section: section,
                                cardBackground: cardBackground,
                                cardBorder: cardBorder,
                                textColor: primaryTextColor,
                                dimTextColor: dimTextColor,
                                accentColor: accentColor,
                                warningColor: warningColor,
                                dangerColor: dangerColor
                            )
                        }

                        Text("Fetched \(usage.fetchedAt)")
                            .font(.system(size: 11))
                            .foregroundColor(dimTextColor)
                    } else if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.top, 60)
                    }
                }
                .padding(16)
            }
            .background(backgroundColor.ignoresSafeArea())
            .navigationTitle("Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(backgroundColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(dimTextColor)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .foregroundColor(accentColor)
                    .disabled(isLoading)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            usage = try await apiClient.getUsage()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Parsing

private struct UsageBar: Identifiable {
    let id = UUID()
    var label: String
    var fraction: Double // 0...1
    var percentText: String
    var caption: String
}

private struct UsageSection: Identifiable {
    let id = UUID()
    var title: String
    var bars: [UsageBar] = []
    var plainLines: [String] = []
}

/// Splits `check-usage.py`'s raw text on "== Section ==" headers, and
/// tries to turn each line under a header into a real progress bar (see
/// `parseUsedPercentLine`/`parseRequestsRatioLine`) — any line neither
/// pattern matches is kept verbatim in `plainLines` rather than dropped.
private func parseUsageSections(_ text: String) -> [UsageSection] {
    var sections: [UsageSection] = []
    var current: UsageSection?

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("==") && line.hasSuffix("==") && line.count > 4 {
            if let current { sections.append(current) }
            var title = line
            while title.hasPrefix("=") { title.removeFirst() }
            while title.hasSuffix("=") { title.removeLast() }
            current = UsageSection(title: title.trimmingCharacters(in: .whitespaces))
            continue
        }
        guard current != nil else { continue }
        if let bar = parseUsedPercentLine(line) {
            current!.bars.append(bar)
        } else if let bar = parseRequestsRatioLine(line) {
            current!.bars.append(bar)
        } else {
            current!.plainLines.append(line)
        }
    }
    if let current { sections.append(current) }
    return sections
}

private func cleanLabel(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespaces)
    while t.hasSuffix(":") { t.removeLast() }
    return t.trimmingCharacters(in: .whitespaces)
}

private func cleanCaption(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespaces)
    while t.hasPrefix(",") { t.removeFirst() }
    return t.trimmingCharacters(in: .whitespaces)
}

private func numberBefore(_ line: String, endingAt end: String.Index) -> String.Index {
    var start = end
    while start > line.startIndex {
        let prev = line.index(before: start)
        if line[prev].isNumber || line[prev] == "." {
            start = prev
        } else {
            break
        }
    }
    return start
}

private func numberAfter(_ line: String, startingAt start: String.Index) -> String.Index {
    var end = start
    while end < line.endIndex, line[end].isNumber || line[end] == "." {
        end = line.index(after: end)
    }
    return end
}

/// Matches e.g. "session (5h):  44.0% used, resets in 3.7h" or
/// "5h window:  18% used, resets in 4.2h".
private func parseUsedPercentLine(_ line: String) -> UsageBar? {
    guard let markerRange = line.range(of: "% used") else { return nil }
    let start = numberBefore(line, endingAt: markerRange.lowerBound)
    guard start < markerRange.lowerBound else { return nil }
    let numberStr = String(line[start..<markerRange.lowerBound])
    guard let pct = Double(numberStr) else { return nil }
    let label = cleanLabel(String(line[line.startIndex..<start]))
    let caption = cleanCaption(String(line[markerRange.upperBound...]))
    let percentText = numberStr.hasSuffix(".0") ? String(numberStr.dropLast(2)) + "%" : numberStr + "%"
    return UsageBar(
        label: label.isEmpty ? "usage" : label,
        fraction: min(max(pct / 100.0, 0), 1),
        percentText: percentText,
        caption: caption
    )
}

/// Matches e.g. "free models:  21/1000 requests today, 979 remaining".
private func parseRequestsRatioLine(_ line: String) -> UsageBar? {
    guard let reqRange = line.range(of: " requests") else { return nil }
    let beforeReq = line[line.startIndex..<reqRange.lowerBound]
    guard let slashIdx = beforeReq.lastIndex(of: "/") else { return nil }
    let denomEnd = numberAfter(line, startingAt: line.index(after: slashIdx))
    let denomStr = String(line[line.index(after: slashIdx)..<denomEnd])
    let numStart = numberBefore(line, endingAt: slashIdx)
    guard numStart < slashIdx else { return nil }
    let numStr = String(line[numStart..<slashIdx])
    guard let num = Double(numStr), let denom = Double(denomStr), denom > 0 else { return nil }
    let label = cleanLabel(String(line[line.startIndex..<numStart]))
    let caption = cleanCaption(String(line[reqRange.upperBound...]))
    return UsageBar(
        label: label.isEmpty ? "requests" : label,
        fraction: min(max(num / denom, 0), 1),
        percentText: "\(numStr)/\(denomStr)",
        caption: caption
    )
}

// MARK: - Rendering

private struct UsageBarRow: View {
    let bar: UsageBar
    let trackColor: Color
    let textColor: Color
    let dimTextColor: Color
    let accentColor: Color
    let warningColor: Color
    let dangerColor: Color

    private var barColor: Color {
        if bar.fraction >= 0.9 { return dangerColor }
        if bar.fraction >= 0.7 { return warningColor }
        return accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bar.label)
                    .font(.system(size: 13))
                    .foregroundColor(textColor)
                Spacer()
                Text(bar.percentText)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(barColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(trackColor)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barColor)
                        .frame(width: max(4, geo.size.width * bar.fraction))
                }
            }
            .frame(height: 8)
            if !bar.caption.isEmpty {
                Text(bar.caption)
                    .font(.system(size: 11))
                    .foregroundColor(dimTextColor)
            }
        }
        .textSelection(.enabled)
    }
}

private struct UsageSectionCard: View {
    let section: UsageSection
    let cardBackground: Color
    let cardBorder: Color
    let textColor: Color
    let dimTextColor: Color
    let accentColor: Color
    let warningColor: Color
    let dangerColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(textColor)
                .textSelection(.enabled)

            ForEach(section.bars) { bar in
                UsageBarRow(
                    bar: bar,
                    trackColor: cardBorder,
                    textColor: textColor,
                    dimTextColor: dimTextColor,
                    accentColor: accentColor,
                    warningColor: warningColor,
                    dangerColor: dangerColor
                )
            }

            ForEach(section.plainLines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(dimTextColor)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(cardBorder, lineWidth: 1)
        )
    }
}

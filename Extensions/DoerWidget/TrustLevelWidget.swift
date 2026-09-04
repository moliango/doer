import SwiftUI
import WidgetKit

struct TrustLevelWidget: Widget {
    let kind = TrustLevelWidgetIDs.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TrustLevelProvider()) { entry in
            TrustLevelWidgetView(entry: entry)
                .widgetURL(URL(string: TrustLevelWidgetIDs.deepLink))
        }
        .configurationDisplayName(String(localized: "trust.widget.title", defaultValue: "信任等级"))
        .description(String(localized: "trust.widget.desc", defaultValue: "已读帖子与升到下一级还差多少"))
        .supportedFamilies([.systemSmall, .systemMedium])
        .disableWidgetContentMargins()
    }
}

struct TrustLevelProvider: TimelineProvider {
    func placeholder(in context: Context) -> TrustLevelEntry {
        TrustLevelEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (TrustLevelEntry) -> Void) {
        completion(TrustLevelEntry(date: Date(), snapshot: TrustLevelWidgetSnapshotStore.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrustLevelEntry>) -> Void) {
        let snapshot = TrustLevelWidgetSnapshotStore.load()
        let entry = TrustLevelEntry(date: Date(), snapshot: snapshot)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(3600))))
    }
}

struct TrustLevelEntry: TimelineEntry {
    let date: Date
    let snapshot: TrustLevelWidgetSnapshot?
}

private extension TrustLevelWidgetSnapshot {
    static let placeholder = TrustLevelWidgetSnapshot(
        title: String(localized: "trust.widget.title", defaultValue: "信任等级"),
        badgeText: String(localized: "trust.widget.unmet", defaultValue: "未达标"),
        subtitle: "",
        items: [
            TrustLevelWidgetItem(
                label: String(localized: "trust.widget.posts_read", defaultValue: "已读帖子"),
                current: 5_000,
                target: 20_000,
                isMet: false,
                isReverse: false
            ),
            TrustLevelWidgetItem(
                label: String(localized: "trust.req.days_visited", defaultValue: "访问天数"),
                current: 92,
                target: 100,
                isMet: false,
                isReverse: false
            ),
            TrustLevelWidgetItem(
                label: String(localized: "trust.req.replies", defaultValue: "回复"),
                current: 12,
                target: 30,
                isMet: false,
                isReverse: false
            ),
            TrustLevelWidgetItem(
                label: String(localized: "trust.req.likes_received", defaultValue: "获赞"),
                current: 8,
                target: 20,
                isMet: false,
                isReverse: false
            ),
        ],
        updatedAt: Date(),
        trustLevel: 2
    )
}

private enum TrustWidgetPalette {
    static func background(_ scheme: ColorScheme) -> LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.11, green: 0.16, blue: 0.24),
                    Color(red: 0.14, green: 0.20, blue: 0.32),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [
                Color(red: 0.89, green: 0.94, blue: 1.00),
                Color(red: 0.78, green: 0.88, blue: 0.99),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func fill(_ scheme: ColorScheme) -> Color {
        if scheme == .dark {
            return Color(red: 0.12, green: 0.17, blue: 0.26)
        }
        return Color(red: 0.86, green: 0.92, blue: 0.99)
    }

    static let ink = Color(red: 0.12, green: 0.18, blue: 0.30)
    static let mute = Color(red: 0.45, green: 0.52, blue: 0.62)
    static let accent = Color(red: 0.18, green: 0.43, blue: 0.90)
    static let met = Color(red: 0.18, green: 0.72, blue: 0.44)
    static let warn = Color(red: 0.96, green: 0.62, blue: 0.12)

    static func barColor(index: Int, isMet: Bool) -> Color {
        if isMet { return met }
        switch index % 3 {
        case 0: return accent
        case 1: return met
        default: return warn
        }
    }
}

struct TrustLevelWidgetView: View {
    var entry: TrustLevelEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot)
            } else {
                emptyState
            }
        }
        .modifier(TrustWidgetCardChrome(family: family, colorScheme: colorScheme))
    }

    private var emptyState: some View {
        HStack(alignment: .center, spacing: 12) {
            penguin(size: family == .systemSmall ? 56 : 82)
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "trust.widget.title", defaultValue: "信任等级"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(titleColor)
                Text(String(localized: "trust.widget.empty", defaultValue: "打开 App 后同步等级进度"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TrustWidgetPalette.mute)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func content(_ snapshot: TrustLevelWidgetSnapshot) -> some View {
        switch family {
        case .systemMedium:
            mediumContent(snapshot)
        default:
            smallContent(snapshot)
        }
    }

    private func smallContent(_ snapshot: TrustLevelWidgetSnapshot) -> some View {
        let item = snapshot.headlineItem
        return HStack(alignment: .center, spacing: 10) {
            penguin(size: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(String(localized: "trust.widget.title", defaultValue: "信任等级"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    levelBadge(snapshot.levelBadgeText)
                }
                if let item {
                    Text(item.formattedCurrent)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(titleColor)
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                    Text(item.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TrustWidgetPalette.mute)
                        .lineLimit(1)
                    TrustHairlineBar(
                        value: item.fractionComplete,
                        color: TrustWidgetPalette.barColor(index: 0, isMet: item.isMet)
                    )
                    .padding(.top, 4)
                    Text(progressCaption(item))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(item.isMet ? TrustWidgetPalette.met : titleColor)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func mediumContent(_ snapshot: TrustLevelWidgetSnapshot) -> some View {
        let headline = snapshot.headlineItem
        let rows = Array(snapshot.secondaryItems.prefix(3))
        return HStack(alignment: .center, spacing: 12) {
            penguin(size: 86)
            VStack(alignment: .leading, spacing: 6) {
                header(snapshot)
                if let headline {
                    heroMetric(headline)
                }
                ForEach(Array(rows.enumerated()), id: \.element.label) { index, item in
                    requirementRow(item, colorIndex: index + 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ snapshot: TrustLevelWidgetSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(localized: "trust.widget.title", defaultValue: "信任等级"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(titleColor)
                .lineLimit(1)
            levelBadge(snapshot.levelBadgeText)
            if !snapshot.badgeText.isEmpty, snapshot.badgeText != snapshot.levelBadgeText {
                statusPill(snapshot.badgeText)
            }
            Spacer(minLength: 4)
            Text(
                String(
                    format: String(localized: "trust.widget.updated_format", defaultValue: "更新于 %@", comment: "Widget updated-at, argument is MM-dd HH:mm"),
                    snapshot.formattedUpdatedAt
                )
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(TrustWidgetPalette.mute)
            .lineLimit(1)
        }
    }

    private func heroMetric(_ item: TrustLevelWidgetItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.formattedCurrent)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(titleColor)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text("\(item.label)  ·  \(progressCaption(item))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(item.isMet ? TrustWidgetPalette.met : TrustWidgetPalette.mute)
                .lineLimit(1)
        }
    }

    private func requirementRow(_ item: TrustLevelWidgetItem, colorIndex: Int) -> some View {
        let color = TrustWidgetPalette.barColor(index: colorIndex, isMet: item.isMet)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.isMet ? "checkmark.circle.fill" : symbolName(for: item.label))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                Text(item.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(item.isMet ? String(localized: "trust.widget.met", defaultValue: "已达标") : "\(item.formattedCurrent) / \(item.formattedTarget)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(item.isMet ? TrustWidgetPalette.met : TrustWidgetPalette.mute)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            TrustHairlineBar(value: item.fractionComplete, color: color)
        }
    }

    private func levelBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(TrustWidgetPalette.accent, in: Capsule())
    }

    private func statusPill(_ text: String) -> some View {
        let met = text.contains("已达标") || text.lowercased().contains("met")
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(met ? TrustWidgetPalette.met : TrustWidgetPalette.warn)
            .lineLimit(1)
    }

    private func penguin(size: CGFloat) -> some View {
        Image("PenguinMascot")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var titleColor: Color {
        colorScheme == .dark ? .white : TrustWidgetPalette.ink
    }

    private func progressCaption(_ item: TrustLevelWidgetItem) -> String {
        if item.isMet {
            return String(localized: "trust.widget.met", defaultValue: "已达标")
        }
        if item.isReverse {
            return String(
                format: String(localized: "trust.widget.keep_under_format", defaultValue: "需保持 ≤ %@"),
                item.formattedTarget
            )
        }
        return String(
            format: String(localized: "trust.widget.remaining_format", defaultValue: "还差 %@"),
            item.formattedRemaining
        )
    }

    private func symbolName(for label: String) -> String {
        if label.contains("读") || label.lowercased().contains("post") { return "book.fill" }
        if label.contains("天") || label.lowercased().contains("day") { return "calendar" }
        if label.contains("赞") || label.lowercased().contains("like") { return "heart.fill" }
        if label.contains("回复") || label.lowercased().contains("repl") { return "bubble.left.fill" }
        if label.contains("浏览") || label.contains("话题") { return "square.stack.fill" }
        if label.contains("时间") || label.contains("分钟") { return "clock.fill" }
        if label.contains("禁言") { return "speaker.slash.fill" }
        if label.contains("举报") { return "exclamationmark.triangle.fill" }
        return "circle.fill"
    }
}

private struct TrustHairlineBar: View {
    var value: Double
    var color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(color.opacity(0.16))
                Capsule()
                    .fill(color)
                    .frame(width: max(4, geo.size.width * CGFloat(min(max(value, 0), 1))))
            }
        }
        .frame(height: 4)
    }
}

private struct TrustWidgetCardChrome: ViewModifier {
    var family: WidgetFamily
    var colorScheme: ColorScheme

    func body(content: Content) -> some View {
        let padded = content
            .padding(family == .systemSmall ? 12 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        if #available(iOS 17.0, *) {
            padded.containerBackground(for: .widget) {
                ZStack {
                    TrustWidgetPalette.fill(colorScheme)
                    TrustWidgetPalette.background(colorScheme)
                }
            }
        } else {
            padded.background(
                ZStack {
                    TrustWidgetPalette.fill(colorScheme)
                    TrustWidgetPalette.background(colorScheme)
                }
            )
        }
    }
}

private extension WidgetConfiguration {
    func disableWidgetContentMargins() -> some WidgetConfiguration {
        if #available(iOS 17.0, *) {
            return contentMarginsDisabled()
        }
        return self
    }
}

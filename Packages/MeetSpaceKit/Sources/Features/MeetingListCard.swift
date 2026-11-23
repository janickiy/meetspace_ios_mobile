import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct MeetingListItem<Value: Identifiable>: Identifiable {
    let value: Value
    let title: String
    let date: Date?
    let duration: Int?
    let status: ConferenceTimelineView
    let cancelled: Bool
    let mine: Bool
    var owner: String?
    var attendees: Int?
    var id: Value.ID { value.id }

    var statusTitle: String {
        switch status {
        case .upcoming: date == nil ? "Без даты" : "Запланирована"
        case .active: "В эфире"
        case .past: cancelled ? "Отменена" : "Завершена"
        }
    }
}

struct MeetingListCard<Value: Identifiable>: View {
    let item: MeetingListItem<Value>
    let zone: TimeZone
    let wide: Bool
    let identifier: String
    let open: () -> Void
    let details: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: wide ? .center : .top, spacing: wide ? 18 : 12))
        layout {
            dateBlock
            VStack(alignment: .leading, spacing: 5) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 6) {
                        statusBadge
                        Text(verbatim: item.title).font(MSTheme.font(wide ? 16 : 14, weight: .semibold))
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        ViewThatFits(in: .horizontal) {
                            if wide { HStack(spacing: 12) { role; attendees } }
                            VStack(alignment: .leading, spacing: 6) { role; attendees }
                        }
                    }.padding(.top, wide ? 0 : 4).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier(identifier)
                if !wide && item.status == .past { materialsButton }
            }.padding(.trailing, !wide && !typeSize.isAccessibilitySize ? 20 : 0)
            if wide {
                if item.status == .past { materialsButton }
                detailsButton
            }
        }.padding(.horizontal, wide ? 21 : 13).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: wide ? 105 : 122, alignment: wide ? .center : .topLeading)
            .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(item.status == .active ? MSTheme.accent : MSTheme.line) }
            .overlay(alignment: .topTrailing) { if !wide { detailsButton } }
    }

    private var dateBlock: some View {
        VStack(spacing: 4) {
            if let date = item.date {
                Text(calendarText(date, format: "HH:mm", zone: zone)).font(MSTheme.font(wide ? 21 : 17, weight: .semibold))
                    .monospacedDigit().foregroundStyle(MSTheme.accent)
                Text(calendarText(date, format: "d MMMM", zone: zone))
            } else {
                WorkspaceIcon("video", size: 20)
                Text(tr("Без даты"))
            }
        }.font(MSTheme.font(wide ? 11 : 10)).foregroundStyle(MSTheme.muted)
            .padding(5).frame(width: typeSize.isAccessibilitySize ? nil : (wide ? 85 : 72)).frame(minHeight: wide ? 64 : 60)
            .background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(scheme == .dark ? Color(red: 0.408, green: 0.537, blue: 0.729) : Color(red: 0.651, green: 0.804, blue: 0.961)) }
            .accessibilityElement(children: .combine)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            if item.status == .active { Circle().frame(width: 5, height: 5) }
            Text(tr(item.statusTitle))
        }.font(MSTheme.font(9)).padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(item.status == .active ? MSTheme.success : MSTheme.muted)
            .background(item.status == .active ? MSTheme.success.opacity(0.12) : MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 5))
    }

    private var role: some View {
        let duration = item.duration.map { "\($0) " + tr("мин") + "  ·  " } ?? ""
        return Text(duration + tr(item.mine ? "Вы организатор" : "Вы участник"))
            .font(MSTheme.font(wide ? 11 : 10)).foregroundStyle(MSTheme.muted).frame(minHeight: wide ? 17 : 15).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var attendees: some View {
        if let count = item.attendees {
            let noun: String = switch (count % 100, count % 10) {
            case (11...14, _): "участников"
            case (_, 1): "участник"
            case (_, 2...4): "участника"
            default: "участников"
            }
            let organizer = wide && !item.mine ? item.owner.map { " · " + $0 } ?? "" : ""
            HStack(spacing: 4) {
                WorkspaceIcon("person.2", size: 12)
                Text("\(count) " + tr(noun) + organizer)
            }.font(MSTheme.font(10)).foregroundStyle(MSTheme.muted).frame(minHeight: 15)
        }
    }

    private var detailsButton: some View {
        Button(action: details) { WorkspaceIcon("ellipsis", size: 20).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel(tr("Подробнее о встрече") + " " + item.title)
            .accessibilityIdentifier("\(identifier).details")
    }

    private var materialsButton: some View {
        Button(action: open) { Label(tr("Материалы"), systemImage: "folder")
            .font(MSTheme.font(11)).padding(.horizontal, 10).frame(minHeight: 34)
            .background(MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}

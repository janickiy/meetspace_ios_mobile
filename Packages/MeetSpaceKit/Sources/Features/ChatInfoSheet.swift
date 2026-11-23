import SwiftUI
import MeetSpaceAPI
import MeetSpaceDesignSystem

struct ChatInfoSheet<Details: View, Materials: View>: View {
    let name: String
    var initials: String?
    let status: String
    var group = false
    var edit: (() -> Void)?
    var call: (() -> Void)?
    var videoCall: (() -> Void)?
    @ViewBuilder let details: () -> Details
    @ViewBuilder let materials: (ChatMaterialKind) -> Materials

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var kind = ChatMaterialKind.media
    @State private var contentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 52
    private var identifier: String { group ? "chatGroupSheet" : "chatContactSheet" }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width <= 600
            let inset: CGFloat = compact ? 14 : 20
            let available = max(0, geometry.size.height - 2 * inset - headerHeight)
            ZStack {
                Color(red: 15 / 255, green: 27 / 255, blue: 60 / 255).opacity(96 / 255)
                    .ignoresSafeArea().onTapGesture { dismiss() }.accessibilityHidden(true)
                VStack(spacing: 0) {
                    HStack {
                        Text(tr(group ? "О группе" : "О контакте"))
                            .font(MSTheme.font(14, weight: .semibold)).foregroundStyle(MSTheme.muted)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        IconButton("xmark", label: "Закрыть") { dismiss() }
                            .accessibilityIdentifier("\(identifier).close")
                    }.padding(.leading, compact ? 16 : 24).padding(.trailing, compact ? 8 : 16)
                        .frame(minHeight: compact ? 52 : 56)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                    ScrollView {
                        VStack(spacing: compact ? 16 : 18) {
                            VStack(spacing: 10) {
                                ChatAvatar(name: name, initials: initials, size: compact ? 60 : 72).clipShape(Circle())
                                VStack(spacing: 4) {
                                    Text(name).font(MSTheme.font(compact ? 21 : 24, weight: .semibold))
                                        .tracking(-0.4).accessibilityAddTraits(.isHeader)
                                    Text(status).font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
                                }.multilineTextAlignment(.center)
                            }.padding(.top, 2)
                            actionRow(compact: compact)
                            details()
                            VStack(spacing: 12) {
                                tabs
                                materials(kind)
                            }
                        }.padding(.horizontal, compact ? 16 : 24).padding(.bottom, compact ? 18 : 24)
                            .frame(maxWidth: .infinity)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }.scrollBounceBehavior(.basedOnSize)
                        .frame(height: contentHeight > 0 ? min(contentHeight, available) : available)
                }
                .frame(maxWidth: 560)
                .background(MSTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 23 : 24))
                .shadow(color: .black.opacity(0.13), radius: 20, y: 10)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
                .padding(inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .bottom : .center)
            }
        }.foregroundStyle(MSTheme.ink).tint(MSTheme.accent)
            .accessibilityAction(.escape) { dismiss() }
        #if os(iOS)
            .presentationBackground(.clear)
        #else
            .frame(minWidth: 410, minHeight: 580)
        #endif
    }

    private func actionRow(compact: Bool) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        let stretch = (compact || typeSize.isAccessibilitySize) && (edit != nil || call != nil)
        return layout {
            Button { dismiss() } label: {
                actionLabel(group ? "Перейти в чат" : "Сообщение", icon: "message", stretch: stretch)
            }
            if let edit {
                Button(action: edit) { actionLabel("Редактировать группу", icon: "pencil", stretch: stretch) }
            }
            if let call {
                if let videoCall {
                    Menu {
                        Button(action: call) { Label(tr("Аудиозвонок"), systemImage: "phone") }
                        Button(action: videoCall) { Label(tr("Видеозвонок"), systemImage: "video") }
                            .accessibilityIdentifier("startVideoCall")
                    } label: { actionLabel("Позвонить", icon: "phone", stretch: stretch) }
                        .menuIndicator(.hidden).accessibilityIdentifier("chatInfo.call")
                } else {
                    Button(action: call) { actionLabel("Позвонить", icon: "phone", stretch: stretch) }
                        .accessibilityIdentifier("chatInfo.call")
                }
            }
        }.buttonStyle(.plain)
    }

    private func actionLabel(_ text: String, icon: String, stretch: Bool) -> some View {
        HStack(spacing: 7) {
            WorkspaceIcon(icon, size: 17)
            Text(tr(text)).font(MSTheme.font(13, weight: .semibold)).multilineTextAlignment(.center)
        }.foregroundStyle(MSTheme.brandAccent)
            .padding(.horizontal, stretch ? 8 : 18).padding(.vertical, 8)
            .frame(maxWidth: stretch ? .infinity : nil, minHeight: 44)
            .background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 14))
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(ChatMaterialKind.allCases, id: \.self) { item in
                Button { kind = item } label: {
                    Text(tr(item.title)).font(MSTheme.font(13, weight: .semibold))
                        .multilineTextAlignment(.center).padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(item == kind ? MSTheme.brandAccent : MSTheme.muted)
                        .background {
                            if item == kind {
                                RoundedRectangle(cornerRadius: 20).fill(MSTheme.surface)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                            }
                        }
                }.buttonStyle(.plain).accessibilityAddTraits(kind == item ? .isSelected : [])
                    .accessibilityIdentifier("chatInfo.tab.\(item.rawValue)")
            }
        }.padding(4).frame(maxWidth: 332)
            .background(MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct ChatInfoDetails: View {
    let fields: [(String, String)]
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(fields, id: \.0) { key, value in
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) :
                    AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                layout {
                    Text(tr(key)).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                        .frame(width: typeSize.isAccessibilitySize ? nil : 76, alignment: .leading)
                    Text(value).font(MSTheme.font(14)).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityElement(children: .combine)
            }
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(MSTheme.background, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ChatInfoMembers<Members: View>: View {
    let count: Int?
    @ViewBuilder let members: () -> Members
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    WorkspaceIcon("person.2", size: 17)
                    Text(tr("Участники")).font(MSTheme.font(13, weight: .semibold))
                    Spacer()
                    if let count { Text(String(count)).font(MSTheme.font(12, weight: .semibold)).foregroundStyle(MSTheme.muted) }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 13)).foregroundStyle(MSTheme.muted)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("chatGroupSheet.members")
            if expanded {
                VStack(alignment: .leading, spacing: 8) { members() }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
            }
        }.padding(.horizontal, 15).background(MSTheme.background, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ChatInfoMember: View {
    let name: String
    var role: String?
    var body: some View {
        HStack(spacing: 8) {
            ChatAvatar(name: name, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(MSTheme.font(13, weight: .semibold))
                if let role { Text(tr(role)).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted) }
            }
        }
    }
}

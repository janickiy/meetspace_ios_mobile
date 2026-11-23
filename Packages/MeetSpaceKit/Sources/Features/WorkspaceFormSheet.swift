import SwiftUI
import MeetSpaceDesignSystem

/// Workspace forms in the prototype share a floating, scrollable card.
struct WorkspaceFormSheet<Content: View>: View {
    let title: String
    let identifier: String
    var closeLabel = "Закрыть"
    var busy = false
    var centered = false
    var dividedHeader = false
    var maxWidth: CGFloat?
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 600
            let inset: CGFloat = compact ? 14 : 20
            let availableHeight = max(0, geometry.size.height - inset * 2)
            let scrollHeight = max(0, availableHeight - (dividedHeader ? headerHeight : 0))
            ZStack {
                #if os(iOS)
                Color(red: 15 / 255, green: 27 / 255, blue: 60 / 255).opacity(96 / 255).ignoresSafeArea()
                    .onTapGesture { if !busy { close() } }
                    .accessibilityHidden(true)
                #endif
                VStack(spacing: 0) {
                    if dividedHeader {
                        VStack(spacing: 0) {
                            header(compact: compact).padding(.horizontal, compact ? 21 : 24).padding(.vertical, 8)
                            Divider()
                        }.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if !dividedHeader { header(compact: compact) }
                            content()
                        }.padding(compact ? 21 : 24)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }.scrollDismissesKeyboard(.interactively)
                        .frame(height: contentHeight > 0 ? min(contentHeight, scrollHeight) : scrollHeight)
                }.frame(maxWidth: maxWidth ?? (centered ? 510 : 440))
                    .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: compact ? 23 : 24))
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 23 : 24))
                    .overlay(RoundedRectangle(cornerRadius: compact ? 23 : 24).strokeBorder(MSTheme.line).allowsHitTesting(false))
                    .shadow(color: .black.opacity(0.15), radius: 25, y: 15)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("\(identifier).form")
                    .padding(inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact && !centered ? .bottom : .center)
            }
        }
        .foregroundStyle(MSTheme.ink)
        .font(MSTheme.font(13))
        .tint(MSTheme.accent)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .accessibilityAction(.escape) { if !busy { close() } }
        #if os(iOS)
        .presentationBackground(.clear)
        .presentationDragIndicator(.hidden)
        #else
        .frame(minWidth: 410, minHeight: 580)
        #endif
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Text(tr(title)).font(MSTheme.font(compact ? 20 : 21, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            IconButton("xmark", label: closeLabel, action: close)
                .accessibilityIdentifier("\(identifier).close")
        }.padding(.trailing, -8)
    }
}

struct WorkspaceFormField<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr(title)).font(MSTheme.font(13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    @ViewBuilder
    func workspaceFormPresentation<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                                  @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        self.blur(radius: isPresented.wrappedValue ? 5 : 0)
            .fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #else
        self.sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }

    @ViewBuilder
    func workspaceFormPresentation<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
            @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(iOS)
        self.blur(radius: item.wrappedValue == nil ? 0 : 5)
            .fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #else
        self.sheet(item: item, onDismiss: onDismiss, content: content)
        #endif
    }

    func workspaceFormInput(minHeight: CGFloat = 50) -> some View {
        self.font(MSTheme.font(16))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MSTheme.line).allowsHitTesting(false))
    }
}

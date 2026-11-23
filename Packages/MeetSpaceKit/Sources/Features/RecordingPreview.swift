import SwiftUI
import MeetSpaceDesignSystem

struct RecordingPreview: View {
    let entry: RecordingLibraryEntry
    var large = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let unit = min(size.width, size.height)
            ZStack {
                background
                switch entry.kind {
                case .tracks: tracks(unit: unit)
                case .audio: RecordingWave().foregroundStyle(Color(red: 0.45, green: 0.78, blue: 0.73))
                        .padding(.horizontal, unit * 0.09).frame(height: unit * 0.48)
                case .video: tiles(unit: unit)
                default: EmptyView()
                }
                if !large {
                    WorkspaceIcon(entry.isCapturing ? "circle" : entry.kind.icon, size: min(20, unit * 0.17))
                        .foregroundStyle(.white).frame(width: min(40, unit * 0.36), height: min(40, unit * 0.36))
                        .background(Color(red: 0.10, green: 0.13, blue: 0.21).opacity(0.9), in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.24)) }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !large, let badge = entry.durationText ?? (entry.isCapturing ? tr("В эфире") : nil) {
                    Text(badge).font(.system(size: 9, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 2)
                        .background(entry.isCapturing ? Color(red: 0.59, green: 0.17, blue: 0.25) : .black.opacity(0.68),
                                    in: RoundedRectangle(cornerRadius: 3)).padding(4)
                }
            }
        }.clipShape(RoundedRectangle(cornerRadius: large ? 0 : 10)).accessibilityHidden(true)
    }

    private var background: some View {
        let colors: [Color] = switch entry.kind {
        case .tracks: [Color(red: 0.16, green: 0.14, blue: 0.24), Color(red: 0.13, green: 0.12, blue: 0.21)]
        case .audio: [Color(red: 0.15, green: 0.29, blue: 0.32), Color(red: 0.10, green: 0.19, blue: 0.25)]
        default: [Color(red: 0.15, green: 0.18, blue: 0.27), Color(red: 0.12, green: 0.14, blue: 0.22)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func tiles(unit: CGFloat) -> some View {
        let colors = [Color(red: 0.33, green: 0.40, blue: 0.58), Color(red: 0.44, green: 0.36, blue: 0.52),
                      Color(red: 0.20, green: 0.46, blue: 0.46), Color(red: 0.47, green: 0.37, blue: 0.39)]
        return VStack(spacing: unit * 0.035) {
            ForEach(0..<2) { row in
                HStack(spacing: unit * 0.035) {
                    ForEach(0..<2) { column in
                        let index = row * 2 + column
                        Group {
                            if entry.initials.indices.contains(index) {
                                Text(entry.initials[index]).font(.system(size: min(21, unit * 0.085), weight: .semibold))
                            } else {
                                Image(systemName: "person.fill").font(.system(size: min(24, unit * 0.115)))
                            }
                        }.foregroundStyle(.white.opacity(0.82))
                            .frame(width: min(58, unit * 0.23), height: min(58, unit * 0.23)).background(colors[index], in: Circle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(colors[index].opacity(0.43), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }.padding(unit * 0.08)
    }

    private func tracks(unit: CGFloat) -> some View {
        VStack(spacing: unit * 0.045) {
            ForEach(0..<3) { index in
                HStack(spacing: unit * 0.05) {
                    if entry.initials.indices.contains(index) {
                        Text(entry.initials[index]).font(.system(size: min(17, unit * 0.087), weight: .semibold))
                            .foregroundStyle(Color(red: 0.85, green: 0.80, blue: 0.94))
                    }
                    RecordingWave().foregroundStyle(Color(red: 0.60, green: 0.69, blue: 0.82))
                }
                .padding(.horizontal, unit * 0.055).padding(.vertical, unit * 0.025)
                .frame(maxHeight: .infinity).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
            }
        }.padding(.horizontal, unit * 0.11).padding(.vertical, unit * (large ? 0.17 : 0.18))
    }
}

private struct RecordingWave: View {
    var body: some View {
        Canvas { context, size in
            let count = max(1, min(25, Int(size.width / 4)))
            let step = size.width / CGFloat(count)
            for index in 0..<count {
                let height = size.height * CGFloat(18 + index * 17 % 38) / 55
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: step * 0.52, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: step / 4), with: .foreground)
            }
        }
    }
}

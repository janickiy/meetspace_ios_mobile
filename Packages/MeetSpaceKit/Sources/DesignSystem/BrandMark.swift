import SwiftUI

/// Paths transcribed from mobile_maket/assets/brand-mark.svg (viewBox 0 0 220 230).
public struct BrandMark: View {
    public init() {}
    public var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 220, geometry.size.height / 230)
            ZStack(alignment: .topLeading) {
                Circle().fill(gradient([(0x06dfff, 0), (0x00b9f4, 0.48), (0x0064ff, 1)], start: .topLeading, end: UnitPoint(x: 0.65, y: 1)))
                    .frame(width: 54, height: 54).offset(x: 25, y: 0)
                Circle().fill(gradient([(0xc34dff, 0), (0x9140ff, 0.55), (0x5e25ff, 1)], start: UnitPoint(x: 0.85, y: 0), end: UnitPoint(x: 0.2, y: 1)))
                    .frame(width: 54, height: 54).offset(x: 124, y: 0)
                BrandShape(part: .back).fill(gradient([(0xce55f4, 0), (0x9841fd, 0.38), (0x413cff, 1)], start: .topTrailing, end: UnitPoint(x: 0.1, y: 1)))
                BrandShape(part: .front).fill(gradient([(0x00d4f3, 0), (0x009efe, 0.3), (0x2448ff, 0.62), (0x7620ff, 1)], start: UnitPoint(x: 8 / 200, y: 84 / 210), end: UnitPoint(x: 188 / 200, y: 204 / 210)))
                BrandShape(part: .left).fill(gradient([(0x00c2f6, 0), (0x0095ff, 0.48), (0x0751ff, 1)], start: UnitPoint(x: 0.2, y: 1), end: UnitPoint(x: 0.8, y: 0)))
                BrandShape(part: .play).fill(gradient([(0xffffff, 0), (0xf4fdff, 0.48), (0xbdd9ff, 1)], start: UnitPoint(x: 0.3, y: 0), end: UnitPoint(x: 0.75, y: 1)))
            }.frame(width: 200, height: 210).offset(x: 10, y: 10)
                .scaleEffect(scale, anchor: .topLeading)
        }.aspectRatio(220 / 230, contentMode: .fit).accessibilityHidden(true)
    }
    private func gradient(_ stops: [(UInt, CGFloat)], start: UnitPoint, end: UnitPoint) -> LinearGradient {
        LinearGradient(stops: stops.map { hex, position in
            .init(color: Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                               blue: Double(hex & 255) / 255), location: position)
        }, startPoint: start, endPoint: end)
    }
}

private struct BrandShape: Shape {
    enum Part { case back, front, left, play }
    let part: Part
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func move(_ x: CGFloat, _ y: CGFloat) { p.move(to: CGPoint(x: x, y: y)) }
        func line(_ x: CGFloat, _ y: CGFloat) { p.addLine(to: CGPoint(x: x, y: y)) }
        func curve(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat, _ x: CGFloat, _ y: CGFloat) {
            p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: a, y: b), control2: CGPoint(x: c, y: d))
        }
        switch part {
        case .back:
            move(103,85); line(129,69); curve(140,61,149,58,160,59); curve(184,60,200,76,200,100)
            line(200,172); curve(200,195,186,210,166,210); curve(153,210,143,205,130,196); line(49,141)
        case .front:
            move(42,59); curve(54,59,63,63,77,73); line(180,147); curve(193,156,200,165,200,178)
            curve(200,197,186,210,166,210); curve(153,210,141,204,128,194); line(65,149)
            curve(53,141,44,142,33,151); line(0,179); line(0,101); curve(0,78,17,59,42,59)
        case .left:
            move(0,172); curve(0,160,5,151,15,143); line(38,125); curve(47,118,55,118,64,124)
            line(105,154); line(64,190); curve(51,202,41,208,28,208); curve(11,208,0,193,0,172)
        case .play:
            move(86.693,109.25); curve(83.193,107.15,80.393,109.25,80.393,113.45); line(80.393,150.55)
            curve(80.393,154.75,83.893,156.85,87.393,154.75); line(113.993,139.35)
            curve(120.993,135.15,121.693,130.95,114.693,126.75); line(86.693,109.25)
        }
        p.closeSubpath(); return p
    }
}

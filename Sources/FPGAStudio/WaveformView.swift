import FPGAStudioCore
import SwiftUI

struct WaveformView: View {
    let document: VCDDocument?
    @State private var query = ""
    @State private var zoom = 1.0
    @State private var cursor: UInt64 = 0
    @State private var radix: VCDRadix = .hexadecimal

    var body: some View {
        if let document {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter signals", text: $query).textFieldStyle(.plain).frame(width: 180)
                    Divider().frame(height: 18)
                    Button { zoom = max(0.5, zoom / 1.4) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { zoom = min(20, zoom * 1.4) } label: { Image(systemName: "plus.magnifyingglass") }
                    Picker("Radix", selection: $radix) { ForEach(VCDRadix.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                        .labelsHidden().frame(width: 120)
                    Spacer()
                    Text("Cursor \(cursor) · \(document.timescale)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.padding(.horizontal, 10).frame(height: 34).background(.bar)
                ScrollView([.horizontal, .vertical]) {
                    WaveformCanvas(document: document, signals: filtered(document.signals), zoom: zoom, cursor: $cursor, radix: radix)
                        .frame(width: max(900, 900 * zoom), height: max(120, CGFloat(filtered(document.signals).count) * 34 + 34))
                }
            }
        } else {
            ContentUnavailableView("No Waveform", systemImage: "waveform.path", description: Text("Run a simulation that writes waves.vcd."))
        }
    }

    private func filtered(_ signals: [VCDSignal]) -> [VCDSignal] {
        query.isEmpty ? signals : signals.filter { $0.qualifiedName.localizedCaseInsensitiveContains(query) }
    }
}

private struct WaveformCanvas: View {
    let document: VCDDocument
    let signals: [VCDSignal]
    let zoom: Double
    @Binding var cursor: UInt64
    let radix: VCDRadix
    private let labelWidth: CGFloat = 220

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let plotWidth = max(1, size.width - labelWidth - 20)
                let scale = plotWidth / CGFloat(max(1, document.endTime))
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .textBackgroundColor)))
                for index in signals.indices {
                    let signal = signals[index]
                    let y = CGFloat(index) * 34 + 42
                    context.draw(Text(signal.qualifiedName).font(.system(size: 11, design: .monospaced)).foregroundStyle(.primary), at: CGPoint(x: 8, y: y), anchor: .leading)
                    let value = signal.value(at: cursor).map { signal.formatted($0, radix: radix) } ?? "—"
                    context.draw(Text(value).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary), at: CGPoint(x: labelWidth - 8, y: y), anchor: .trailing)
                    var path = Path()
                    if signal.width == 1 {
                        drawScalar(signal, into: &path, y: y, scale: scale)
                    } else {
                        drawBus(signal, into: &path, y: y, scale: scale)
                    }
                    context.stroke(path, with: .color(.green), lineWidth: 1.3)
                    context.stroke(Path { $0.move(to: CGPoint(x: labelWidth, y: y + 15)); $0.addLine(to: CGPoint(x: size.width, y: y + 15)) }, with: .color(.secondary.opacity(0.12)))
                }
                let cursorX = labelWidth + CGFloat(cursor) * scale
                context.stroke(Path { $0.move(to: CGPoint(x: cursorX, y: 0)); $0.addLine(to: CGPoint(x: cursorX, y: size.height)) }, with: .color(.orange), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let width = max(1, geometry.size.width - labelWidth - 20)
                let normalized = max(0, min(1, (value.location.x - labelWidth) / width))
                cursor = UInt64(normalized * CGFloat(document.endTime))
            })
        }
    }

    private func x(_ time: UInt64, scale: CGFloat) -> CGFloat { labelWidth + CGFloat(time) * scale }

    private func drawScalar(_ signal: VCDSignal, into path: inout Path, y: CGFloat, scale: CGFloat) {
        guard !signal.changes.isEmpty else { return }
        for index in signal.changes.indices {
            let change = signal.changes[index]
            let next = index + 1 < signal.changes.count ? signal.changes[index + 1].time : document.endTime
            let high = change.value == "1"
            let level = y + (high ? -8 : 8)
            if index == 0 { path.move(to: CGPoint(x: x(change.time, scale: scale), y: level)) }
            else { path.addLine(to: CGPoint(x: x(change.time, scale: scale), y: level)) }
            path.addLine(to: CGPoint(x: x(next, scale: scale), y: level))
        }
    }

    private func drawBus(_ signal: VCDSignal, into path: inout Path, y: CGFloat, scale: CGFloat) {
        guard !signal.changes.isEmpty else { return }
        for index in signal.changes.indices {
            let start = x(signal.changes[index].time, scale: scale)
            let end = x(index + 1 < signal.changes.count ? signal.changes[index + 1].time : document.endTime, scale: scale)
            path.move(to: CGPoint(x: start, y: y - 7)); path.addLine(to: CGPoint(x: end, y: y - 7))
            path.move(to: CGPoint(x: start, y: y + 7)); path.addLine(to: CGPoint(x: end, y: y + 7))
            path.move(to: CGPoint(x: start, y: y - 7)); path.addLine(to: CGPoint(x: start + 5, y: y)); path.addLine(to: CGPoint(x: start, y: y + 7))
        }
    }
}

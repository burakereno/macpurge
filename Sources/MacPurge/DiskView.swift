#if SWIFT_PACKAGE
import MacPurgeCore
#endif
import SwiftUI

/// An elevation drawing of stacked sheets. Each line follows the same ridge
/// at a slightly different depth, like the layers that make up disk usage.
private struct Relief: View {
    var body: some View {
        Canvas { ctx, size in
            for row in 0..<44 {
                let t = Double(row) / 43
                var p = Path()
                for column in 0...115 {
                    let u = Double(column) / 115
                    let x = 0.025 + u * 0.93 + (t - 0.5) * 0.18
                    let ridge = sin(u * .pi) * (0.22 + 0.27 * sin(5.7 * u + 2.0 * t))
                    let y = 0.29 + 0.47 * t + 0.10 * u - ridge - 0.07 * sin(9.0 * u - t)
                    let point = CGPoint(x: x * size.width, y: y * size.height)
                    if column == 0 { p.move(to: point) } else { p.addLine(to: point) }
                }
                let alpha = 0.24 + 0.58 * (1 - t)
                ctx.stroke(p, with: .color(Ink.mint.opacity(alpha)), lineWidth: row.isMultiple(of: 7) ? 1.45 : 0.85)
            }
        }
        .accessibilityHidden(true)
    }
}

struct DiskView: View {
    let disk: VolumeReading
    init(reading: VolumeReading) { disk = reading }
    init(freeMB: Int) {
        disk = VolumeReading(name: "Macintosh HD", bytes: 512_000_000_000, free: Int64(freeMB) * 1_000_000)
    }
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.17, blue: 0.18), Color(red: 0.09, green: 0.29, blue: 0.27)], startPoint: .bottomLeading, endPoint: .topTrailing)
            GeometryReader { geo in
                Relief().frame(width: geo.size.width * 0.58, height: 169)
                    .position(x: geo.size.width * 0.79, y: 73)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0.32), .init(color: .white, location: 0.60)], startPoint: .leading, endPoint: .trailing))
            }
            VStack(alignment: .leading, spacing: 0) {
                Label(disk.name, systemImage: "internaldrive").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.84))
                Text(byteLabel(disk.free)).font(.system(size: 46, weight: .semibold)).tracking(-2).foregroundStyle(.white)
                    .padding(.top, 9)
                Text("kullanılabilir alan").font(.system(size: 14)).foregroundStyle(.white.opacity(0.78))
                Spacer(minLength: 16)
                GeometryReader { geo in
                    Capsule().fill(Color(red: 0.37, green: 0.54, blue: 0.51))
                    Capsule().fill(Ink.mint)
                        .frame(width: geo.size.width * max(0, min(1, 1 - CGFloat(disk.free) / CGFloat(disk.bytes))))
                }.frame(height: 5)
                HStack {
                    Text("\(byteLabel(max(0, disk.bytes - disk.free))) kullanımda")
                    Spacer()
                    Text("\(byteLabel(disk.bytes)) toplam")
                }.font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.82)).padding(.top, 7)
            }.padding(.vertical, 18).padding(.horizontal, 22)
        }
        .frame(height: 171)
        .clipShape(RoundedRectangle(cornerRadius: 17))
        .accessibilityElement(children: .combine)
    }
}

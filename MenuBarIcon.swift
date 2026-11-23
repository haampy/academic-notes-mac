import SwiftUI

struct MenuBarIcon: View {
    let recording: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame = 0

    private var moving: Bool { recording && !reduceMotion }

    var body: some View {
        Image(nsImage: Self.frames[moving ? frame : 0])
            .accessibilityLabel(recording ? "Purrk，正在记录" : "Purrk")
            .task(id: moving) {
                frame = 0
                guard moving else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(65)) }
                    catch { return }
                    frame = (frame + 1) % Self.frames.count
                }
            }
    }

    // Rotate each ear around its base so the mark stays centered in the menu bar.
    static let frames: [NSImage] = (0..<32).map { index in
        let phase = 2 * CGFloat.pi * CGFloat(index) / 32
        let tilt = sin(phase) * .pi / 24
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for right in [false, true] {
                context.saveGState()
                context.translateBy(x: right ? 20.4 : 3.6, y: 14.65)
                context.rotate(by: tilt)
                context.scaleBy(x: right ? -1 : 1, y: 1)
                context.translateBy(x: -3.1, y: -14.25)
                context.addPath(ear)
                context.fillPath()
                context.restoreGState()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // A closed contour lets the outer rim and the short inner fold taper independently.
    private static let ear: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2.9, y: 14.3))
        path.addCurve(to: CGPoint(x: 2.72, y: 2.98),
                      control1: CGPoint(x: 1.8, y: 10.83), control2: CGPoint(x: 1.92, y: 5.08))
        path.addQuadCurve(to: CGPoint(x: 3.8, y: 2.57), control: CGPoint(x: 2.99, y: 2.19))
        path.addCurve(to: CGPoint(x: 10.44, y: 9.23),
                      control1: CGPoint(x: 6.48, y: 3.85), control2: CGPoint(x: 9.05, y: 6.37))
        path.addQuadCurve(to: CGPoint(x: 10.14, y: 9.77), control: CGPoint(x: 10.71, y: 9.75))
        path.addQuadCurve(to: CGPoint(x: 4.84, y: 11.7), control: CGPoint(x: 8.16, y: 9.82))
        path.addQuadCurve(to: CGPoint(x: 8.65, y: 8.83), control: CGPoint(x: 6.26, y: 9.45))
        path.addQuadCurve(to: CGPoint(x: 3.72, y: 4.55), control: CGPoint(x: 6.71, y: 6.26))
        path.addQuadCurve(to: CGPoint(x: 3.25, y: 14.28), control: CGPoint(x: 3.16, y: 7.69))
        path.addQuadCurve(to: CGPoint(x: 2.9, y: 14.3), control: CGPoint(x: 3.23, y: 14.81))
        path.closeSubpath()
        return path
    }()
}

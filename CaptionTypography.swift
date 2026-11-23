import Foundation

struct CaptionTypography: Equatable {
    static let preferenceKey = "captionFontSize"
    static let defaultSize = 12
    static let sizes = 10...24

    let bodySize: CGFloat

    init(_ size: Int) {
        bodySize = CGFloat(max(Self.sizes.lowerBound, min(size, Self.sizes.upperBound)))
    }

    var scale: CGFloat { bodySize / CGFloat(Self.defaultSize) }
    var titleSize: CGFloat { bodySize }
    var deviceSize: CGFloat { max(10, 11 * scale) }
    var statusSize: CGFloat { max(10, 10 * scale) }
    var timestampSize: CGFloat { statusSize }
    var actionSize: CGFloat { deviceSize }
}

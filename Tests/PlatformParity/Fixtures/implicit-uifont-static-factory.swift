import UIKit

func scaledPlatformFontSize(baseSize: CGFloat) -> CGFloat {
    UIFontMetrics.default.scaledValue(for: baseSize)
}

func makePlatformSystemFont(size: CGFloat) -> UIFont {
    .systemFont(ofSize: scaledPlatformFontSize(baseSize: size))
}

func implicitPlatformStaticFactorySucceeds() -> Bool {
    _ = makePlatformSystemFont(size: 13)
    return true
}

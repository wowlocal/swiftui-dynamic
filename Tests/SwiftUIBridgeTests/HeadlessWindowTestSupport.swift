import AppKit

/// Keeps displayed headless test windows alive for the test process lifetime.
///
/// Closing an AppKit window starts a private transform-animation teardown that
/// can outlive its test. A later `Process.waitUntilExit()` pumps the main run
/// loop and may release that animation after its window graph is gone. These
/// tests exercise hosted SwiftUI behavior, not window presentation, so they
/// retire content while retaining the animation-disabled window shell.
@MainActor
enum HeadlessWindowTestLifetime {
    private static var retainedWindows: [NSWindow] = []

    static func retain(_ window: NSWindow) {
        window.animationBehavior = .none
        retainedWindows.append(window)
    }

    static func retire(_ window: NSWindow) {
        window.contentView = nil
    }
}

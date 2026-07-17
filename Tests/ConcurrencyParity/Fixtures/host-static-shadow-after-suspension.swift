import Foundation

extension Date {
    static var now: Date {
        Date(timeIntervalSince1970: 1_784_228_400)
    }
}

@MainActor
func parityHostStaticShadowAfterSuspension() async -> String {
    await Task.yield()
    return parityHostDateEpoch(.now)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parityHostStaticShadowAfterSuspension()
}

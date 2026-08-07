import Models
import SwiftUI

/// The twin's window onto IceCubes' APP TARGET, as opposed to its packages.
///
/// `Examples/IceCubesNativeTwin/Package.swift` depended only on
/// `External/oss/IceCubesApp/Packages/*`, so every View declared under
/// `IceCubesApp/IceCubesApp/**` was unreachable by the native twin and
/// therefore permanently unscorable on the R2 pixel board — 36 files, 30 of
/// them declaring View types, including the whole Settings tab, the signed-out
/// instance picker this LOOP's quarantine explicitly requires to render
/// pixel-identically, and the tab shell. The interpreted side has always
/// merged those files (`paths.appFiles`), so the asymmetry was the twin's
/// alone: no expectation could be captured for any of it, no matter how many
/// package screens were admitted.
///
/// Two constraints shape the fix. SwiftPM rejects a target whose `path`
/// escapes the package root outright ("target 'X' in package 'Y' is outside
/// the package root"), so each admitted app file is SYMLINKED into this
/// directory — the same device the twin already uses to share
/// `CaptureGeometryDump.swift` with `Sources/IceCubesCheck`. One link per
/// file rather than one link to `App/`, so that the directory listing is
/// itself the list of app sources the twin compiles and SwiftPM has no
/// unhandled files to warn about. And the app's screens are `internal`: a
/// separate module cannot name them. This file is compiled INTO the same
/// module as the app sources it exposes, which is what lets it hand them out
/// publicly without editing a single app file. App sources stay read-only,
/// exactly as the LOOP requires; the seam is here.
///
/// Screens join one file at a time rather than the app target joining
/// wholesale. Its 36 files together need RevenueCat, WishKit, AppIntents and
/// all 13 local packages; admitting that closure would be a build project
/// rather than a measurement. Each screen brings only its own imports.
public enum AppTargetScreen {
    /// The app's `InstanceInfoView` (`App/Tabs/Settings/InstanceInfoView.swift`),
    /// the screen `SettingsTab` pushes for the signed-in instance and the
    /// first app-target screen this board can score. It is a pure function of
    /// the `Instance` it is handed — the recorded `/api/v2/instance` response
    /// drives every branch of it — so it needs no fetch, no clock and no
    /// namespace to be deterministic.
    @MainActor
    public static func instanceInfo(instance: Instance) -> some View {
        InstanceInfoView(instance: instance)
    }
}

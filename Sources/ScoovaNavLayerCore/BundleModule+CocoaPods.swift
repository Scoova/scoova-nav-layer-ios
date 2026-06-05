//
//  BundleModule+CocoaPods.swift
//  ScoovaNavLayerCore
//
//  SwiftPM auto-synthesises `Bundle.module` for any target that ships
//  resources. CocoaPods doesn't — it routes the same resources into a
//  pod-named resource bundle instead. This file bridges that gap so the
//  same SDK source (VoicePack.swift, etc.) compiles under both build
//  systems with no `#if` clutter in the call sites.
//
//  The whole shim is guarded by `!SWIFT_PACKAGE` so SPM users keep the
//  compiler-synthesised `Bundle.module` and we don't shadow it.
//

#if !SWIFT_PACKAGE
import Foundation

private final class _ScoovaNavLayerCoreBundleToken {}

extension Bundle {
    /// Resource bundle for this module under CocoaPods. The pod's
    /// `resource_bundles` config builds `ScoovaNavLayerCore.bundle` and
    /// embeds it inside the framework — we resolve it relative to the
    /// framework's own Bundle.
    static let module: Bundle = {
        let host = Bundle(for: _ScoovaNavLayerCoreBundleToken.self)
        if let url = host.url(forResource: "ScoovaNavLayerCore",
                              withExtension: "bundle"),
           let resourceBundle = Bundle(url: url) {
            return resourceBundle
        }
        return host
    }()
}
#endif

#
# ScoovaNavLayerCore.podspec — voice + cues + thresholds + spatial audio.
#
# One framework per SPM target so the cross-module `import` statements in
# the SDK source files (ScoovaNavLayerUI, ScoovaRoutingAdapter) keep
# working under CocoaPods. With sub-specs CocoaPods rolls everything into
# a single framework, which breaks those imports.
#
Pod::Spec.new do |s|
  s.name             = "ScoovaNavLayerCore"
  s.module_name      = "ScoovaNavLayerCore"
  s.version          = "1.0.1"
  s.summary          = "Scoova Nav Layer — voice + cues core."
  s.description      = "Dialect-aware turn-by-turn voice engine, eyes-off cue grammar, spatial audio panning, chain-absorb, sensor-fused heading."
  s.homepage         = "https://scoo-va.info"
  s.license          = { :type => "MIT" }
  s.author           = { "Scoova" => "admin@scoo-va.info" }
  s.source           = { :git => "https://github.com/Scoova/scoova-nav-layer-ios.git",
                         :tag => s.version.to_s }
  s.ios.deployment_target = "15.0"
  s.osx.deployment_target = "13.0"
  s.swift_versions        = ["5.9"]

  s.source_files = "Sources/ScoovaNavLayerCore/**/*.swift"
  s.resource_bundles = {
    "ScoovaNavLayerCore" => ["Sources/ScoovaNavLayerCore/Resources/voicepack/**/*"]
  }
  s.frameworks   = "Foundation", "AVFoundation", "CoreLocation", "CoreMotion"
end

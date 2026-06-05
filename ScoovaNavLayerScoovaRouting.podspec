#
# ScoovaNavLayerScoovaRouting.podspec — Scoova routing API adapter.
#
Pod::Spec.new do |s|
  s.name             = "ScoovaNavLayerScoovaRouting"
  s.module_name      = "ScoovaNavLayerScoovaRouting"
  s.version          = "1.0.0"
  s.summary          = "Scoova Nav Layer — Scoova routing adapter."
  s.description      = "Bridges Scoova's routing API (rich scoova.* voice + banner blocks) into ScoovaNavLayer's maneuver feed."
  s.homepage         = "https://scoo-va.info"
  s.license          = { :type => "MIT" }
  s.author           = { "Scoova" => "admin@scoo-va.info" }
  s.source           = { :git => "https://github.com/Scoova/scoova-nav-layer-ios.git",
                         :tag => s.version.to_s }
  s.ios.deployment_target = "15.0"
  s.osx.deployment_target = "13.0"
  s.swift_versions        = ["5.9"]

  s.source_files = "Sources/ScoovaNavLayerScoovaRouting/**/*.swift"
  s.dependency     "ScoovaNavLayerCore", s.version.to_s
end

#
# ScoovaNavLayerUI.podspec — SwiftUI banner + heading puck + route card.
#
Pod::Spec.new do |s|
  s.name             = "ScoovaNavLayerUI"
  s.module_name      = "ScoovaNavLayerUI"
  s.version          = "1.0.1"
  s.summary          = "Scoova Nav Layer — SwiftUI components."
  s.description      = "Drop-in SwiftUI banner (ScoovaManeuverBanner), heading puck (ScoovaHeadingPuck), and route preview card."
  s.homepage         = "https://scoo-va.info"
  s.license          = { :type => "MIT" }
  s.author           = { "Scoova" => "admin@scoo-va.info" }
  s.source           = { :git => "https://github.com/Scoova/scoova-nav-layer-ios.git",
                         :tag => s.version.to_s }
  s.ios.deployment_target = "15.0"
  s.osx.deployment_target = "13.0"
  s.swift_versions        = ["5.9"]

  s.source_files = "Sources/ScoovaNavLayerUI/**/*.swift"
  s.dependency     "ScoovaNavLayerCore", s.version.to_s
  s.frameworks   = "SwiftUI"
end

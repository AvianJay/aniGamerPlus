#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint video_player_pip.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'video_player_pip'
  s.version          = '0.0.1'
  s.summary          = 'A Picture-in-Picture plugin for Flutter video_player'
  s.description      = <<-DESC
A Flutter plugin that adds Picture-in-Picture functionality to the video_player package.
                       DESC
  s.homepage         = 'https://github.com/AkmaljonAbdirakhimov/video_player_pip'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Akmaljon Abdirakhimov' => 'akmaljonabdirakhimov@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'  # PiP requires iOS 15+
  
  # Required frameworks for PiP functionality
  s.frameworks = 'AVFoundation', 'AVKit'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'video_player_pip_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end

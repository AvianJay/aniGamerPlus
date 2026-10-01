#
# 投放中 App 退到背景時, 用一段靜音讓 iOS 別把它暫停.
#
Pod::Spec.new do |s|
  s.name             = 'cast_keepalive'
  s.version          = '0.1.0'
  s.summary          = 'Keeps the app running in the background while casting.'
  s.description      = <<-DESC
Plays silent audio, mixed with other apps, while the app is casting from the
background, so iOS does not suspend it and the player can keep following the
Chromecast (next episode, watch progress).
                       DESC
  s.homepage         = 'https://github.com/AvianJay/aniGamerPlus'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'aniGamerPlus' => 'noreply@github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.frameworks = 'AVFoundation'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end

#
# AirPlay 按鈕 (AVRoutePickerView) 與目前的音訊路由.
#
Pod::Spec.new do |s|
  s.name             = 'airplay_route'
  s.version          = '0.1.0'
  s.summary          = 'AirPlay route picker button and route state for the player.'
  s.description      = <<-DESC
Wraps AVRoutePickerView as a Flutter platform view and reports whether the
current audio route is an AirPlay device, so the player can hand the Apple TV
a URL it can actually reach.
                       DESC
  s.homepage         = 'https://github.com/AvianJay/aniGamerPlus'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'aniGamerPlus' => 'noreply@github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end

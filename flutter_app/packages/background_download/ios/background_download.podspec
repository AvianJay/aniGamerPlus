#
# 背景下載: 系統的背景 URLSession 抓影片檔, 動態島 / 鎖定畫面的即時動態顯示進度.
#
Pod::Spec.new do |s|
  s.name             = 'background_download'
  s.version          = '0.1.0'
  s.summary          = 'Background video downloads with a Live Activity showing progress.'
  s.description      = <<-DESC
Hands video downloads to a background URLSession so they keep going after the app
is suspended, and mirrors progress into a Live Activity (Dynamic Island / Lock Screen).
                       DESC
  s.homepage         = 'https://github.com/AvianJay/aniGamerPlus'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'aniGamerPlus' => 'noreply@github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  # 即時動態是 iOS 16.1 起才有, App 本體還支援 15: 弱連結, 用到的地方都有 #available 擋著
  s.weak_frameworks = 'ActivityKit'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end

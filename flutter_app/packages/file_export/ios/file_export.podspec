#
# 把 App 沙盒裡的檔案交給檔案 App 的匯出面板.
#
Pod::Spec.new do |s|
  s.name             = 'file_export'
  s.version          = '0.1.0'
  s.summary          = 'Export files from the app sandbox through the system document picker.'
  s.description      = <<-DESC
Presents UIDocumentPickerViewController(forExporting:asCopy:) so the user can save
downloaded files anywhere the Files app can reach.
                       DESC
  s.homepage         = 'https://github.com/AvianJay/aniGamerPlus'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'aniGamerPlus' => 'noreply@github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  # UIDocumentPickerViewController(forExporting:asCopy:) 是 iOS 14 起才有
  s.platform = :ios, '15.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end

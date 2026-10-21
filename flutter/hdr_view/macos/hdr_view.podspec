Pod::Spec.new do |s|
  s.name             = 'hdr_view'
  s.version          = '0.0.1'
  s.summary          = 'Native HDR10 remote screen view for RustDesk on macOS.'
  s.description      = 'AVSampleBufferDisplayLayer-backed platform view fed HEVC Main10 BT.2020 PQ access units.'
  s.homepage         = 'https://github.com/rustdesk/rustdesk'
  s.license          = { :type => 'AGPL-3.0' }
  s.author           = { 'RustDesk' => 'info@rustdesk.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.frameworks       = 'AVFoundation', 'CoreMedia'

  s.platform = :osx, '10.14'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end

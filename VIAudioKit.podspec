Pod::Spec.new do |s|
  s.name         = 'VIAudioKit'
  s.version      = '0.1.0'
  s.summary      = 'Cross-platform audio player with chunked downloading, custom decoding and AVAudioEngine rendering.'
  s.homepage     = 'https://github.com/example/VIAudioKit'
  s.license      = { :type => 'MIT', :file => 'LICENSE' }
  s.author       = { 'VIAudioKit' => 'dev@example.com' }
  s.source       = { :git => 'https://github.com/example/VIAudioKit.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.swift_version = '5.9'

  s.source_files = 'Sources/**/*.swift'
  s.frameworks   = 'Foundation', 'AVFoundation', 'AudioToolbox', 'Network', 'CryptoKit'
  s.pod_target_xcconfig = { 'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => 'COCOAPODS' }
end

Pod::Spec.new do |s|
  s.name         = 'VIAudioKit'
  s.version      = '0.1.0'
  s.summary      = 'Cross-platform audio player with chunked downloading, custom decoding and AVAudioEngine rendering.'
  s.homepage     = 'https://github.com/wanqingrongruo/VIAudioKit'
  s.license      = { :type => 'MIT', :file => 'LICENSE' }
  s.author       = { 'VIAudioKit' => 'wanqingrongruo' }
  s.source       = { :git => 'https://github.com/wanqingrongruo/VIAudioKit.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.swift_version = '5.9'

  s.static_framework = true

  s.default_subspec = 'Core'

  s.subspec 'Core' do |core|
    core.source_files = 'Sources/VIAudioDownloader/**/*.swift', 'Sources/VIAudioDecoder/**/*.swift', 'Sources/VIAudioPlayer/**/*.swift'
    core.frameworks   = 'Foundation', 'AVFoundation', 'AudioToolbox', 'Network', 'CryptoKit'
    core.pod_target_xcconfig = { 'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => 'COCOAPODS' }
  end

  s.subspec 'FFmpeg' do |ffmpeg|
    ffmpeg.dependency 'VIAudioKit/Core'
    ffmpeg.dependency 'ffmpeg-kit-ios-full'
    ffmpeg.source_files = 'Sources/VIAudioFFmpeg/**/*.{swift,h,m,c}'
    ffmpeg.preserve_paths = 'Sources/VIAudioFFmpeg/include/module.modulemap'
    ffmpeg.pod_target_xcconfig = { 
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => 'COCOAPODS',
      'SWIFT_INCLUDE_PATHS' => '$(PODS_TARGET_SRCROOT)/Sources/VIAudioFFmpeg/include',
      'USER_HEADER_SEARCH_PATHS' => '$(inherited) ${PODS_ROOT}/ffmpeg-kit-ios-full/ffmpegkit.xcframework/ios-arm64/ffmpegkit.framework/Headers'
    }
  end
end

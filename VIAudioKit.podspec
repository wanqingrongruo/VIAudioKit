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
    ffmpeg.source_files = 'Sources/VIAudioFFmpeg/**/*.{swift,m,c}'
    ffmpeg.preserve_paths = 'Sources/VIAudioFFmpeg/include/module.modulemap', 'Sources/VIAudioFFmpeg/include/**/*.h'
    ffmpeg.pod_target_xcconfig = { 
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => 'COCOAPODS',
      'SWIFT_INCLUDE_PATHS' => '$(PODS_TARGET_SRCROOT)/Sources/VIAudioFFmpeg/include',
      'USER_HEADER_SEARCH_PATHS' => '$(inherited) ${PODS_ROOT}/ffmpeg-kit-ios-full/ffmpegkit.xcframework/ios-arm64/ffmpegkit.framework/Headers'
    }
  end

  # 为已经手动集成 FFmpegKit 的宿主 App 提供的免依赖 Subspec
  s.subspec 'FFmpeg-Manual' do |ffmpeg|
    ffmpeg.dependency 'VIAudioKit/Core'
    ffmpeg.source_files = 'Sources/VIAudioFFmpeg/**/*.{swift,m,c}'
    ffmpeg.preserve_paths = 'Sources/VIAudioFFmpeg/include/module.modulemap', 'Sources/VIAudioFFmpeg/include/**/*.h'
    ffmpeg.pod_target_xcconfig = { 
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => 'COCOAPODS',
      'SWIFT_INCLUDE_PATHS' => '$(PODS_TARGET_SRCROOT)/Sources/VIAudioFFmpeg/include'
      # 注意：由于去掉了依赖，宿主工程必须在自己的 Build Settings 中确保 FFmpeg headers 可被发现
      # 或者手动拖入的 Framework 头文件已经暴露给 CocoaPods
    }
  end
end

platform :ios, '16.0'
use_frameworks!
inhibit_all_warnings!

target 'FileManagerApp' do

  # ── Networking ─────────────────────────────────────────────────────────────
  pod 'Alamofire', '~> 5.8'

  # ── Keychain ───────────────────────────────────────────────────────────────
  pod 'KeychainAccess', '~> 4.2'

  # ── SFTP (libssh2 wrapper, BSD licensed) ───────────────────────────────────
  # https://github.com/NMSSH/NMSSH (~1.6k stars)
  pod 'NMSSH', '~> 2.3'

  # ── SMB / CIFS (libsmb2 wrapper, LGPL) ─────────────────────────────────────
  # https://github.com/amosavian/AMSMB2 (~700 stars, the de-facto Swift SMB client)
  pod 'AMSMB2', '~> 3.0'

  # ── Image loading & disk caching ───────────────────────────────────────────
  pod 'Kingfisher', '~> 7.10'

  # ── Text syntax highlighting ───────────────────────────────────────────────
  pod 'Highlightr', '~> 2.1'

end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
      config.build_settings['SWIFT_VERSION'] = '5.9'
    end
  end
end

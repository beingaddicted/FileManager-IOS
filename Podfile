platform :ios, '16.0'
use_frameworks!
inhibit_all_warnings!

target 'FileManagerApp' do

  # ── Networking ─────────────────────────────────────────────────────────────
  pod 'Alamofire', '~> 5.8'           # HTTP networking layer

  # ── Keychain ───────────────────────────────────────────────────────────────
  pod 'KeychainAccess', '~> 4.2'      # Secure credential storage

  # ── SFTP (SSH File Transfer Protocol) ─────────────────────────────────────
  pod 'NMSSH', '~> 2.3'              # libssh2-based SSH/SFTP

  # ── SMB (Windows file shares) ─────────────────────────────────────────────
  # Uncomment when targeting SMB support:
  # pod 'AMSMB2', '~> 3.0'           # SMB2/3 client

  # ── Image loading & caching ────────────────────────────────────────────────
  pod 'Kingfisher', '~> 7.10'        # Async image loading / disk cache

end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
      config.build_settings['SWIFT_VERSION'] = '5.9'
    end
  end
end

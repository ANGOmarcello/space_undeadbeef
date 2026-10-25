#!/usr/bin/env ruby
# Created by Angelo Cammalleri on 25.10.2026.

require 'xcodeproj'
require 'fileutils'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'SPACE UNDEADBEEF.xcodeproj')
project = Xcodeproj::Project.new(project_path)
project.root_object.attributes['LastUpgradeCheck'] = '2720'
project.root_object.attributes['ORGANIZATIONNAME'] = 'Angelo Cammalleri'
project.root_object.compatibility_version = 'Xcode 14.0'

source_group = project.main_group.new_group('Sources', 'Sources')
host_group = source_group.new_group('Host', 'Host')
legacy_group = source_group.new_group('Legacy', 'Legacy')
host_sources = Dir.glob(File.join(root, 'Sources/Host/*.swift')).sort.map do |path|
  host_group.new_file(File.basename(path))
end
legacy_files = Dir.glob(File.join(root, 'Sources/Legacy/*.{h,c,cpp,m,mm}')).sort.map do |path|
  legacy_group.new_file(File.basename(path))
end
legacy_sources = legacy_files.reject { |file| file.path.end_with?('.h') }
config_group = project.main_group.new_group('Config', 'Config')
config = config_group.new_file('App.xcconfig')
config_group.new_file('SpaceUndeadbeef-Bridging-Header.h')
resources_group = project.main_group.new_group('Resources', 'Resources')
original = resources_group.new_file('Original')
original.last_known_file_type = 'folder'
tests_group = project.main_group.new_group('Tests', 'Tests')
ui_test_source = tests_group.new_file('HostUITests.swift')

platforms = {
  'iOS' => { platform: :ios, version: '18.0', sdk: 'iphoneos', supported: 'iphoneos iphonesimulator', family: '1,2', deployment: 'IPHONEOS_DEPLOYMENT_TARGET', suffix: '' },
  'macOS' => { platform: :osx, version: '15.0', sdk: 'macosx', supported: 'macosx', family: nil, deployment: 'MACOSX_DEPLOYMENT_TARGET', suffix: '.mac' },
  'tvOS' => { platform: :tvos, version: '18.0', sdk: 'appletvos', supported: 'appletvos appletvsimulator', family: '3', deployment: 'TVOS_DEPLOYMENT_TARGET', suffix: '.tv' },
  'watchOS' => { platform: :watchos, version: '11.0', sdk: 'watchos', supported: 'watchos watchsimulator', family: '4', deployment: 'WATCHOS_DEPLOYMENT_TARGET', suffix: '.watch' }
}

schemes = []
platforms.each do |name, options|
  target = project.new_target(:application, "SPACE UNDEADBEEF #{name}", options[:platform], options[:version])
  target.product_name = 'SpaceUndeadbeef'
  target.product_reference.path = 'SpaceUndeadbeef.app'
  target.product_reference.name = "SpaceUndeadbeef (#{name}).app"
  (host_sources + legacy_sources).each { |file| target.source_build_phase.add_file_reference(file) }
  target.resources_build_phase.add_file_reference(original)
  target.add_system_frameworks(['Foundation', 'CoreGraphics', 'ImageIO', 'AVFoundation'])
  plist_path = File.join(root, 'Config', "#{name}-Info.plist")
  plist = {
    'CFBundleDevelopmentRegion' => 'en',
    'CFBundleDisplayName' => 'SPACE UNDEADBEEF',
    'CFBundleExecutable' => '$(EXECUTABLE_NAME)',
    'CFBundleIdentifier' => '$(PRODUCT_BUNDLE_IDENTIFIER)',
    'CFBundleInfoDictionaryVersion' => '6.0',
    'CFBundleName' => '$(PRODUCT_NAME)',
    'CFBundlePackageType' => 'APPL',
    'CFBundleShortVersionString' => '$(MARKETING_VERSION)',
    'CFBundleVersion' => '$(CURRENT_PROJECT_VERSION)',
    'ITSAppUsesNonExemptEncryption' => false
  }
  case name
  when 'iOS'
    plist['LSRequiresIPhoneOS'] = true
    plist['UIApplicationSceneManifest'] = { 'UIApplicationSupportsMultipleScenes' => false }
    plist['UILaunchScreen'] = {}
    plist['UISupportedInterfaceOrientations'] = ['UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight']
    plist['UISupportedInterfaceOrientations~ipad'] = ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight']
    plist['UIStatusBarHidden'] = true
    plist['UIViewControllerBasedStatusBarAppearance'] = true
  when 'macOS'
    plist['NSPrincipalClass'] = 'NSApplication'
    plist['LSApplicationCategoryType'] = 'public.app-category.action-games'
    plist['NSHighResolutionCapable'] = true
  when 'watchOS'
    plist['WKApplication'] = true
    plist['WKWatchOnly'] = true
  end
  Xcodeproj::Plist.write_to_path(plist, plist_path)
  config_group.new_file("#{name}-Info.plist")
  target.build_configurations.each do |configuration|
    configuration.base_configuration_reference = config
    settings = configuration.build_settings
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = "dev.cammalleri.SpaceUndeadbeef#{options[:suffix]}"
    settings['INFOPLIST_FILE'] = "Config/#{name}-Info.plist"
    settings['SDKROOT'] = options[:sdk]
    settings['SUPPORTED_PLATFORMS'] = options[:supported]
    settings[options[:deployment]] = options[:version]
    settings['TARGETED_DEVICE_FAMILY'] = options[:family] if options[:family]
    settings['SUPPORTS_MACCATALYST'] = 'NO' if name == 'iOS'
    settings['SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD'] = 'NO' if name == 'iOS'
    settings['ENABLE_APP_SANDBOX'] = 'YES' if name == 'macOS'
    settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', name == 'macOS' ? '@executable_path/../Frameworks' : '@executable_path/Frameworks']
  end
  ui_target = nil
  if ['iOS', 'tvOS'].include?(name)
    ui_target = project.new_target(:ui_test_bundle, "SPACE UNDEADBEEF #{name} UITests", options[:platform], options[:version])
    ui_target.add_dependency(target)
    ui_target.source_build_phase.add_file_reference(ui_test_source)
    ui_target.build_configurations.each do |configuration|
      settings = configuration.build_settings
      settings['PRODUCT_BUNDLE_IDENTIFIER'] = "dev.cammalleri.SpaceUndeadbeef#{options[:suffix]}.uitests"
      settings['TEST_TARGET_NAME'] = target.name
      settings['SWIFT_VERSION'] = '6.0'
      settings['GENERATE_INFOPLIST_FILE'] = 'YES'
      settings['SDKROOT'] = options[:sdk]
      settings['SUPPORTED_PLATFORMS'] = options[:supported]
      settings['TARGETED_DEVICE_FAMILY'] = options[:family]
      settings[options[:deployment]] = options[:version]
      settings['CODE_SIGN_STYLE'] = 'Automatic'
    end
  end
  schemes << [name, target, ui_target]
end

project.predictabilize_uuids
project.save
schemes.each do |name, target, ui_target|
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(target)
  scheme.set_launch_target(target)
  scheme.add_test_target(ui_target) if ui_target
  scheme.launch_action.build_configuration = 'Debug'
  scheme.archive_action.build_configuration = 'Release'
  scheme.save_as(project_path, "SPACE UNDEADBEEF #{name}", true)
end
puts project_path

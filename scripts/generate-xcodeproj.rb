#!/usr/bin/env ruby
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# frozen_string_literal: true

require 'fileutils'
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'Rinflow.xcodeproj')
source_root = File.join(root, 'Rinflow')

# The Swift packages' pinned versions survive regenerating the project.
resolved_path = File.join(project_path, 'project.xcworkspace', 'xcshareddata', 'swiftpm', 'Package.resolved')
resolved = File.exist?(resolved_path) ? File.read(resolved_path) : nil

FileUtils.rm_rf(project_path)
project = Xcodeproj::Project.new(project_path)
project.root_object.attributes['LastSwiftUpdateCheck'] = '2660'
project.root_object.attributes['LastUpgradeCheck'] = '2660'

target = project.new_target(:application, 'Rinflow', :osx, '14.0')
app_group = project.main_group.new_group('Rinflow', 'Rinflow')

Dir.glob(File.join(source_root, '**', '*.swift')).sort.each do |path|
  relative = path.delete_prefix("#{source_root}/")
  group = relative.split('/')[0...-1].reduce(app_group) do |parent, component|
    parent.groups.find { |item| item.display_name == component } || parent.new_group(component, component)
  end
  reference = group.new_file(relative.split('/').last)
  target.source_build_phase.add_file_reference(reference)
end

bridging_group = app_group.groups.find { |group| group.display_name == 'Bridging' } || app_group.new_group('Bridging', 'Bridging')
bridging_group.new_file('Rinflow-Bridging-Header.h')
resources_group = app_group.groups.find { |group| group.display_name == 'Resources' } || app_group.new_group('Resources', 'Resources')
resources_group.new_file('Info.plist')
# The app icon is an Icon Composer document (light / dark / tinted from one glyph);
# Xcode also derives the AppIcon.icns that macOS before 26 reads. MenuBarIcon is
# a template image, so the menu bar tints it for light, dark and wallpaper.
app_icon = resources_group.new_file('AppIcon.icon')
app_icon.last_known_file_type = 'folder.iconcomposer.icon'
target.resources_build_phase.add_file_reference(app_icon)
target.resources_build_phase.add_file_reference(resources_group.new_file('Assets.xcassets'))
target.resources_build_phase.add_file_reference(resources_group.new_file('THIRD_PARTY_NOTICES.txt'))

# Localizations: String Catalogs whose source language is Simplified Chinese,
# the language the code is written in. English stays the development region,
# so a system language Rinflow doesn't have gets English, not Chinese.
project.root_object.development_region = 'en'
project.root_object.known_regions = %w[en Base ja zh-Hans]
%w[Localizable.xcstrings InfoPlist.xcstrings].each do |name|
  catalog = resources_group.new_file(name)
  catalog.last_known_file_type = 'text.json.xcstrings'
  target.resources_build_phase.add_file_reference(catalog)
end

# Sparkle, for updates from the GitHub releases (Rinflow/App/Updater.swift).
# An exact version: an update of the updater is a decision, not a side effect.
sparkle = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
sparkle.repositoryURL = 'https://github.com/sparkle-project/Sparkle'
sparkle.requirement = { 'kind' => 'exactVersion', 'version' => '2.10.1' }
project.root_object.package_references << sparkle
sparkle_product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
sparkle_product.package = sparkle
sparkle_product.product_name = 'Sparkle'
target.package_product_dependencies << sparkle_product
sparkle_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
sparkle_file.product_ref = sparkle_product
target.frameworks_build_phase.files << sparkle_file

scripts_group = project.main_group.new_group('scripts', 'scripts')
scripts_group.new_file('build-rust.sh')
scripts_group.new_file('generate-xcodeproj.rb')

rust_phase = target.new_shell_script_build_phase('Build Rust Core')
rust_phase.shell_path = '/bin/sh'
rust_phase.shell_script = '"${SRCROOT}/scripts/build-rust.sh"'
rust_phase.output_paths = ['$(BUILT_PRODUCTS_DIR)/librinflow_core.a']
# The Rust source tree lives outside the Xcode project and can gain new files,
# which cannot be represented by a stable list of script-phase input paths.
# Always invoke the phase and let Cargo's incremental build decide what changed.
rust_phase.always_out_of_date = '1'
target.build_phases.delete(rust_phase)
target.build_phases.insert(0, rust_phase)

target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.rinflow.mac'
  settings['PRODUCT_NAME'] = 'Rinflow'
  settings['MARKETING_VERSION'] = '0.0.1'
  # The public half of the EdDSA key that signs updates (Sparkle's
  # generate_keys; the private half stays in the release keychain and the
  # SPARKLE_PRIVATE_KEY secret). Empty: the app never looks for updates.
  settings['SPARKLE_PUBLIC_KEY'] = ''
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['INFOPLIST_FILE'] = 'Rinflow/Resources/Info.plist'
  settings['SWIFT_OBJC_BRIDGING_HEADER'] = 'Rinflow/Bridging/Rinflow-Bridging-Header.h'
  settings['HEADER_SEARCH_PATHS'] = ['$(inherited)', '$(SRCROOT)/../rinflow-core/include']
  settings['LIBRARY_SEARCH_PATHS'] = ['$(inherited)', '$(BUILT_PRODUCTS_DIR)']
  settings['OTHER_LDFLAGS'] = [
    '$(inherited)',
    '-force_load',
    '$(BUILT_PRODUCTS_DIR)/librinflow_core.a',
    '-liconv'
  ]
  settings['SWIFT_VERSION'] = '6.0'
  settings['SWIFT_STRICT_CONCURRENCY'] = 'complete'
  # The compiler lists the strings the code uses; the catalog is synced from that.
  settings['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  settings['LOCALIZATION_PREFERS_STRING_CATALOGS'] = 'YES'
  settings['CLANG_ENABLE_MODULES'] = 'YES'
  # Cargo reads the sibling Core project and the user's rustup toolchain.
  # Xcode's script sandbox cannot express those dynamic inputs reliably.
  settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = '998ZTJV2HQ'
  settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/../Frameworks']
  # Keep local Debug/Release builds self-contained on the developer's Mac.
  # For a universal archive, install both Rust targets and set this to NO.
  settings['ONLY_ACTIVE_ARCH'] = 'YES'
end

# Unit tests of the pure geometry, without the app (no host): it starts the
# core and asks for permissions, which tests have no business doing.
tests_root = File.join(root, 'RinflowTests')
test_target = project.new_target(:unit_test_bundle, 'RinflowTests', :osx, '14.0')
tests_group = project.main_group.new_group('RinflowTests', 'RinflowTests')
Dir.glob(File.join(tests_root, '*.swift')).sort.each do |path|
  test_target.source_build_phase.add_file_reference(tests_group.new_file(File.basename(path)))
end
['Core/Layout.swift', 'Core/CoreTypes.swift', 'Core/CallbackRelay.swift', 'Model/AppSettings.swift', 'Input/ClipboardBridge.swift', 'Input/CrossingGate.swift', 'Input/ClickTracker.swift', 'Input/InputPlayer.swift', 'Input/HIDKeyMap.swift'].each do |relative|
  reference = app_group.recursive_children.find { |item| item.respond_to?(:real_path) && item.real_path.to_s == File.join(source_root, relative) }
  test_target.source_build_phase.add_file_reference(reference)
end
test_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.rinflow.mac.tests'
  settings['SWIFT_OBJC_BRIDGING_HEADER'] = 'Rinflow/Bridging/Rinflow-Bridging-Header.h'
  settings['HEADER_SEARCH_PATHS'] = ['$(inherited)', '$(SRCROOT)/../rinflow-core/include']
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['SWIFT_VERSION'] = '6.0'
  settings['SWIFT_STRICT_CONCURRENCY'] = 'complete'
  settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = '998ZTJV2HQ'
  settings['ONLY_ACTIVE_ARCH'] = 'YES'
end

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.add_test_target(test_target)
scheme.set_launch_target(target)
scheme.save_as(project_path, 'Rinflow', true)

project.save
# The workspace Xcode and xcodebuild use for the packages; rm_rf took it.
FileUtils.mkdir_p(File.join(project_path, 'project.xcworkspace'))
File.write(File.join(project_path, 'project.xcworkspace', 'contents.xcworkspacedata'), <<~XML)
  <?xml version="1.0" encoding="UTF-8"?>
  <Workspace
     version = "1.0">
     <FileRef
        location = "self:">
     </FileRef>
  </Workspace>
XML
if resolved
  FileUtils.mkdir_p(File.dirname(resolved_path))
  File.write(resolved_path, resolved)
end
puts "Generated #{project_path}"

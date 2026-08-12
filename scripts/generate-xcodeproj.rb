#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'LinkCursor.xcodeproj')
source_root = File.join(root, 'LinkCursor')

FileUtils.rm_rf(project_path)
project = Xcodeproj::Project.new(project_path)
project.root_object.attributes['LastSwiftUpdateCheck'] = '2660'
project.root_object.attributes['LastUpgradeCheck'] = '2660'

target = project.new_target(:application, 'LinkCursor', :osx, '14.0')
app_group = project.main_group.new_group('LinkCursor', 'LinkCursor')

Dir.glob(File.join(source_root, '**', '*.swift')).sort.each do |path|
  relative = path.delete_prefix("#{source_root}/")
  group = relative.split('/')[0...-1].reduce(app_group) do |parent, component|
    parent.groups.find { |item| item.display_name == component } || parent.new_group(component, component)
  end
  reference = group.new_file(relative.split('/').last)
  target.source_build_phase.add_file_reference(reference)
end

bridging_group = app_group.groups.find { |group| group.display_name == 'Bridging' } || app_group.new_group('Bridging', 'Bridging')
bridging_group.new_file('LinkCursor-Bridging-Header.h')
resources_group = app_group.groups.find { |group| group.display_name == 'Resources' } || app_group.new_group('Resources', 'Resources')
resources_group.new_file('Info.plist')

scripts_group = project.main_group.new_group('scripts', 'scripts')
scripts_group.new_file('build-rust.sh')
scripts_group.new_file('generate-xcodeproj.rb')

rust_phase = target.new_shell_script_build_phase('Build Rust Core')
rust_phase.shell_path = '/bin/sh'
rust_phase.shell_script = '"${SRCROOT}/scripts/build-rust.sh"'
rust_phase.output_paths = ['$(BUILT_PRODUCTS_DIR)/liblinkcursor_core.a']
# The Rust source tree lives outside the Xcode project and can gain new files,
# which cannot be represented by a stable list of script-phase input paths.
# Always invoke the phase and let Cargo's incremental build decide what changed.
rust_phase.always_out_of_date = '1'
target.build_phases.delete(rust_phase)
target.build_phases.insert(0, rust_phase)

target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.linkcursor.mac'
  settings['PRODUCT_NAME'] = 'LinkCursor'
  settings['MARKETING_VERSION'] = '0.1.0'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['INFOPLIST_FILE'] = 'LinkCursor/Resources/Info.plist'
  settings['SWIFT_OBJC_BRIDGING_HEADER'] = 'LinkCursor/Bridging/LinkCursor-Bridging-Header.h'
  settings['HEADER_SEARCH_PATHS'] = ['$(inherited)', '$(SRCROOT)/../linkcursor-core/include']
  settings['LIBRARY_SEARCH_PATHS'] = ['$(inherited)', '$(BUILT_PRODUCTS_DIR)']
  settings['OTHER_LDFLAGS'] = [
    '$(inherited)',
    '-force_load',
    '$(BUILT_PRODUCTS_DIR)/liblinkcursor_core.a',
    '-liconv'
  ]
  settings['SWIFT_VERSION'] = '6.0'
  settings['SWIFT_STRICT_CONCURRENCY'] = 'complete'
  settings['CLANG_ENABLE_MODULES'] = 'YES'
  # Cargo reads the sibling Core project and the user's rustup toolchain.
  # Xcode's script sandbox cannot express those dynamic inputs reliably.
  settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/../Frameworks']
  # Keep local Debug/Release builds self-contained on the developer's Mac.
  # For a universal archive, install both Rust targets and set this to NO.
  settings['ONLY_ACTIVE_ARCH'] = 'YES'
end

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(project_path, 'LinkCursor', true)

project.save
puts "Generated #{project_path}"

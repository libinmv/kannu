require 'xcodeproj'

project_path = './DynamicIsland.xcodeproj'
project = Xcodeproj::Project.open(project_path)

ui_test_target = project.targets.find { |t| t.name == 'DynamicIslandUITests' }

ui_test_target.build_configurations.each do |config|
  config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Atoll.app/Contents/MacOS/Atoll'
  config.build_settings['USES_SWIFT_TESTING'] = 'YES'
  config.build_settings['SWIFT_TESTING_FRAMEWORK'] = 'YES'
  config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'YES'
end

project.save
puts "Successfully updated test host and swift testing settings."

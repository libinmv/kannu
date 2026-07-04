require 'xcodeproj'

project_path = './DynamicIsland.xcodeproj'
project = Xcodeproj::Project.open(project_path)

ui_test_target = project.targets.find { |t| t.name == 'DynamicIslandUITests' }

ui_test_target.build_configurations.each do |config|
  config.build_settings['PRODUCT_NAME'] = 'DynamicIslandUITests'
  config.build_settings['PRODUCT_MODULE_NAME'] = 'DynamicIslandUITests'
end

project.save
puts "Successfully updated build settings."

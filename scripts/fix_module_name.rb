require 'xcodeproj'

project_path = './Kannu.xcodeproj'
project = Xcodeproj::Project.open(project_path)

ui_test_target = project.targets.find { |t| t.name == 'KannuUITests' }

ui_test_target.build_configurations.each do |config|
  config.build_settings['PRODUCT_NAME'] = 'KannuUITests'
  config.build_settings['PRODUCT_MODULE_NAME'] = 'KannuUITests'
end

project.save
puts "Successfully updated build settings."

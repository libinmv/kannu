require 'xcodeproj'

project_path = './DynamicIsland.xcodeproj'
project = Xcodeproj::Project.open(project_path)

ui_test_target = project.targets.find { |t| t.name == 'DynamicIslandUITests' }

ui_test_target.build_configurations.each do |config|
  config.build_settings['ENABLE_TESTING_SEARCH_PATHS'] = 'YES'
end

project.save
puts "Successfully updated testing search paths."

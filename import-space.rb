require 'json'
require 'yaml'

# determine this file's current directory
pwd = File.dirname(File.expand_path(__FILE__))
# directory where the libraries are installed (request-ce-sdk and kinetic-utils)
libdir = "#{pwd}/../"
# require the Kinetic Request CE SDK
require "#{libdir}/request-ce-sdk-rb/request-ce-sdk"
# require Kinetic Utilities
require "#{libdir}/kinetic-utils-rb/kinetic-utils"

# Log file to send +puts+ statements to
LOGFILE = "#{pwd}/logs/#{Time.now.strftime('%Y%m%dT%H%M%S%L')}.log"
#
# Monkey patch IO.puts to create a log file for all puts statements
#
def puts str
  # send the input to standard output, just as normal
  $stdout << "#{str}\n"
  # if the LOGFILE is defined and not null, send to file with a timestamp
  if defined? LOGFILE && !LOGFILE.nil?
    open(LOGFILE, 'a') do |f|
      timestamp = Time.now.strftime('%Y-%m-%dT%H:%M:%S.%L')
      f.puts "#{timestamp}  #{str}"
    end
  end
end

# Load the configuration file
env = YAML.load_file("#{pwd}/config.yaml")

# Get space slug from Arguements
space_slug = ARGV[0]
space_name = ARGV[0]

# Build System Connection
ceSystem = Kinetic::RequestCeApi::SDK.new({
    app_server_url: env["server"],
    login: env["adminUser"],
    password: env["adminPassword"],
    options: { "log_level" => env["log_level"] }
  }
)

# Create Space
ceSystem.create_space(space_name, space_slug)

# Generate Temporary U/PW for Space Admin
tempUser = Kinetic::Utils.random_password(5)
tempPw = Kinetic::Utils.random_password(12)

# Create Temporary User in Space
ceSystem.create_user({
    "space_slug" => space_slug,
    "username" => tempUser,
    "password" => tempPw,
    "displayName" => "TEMP",
    "email" => "exporting@kineticdata.com",
    "enabled" => true,
    "spaceAdmin" => true
})

# Create Demo Integration User in Space
ceSystem.create_user({
    "space_slug" => space_slug,
    "username" => env["integrationUser"],
    "password" => env["integrationPassword"],
    "displayName" => "Integration User",
    "email" => "demo.taskman@kineticdata.com",
    "enabled" => true,
    "spaceAdmin" => true
})

# Build Space Connection with Temp User
ceSdk = Kinetic::RequestCeApi::SDK.new({
    app_server_url: env["server"],
    space_slug: space_slug,
    login: tempUser,
    password: tempPw,
    options: { "log_level" => env["log_level"] }
  }
)

# Locate Space Import Directory
spacesDir = "#{pwd}/template"

# Create Space Attribute Definitions
spaceAttributeDefinitions = JSON.parse(File.read("#{spacesDir}/spaceAttributeDefinitions.json"))
spaceAttributeDefinitions.each do |obj|
  ceSdk.create_space_attribute_definition(
    obj["name"],
    obj["description"],
    obj["allowsMultiple"]
  )
end

# Create User Attribute Definitions
userAttributeDefinitions = JSON.parse(File.read("#{spacesDir}/userAttributeDefinitions.json"))
userAttributeDefinitions.each do |obj|
  ceSdk.create_user_attribute_definition(
    obj["name"],
    obj["description"],
    obj["allowsMultiple"]
  )
end

# Create User Attribute Definitions
userProfileAttributeDefinitions = JSON.parse(File.read("#{spacesDir}/userProfileAttributeDefinitions.json"))
userProfileAttributeDefinitions.each do |obj|
  ceSdk.create_user_profile_attribute_definition(
    obj["name"],
    obj["description"],
    obj["allowsMultiple"]
  )
end

# Create Space Webhooks
webhooks = JSON.parse(File.read("#{spacesDir}/webhooks.json"))
webhooks.each do |obj|
  ceSdk.create_space_webhook(obj)
end

# Update the Space with all attributes and properties
spaceJson = JSON.parse(File.read("#{spacesDir}/space.json"))
# Remove the space slug and space name (slug/name from the template)
spaceJson.delete("slug")
spaceJson.delete("name")
ceSdk.update_space(spaceJson)

# Import Bridges
bridgesDir = "#{spacesDir}/bridges/bridges"
Dir["#{bridgesDir}/*"].each do |dirname|
    bridge = JSON.parse(File.read("#{dirname}"))
    bridge.delete("key")
    ceSdk.create_bridge(bridge)
end

# Import Bridge Models
bridgesModelsDir = "#{spacesDir}/bridges/bridgeModels"
Dir["#{bridgesModelsDir}/*"].each do |dirname|
    ceSdk.create_bridge_model(JSON.parse(File.read("#{dirname}")))
end

# Teams #
Dir["#{spacesDir}/teams/*"].each do |team_file|
    team = JSON.parse(File.read("#{team_file}"))
    team.delete("slug")
    ceSdk.create_team(team)
end

# Delete OOTB Catalog Kapp
ceSdk.delete_kapp("catalog");

# Import Kapps
Dir["#{spacesDir}/kapp-*"].each do |dirname|

  # Import Kapp
  kappJson = JSON.parse(File.read("#{dirname}/kapp.json"))
  kappSlug = kappJson['slug']
  ceSdk.create_kapp(kappJson['name'], kappJson['slug'], kappJson)

  # Import Category Attribute Definitions
  objJson = JSON.parse(File.read("#{dirname}/categoryAttributeDefinitions.json"))
  objJson.each do |obj|
    ceSdk.create_category_attribute_definition(kappSlug, obj['name'], obj['description'], obj['allowsMultiple'])
  end

  # Import Form Attribute Definitions
  objJson = JSON.parse(File.read("#{dirname}/formAttributeDefinitions.json"))
  objJson.each do |obj|
    ceSdk.create_form_attribute_definition(kappSlug, obj['name'], obj['description'], obj['allowsMultiple'])
  end

  # Import Kapp Attribute Definitions
  objJson = JSON.parse(File.read("#{dirname}/kappAttributeDefinitions.json"))
  objJson.each do |obj|
    ceSdk.create_kapp_attribute_definition(kappSlug, obj['name'], obj['description'], obj['allowsMultiple'])
  end

  # Import Form Types
  objJson = JSON.parse(File.read("#{dirname}/formTypes.json"))
  # first delete all existing form type
  ceSdk.delete_form_types_on_kapp(kappSlug)
  # now import the form types defined in the space
  objJson.each do |obj|
    ceSdk.create_form_type_on_kapp(kappSlug, obj)
  end

  # Import Categories
  objJson = JSON.parse(File.read("#{dirname}/categories.json"))
  objJson.each do |obj|
    ceSdk.create_category_on_kapp(kappSlug, obj)
  end

  # Import Forms
  formsDir = "#{dirname}/forms"
  Dir["#{formsDir}/*"].each do |form|
    ceSdk.create_form(kappSlug, JSON.parse(File.read("#{form}")))
  end

    # Import Submissions
    Dir["#{dirname}/data/*"].each do |form|
      # Parse form slug from directory path
      form_slug = File.basename(form, '.json')
      puts "Importing submissions for: #{form_slug}"
      # Each submission is a single line on the export file
      File.readlines(form).each do |line|
        submission = JSON.parse(line)
        ceSdk.create_submission(kappSlug, form_slug, {
          "origin" => submission['origin'],
          "parent" => submission['parent'],
          "values" => submission['values']
        })
      end
    end

  # Import Kapp Webhooks
  objJson = JSON.parse(File.read("#{dirname}/webhooks.json"))
  objJson.each do |obj|
    ceSdk.create_webhook_on_kapp(kappSlug, obj)
  end

end

# Remove Temporary User
ceSystem.delete_user({
    "space_slug" => space_slug,
    "username" => tempUser,
})
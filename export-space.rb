require 'json'
require 'yaml'

# determine this file's current directory
pwd = File.dirname(File.expand_path(__FILE__))
# Build an Array of All attributes to remove from JSON export
attrsToDelete = ["createdAt","createdBy","updatedAt","updatedBy","closedAt","closedBy","id"]
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

# Build System Connection
ceSystem = Kinetic::RequestCeApi::SDK.new({
    app_server_url: env["server"],
    login: env["adminUser"],
    password: env["adminPassword"],
    options: { "log_level" => env["log_level"] }
  }
)

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

# Build Space Connection with Temp User
ceSpace = Kinetic::RequestCeApi::SDK.new({
    app_server_url: env["server"],
    space_slug: space_slug,
    login: tempUser,
    password: tempPw,
    options: { "log_level" => env["log_level"] }
  }
)

# Export Space - Returns the entire Space definition including all kapps
space = JSON.parse(ceSpace.retrieve_entire_space())['space']
exportedSpaceName = space['name']
exportedSpaceSlug = space['slug']

## SPACE ##
puts "Building Space Directory Structure"
spaceDir = "#{pwd}/template"
Dir.mkdir(spaceDir, 0700) unless Dir.exist?(spaceDir)
Dir.chdir(spaceDir)

# Create space.json (All Arrays except attributes and security policies should be excluded)
spaceJson = JSON.pretty_generate(space.reject {|k,v| v.is_a?(Array) && k != "attributes" && k != "securityPolicies" })
File.open("#{spaceDir}/space.json", 'w') { |file| file.write(spaceJson) }

# Loop over the rest of the space objects and create files for them
spaceObjects = space.reject {|k,v| !v.is_a?(Array) || k == "attributes" || k == "securityPolicies" || k == "kapps" || k.start_with?("bridge")}
spaceObjects.each do | k, v |
  File.open("#{spaceDir}/#{k}.json", 'w') { |file| file.write(JSON.pretty_generate(v)) }
end

## BRIDGES ##
puts "Building Bridge Directory Structure"
Dir.mkdir("#{spaceDir}/bridges", 0700) unless Dir.exist?("#{spaceDir}/bridges")
Dir.chdir("#{spaceDir}/bridges")
bridgeObjects = space.select {|k,v| k.start_with?("bridge")}

# Loop over bridges and bridge mappings and create structures accordingly
bridgeObjects.each do | k, v |
  Dir.mkdir("#{spaceDir}/bridges/#{k}", 0700) unless Dir.exist?("#{spaceDir}/bridges/#{k}")
  Dir.chdir("#{spaceDir}/bridges/#{k}")
  v.each do |obj|
    File.open("#{spaceDir}/bridges/#{k}/#{obj['name']}.json", 'w') { |file| file.write(JSON.pretty_generate(obj)) }
  end
end

## KAPPS ##
puts "Building Kapp Directory Structure"
# Loop over Each Kapp
space["kapps"].each do |kapp|
  # Create a Kapp Directory
  kappDir = "#{spaceDir}/kapp-#{kapp['slug']}"
  Dir.mkdir(kappDir, 0700) unless Dir.exist?(kappDir)
  Dir.chdir(kappDir)

  # Create kapp.json (All Arrays except attributes and security policies should be excluded)
  kappJson = JSON.pretty_generate(kapp.reject {|k,v| v.is_a?(Array) && k != "attributes" && k != "securityPolicies" })
  File.open("#{kappDir}/kapp.json", 'w') { |file| file.write(kappJson) }
  
  # Loop over the rest of the kapp objects and create files for them
  kappObjects = kapp.reject {|k,v| !v.is_a?(Array) || k == "attributes" || k == "securityPolicies"}
  kappObjects.each do | k, v |
    if k == "forms"
      Dir.mkdir("#{kappDir}/forms", 0700) unless Dir.exist?("#{kappDir}/forms")
      v.each do |form|
        File.open("#{kappDir}/forms/#{form['slug']}.json", 'w') { |file| file.write(JSON.pretty_generate(form)) }
      end
    else
      File.open("#{kappDir}/#{k}.json", 'w') { |file| file.write(JSON.pretty_generate(v)) }
    end
  end
end

# ## Teams ##
# puts "Building Teams Directory Structure"
# Dir.mkdir("#{spaceDir}/teams", 0700) unless Dir.exist?("#{spaceDir}/teams")
# Dir.chdir("#{spaceDir}/teams")
# teams_array = JSON.parse(ceSpace.find_teams({"include" => "attributes"}))["teams"]
# teams_array.each do |obj|
#   File.open("#{spaceDir}/teams/#{obj['name']}.json", 'w') { |file| file.write(JSON.pretty_generate(obj)) }
# end


## SUBMISSIONS ##
puts "Exporting Submissions"

# Build mapping of kapp/forms to export
formsToExport = {"admin" => [
                             'broadcast-alerts', 
                             'group-membership', 
                             'group', 
                             'telephone'
                            ]
                }
# Loop over each Kapp in the forms to export map
formsToExport.keys.each do |kappSlug|
  # Loop over each form slug in the formsToExport map for the given kapp
  formsToExport[kappSlug].each do |formSlug|
    # Build a data directory for the kapp
    dataDir = "#{spaceDir}/kapp-#{kappSlug}/data"
    FileUtils.mkdir_p(dataDir, :mode => 0700)
    # Build params to pass to the retrieve_form_submissions method
    params = {"include" => "values", "limit" => 1000}
    # Open the submissions file in write mode
    file = File.open("#{dataDir}/#{formSlug}.json", 'w');
    # Ensure the file is empty
    file.truncate(0)
    response = nil
    count = 0
    begin
      # Get submissions
      response = ceSpace.retrieve_form_submissions(kappSlug, formSlug, params)
      count += response["submissions"].size
      # Write each submission on its own line
      response["submissions"].each do |submission|
        # Append each submission (removing the submission unwanted attributes)
        file.puts(JSON.generate(submission.delete_if { |key, value| attrsToDelete.member?(key)}))
      end
      params['pageToken'] = response['nextPageToken']
      # Get next page of submissions if there are more
    end while !response.nil? && !response['nextPageToken'].nil?
    # Close the submissions file
    file.close()
  end
end


## MANIPULATE DATA FILES TO REMOVE DATES / UPDATED BY DETAILS ##
################################################################

# Build an Array of All JSON files that were exported
configFiles = Dir.glob("#{spaceDir}/**/*.json")
replacements = [ [exportedSpaceName, "Space Template"], [exportedSpaceSlug, "space-template"] ]

puts "Stripping out Created/Updated Dates and Users"

# loop over each file and remove the attributes we want to omit
configFiles.each do |filename|
  # Submission Data is handled in the export 
  unless filename.include?("/data/")
    filename.include?("/data/")
    json = JSON.parse(File.read("#{filename}"))
    json.delete_if { |key, value| attrsToDelete.member?(key)}
    # Replace Space Name and Space Slug References
    updatedData = JSON.pretty_generate(json)
    replacements.each {|replacement| updatedData.gsub!(/\b(#{replacement[0]})\b/, replacement[1])}
    File.open("#{filename}", 'w') { |file| file.write(updatedData) }
  end
end

# Remove Temporary User
ceSystem.delete_user({
    "space_slug" => space_slug,
    "username" => tempUser,
})
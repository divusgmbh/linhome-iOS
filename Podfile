
platform :ios, '15.0'
source "https://gitlab.linphone.org/BC/public/podspec.git"
source "https://github.com/CocoaPods/Specs.git"

# App
def app_pods
	pod 'IQKeyboardManager'
	pod 'PocketSVG'
	pod 'Zip'
	pod 'SVProgressHUD'
	pod 'SwiftSVG'
	pod 'DropDown'
	pod 'SnapKit'
	pod 'Firebase/Crashlytics'
	pod 'MarqueeLabel'
end

target 'Linhome' do
	use_frameworks! :linkage => :static
	app_pods
end

# Extensions
def ext_pods
	pod 'Zip'
	pod 'PocketSVG'
	pod 'Firebase/Crashlytics'
end

target 'LinhomeContentExtension' do
	use_frameworks! :linkage => :static
	ext_pods
end

target 'LinhomeServiceExtension' do
	use_frameworks! :linkage => :static
	ext_pods
end

post_install do |installer|
	installer.pods_project.targets.each do |target|
		if target.name == 'SwiftSVG'
			target.build_configurations.each do |config|
				config.build_settings['SWIFT_INSTALL_OBJC_HEADER'] = 'NO'
			end
		end
		target.build_configurations.each do |config|
      			config.build_settings.delete 'IPHONEOS_DEPLOYMENT_TARGET'
			config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] = '$(inherited) POCKETSVG_DISABLE_FILEWATCH=1'
    		end	
	end
end

/*
 * Copyright (c) 2010-2020 Belledonne Communications SARL.
 *
 * This file is part of linhome
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import UIKit
import linphonesw
import UserNotifications
import Firebase
import AVFoundation
import SVProgressHUD
import FirebaseCore
import PushKit
import CallKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    
	var window: UIWindow?
	
	var coreDelegate : CoreDelegateStub?
	var notificationAction : String?
	var hasBeenConnected : [String?] = []
	
	var appOpenedTime = Date()

	var coreState = MutableLiveData(GlobalState.Off)
	var flexiApiTokenReceived = MutableLiveData(false)

	var historyNotifTapped = false

	var preventEnterinBackground = false
    private var voipRegistry: PKPushRegistry?
    private var callKitProvider: CXProvider?
    // Maps CallKit UUID → SIP call-id so we can link push-reported calls to arriving INVITEs
    private var pendingCallKitIds = [UUID: String]()
    // Calls the user answered via CallKit before the INVITE arrived
    private var callKitAcceptedCallIds = Set<String>()
    // Call Kit closed observation
    private var onCallKitClosed: (() -> Void)?
    private let callObserver = CXCallObserver()
    private let callController = CXCallController()
    private var appCallDelegate: CallDelegateStub?
    private var missedCallPreId: String?
    // Background task
    private var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
    
    // CFMessagePort for other processes to know if the App is active
    // var messagePort: CFMessagePort?
	
	func displayWaitIndicatorIfFromPush() -> Bool {
		var fromPush = false
		if let userDefaults = UserDefaults(suiteName: Config.appGroupName) {
			if let lastPushTime = userDefaults.value(forKey: "lastcallpushtime") as! Date? {
				if let lastLaunchTime = userDefaults.value(forKey: "lastlaunchtime") as! Date? {
					if (lastPushTime > lastLaunchTime) {
						fromPush = true
						if (Date().timeIntervalSince1970 - lastPushTime.timeIntervalSince1970 < 5.0) { // Fresh push most likely waiting for core to start
							DispatchQueue.main.async {
								SVProgressHUD.show()
							}
							DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(10)) {
								SVProgressHUD.dismiss()
							}
						}
					}
				}
			}
			userDefaults.set(Date(), forKey: "lastlaunchtime")
		}
		return fromPush
	}
	
	func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // Must be set before didFinishLaunching returns so notification responses
        // are delivered even when the app was launched from a killed state by a VoIP push.
        UNUserNotificationCenter.current().delegate = self

        if Config.useInAppCallKit {
            setupCallKit()
            setupVoIPPush()
        }

		FirebaseApp.configure()
		
		UserDefaults.standard.set(false, forKey: "_UIConstraintBasedLayoutLogUnsatisfiable")
		
		_ = Customisation.it
		_ = GSMActivityHelper.it
		_ = DeviceStore.it
		
		
		self.window = UIWindow(frame: UIScreen.main.bounds)
		window?.rootViewController = displayWaitIndicatorIfFromPush() ? MainView() : Splash()
		window?.makeKeyAndVisible()
		
		coreDelegate = CoreDelegateStub(
			onGlobalStateChanged: { (core: Core, state: GlobalState, message: String) -> Void in
				self.coreState.value = state
                if(state == GlobalState.On) {
                    HistoryEventStore.it.rotateRecordings(cleanup: true, core: Core.get())
                }
			},
			onCallStateChanged : { (lc: Core, call: Call, cstate: Call.State, message: String) -> Void in
				
				Log.error("onCallStateChanged \(cstate)")
				
				if let callId = call.callLog?.callId {
					Call.requestOwnerShip(callId) // Will release the extension handling
				}
				
				if (cstate == Call.State.Released) {
                    if(Config.useInAppCallKit){
                        if let d = self.appCallDelegate { call.removeDelegate(delegate: d) }
                        self.appCallDelegate = nil
                    }
					SVProgressHUD.dismiss()
					//let openFiles = FileUtil.openFilePaths()
					//Log.debug("Open file descriptors: limit = \(FileUtil.getNofFileLimit()) count=\(openFiles.count) FDs : \n \(openFiles)")
                    if(Config.useInAppCallKit) {
                        self.closeCallKit(call: call)
                    }
				}
                
                if (cstate == Call.State.End) {
                    call.extendedClose(core: Core.get())
                    // Correct missed call if not using callkit
                    if (!Config.useInAppCallKit) {
                        if let callId = call.callLog?.callId {
                            let missed = NSNumber(value: Core.get().missedCount())
                            UserDefaults(suiteName: Config.appGroupName)?.set(missed, forKey: "notification_badge_"+callId)
                        }
                    }
                    if (UIApplication.shared.applicationState == .background) { // A call is terminated in background
                        // Process end of call in background task
                        Task.detached(priority: .background) {
                            await self.processEndOfCallinBkg(call: call)
                        }
                    }else{
                        if(Config.useInAppCallKit) {
                            if let callId = call.callLog?.callId {
                                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) {
                                    self.storeSnapshotForDevice(call: call)
                                    self.notifyMissedCall(callId: callId)
                                }
                            }
                        }
                    }
                }
				
				/*if (cstate == Call.State.Released && UIApplication.shared.applicationState == .background) { // A call is terminated in background
					DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) {
						self.applicationWillResignActive(UIApplication.shared)
					}
				}*/
				
				if (cstate == Call.State.Released && call.callLog?.dir == .Incoming) {
					if (self.appOpenedTime.timeIntervalSince1970 > Double((call.callLog?.startDate ?? 0))) {
						//UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
					}
				}
				
				if (cstate == Call.State.Error && call.callLog?.dir == Call.Dir.Outgoing) {
					DispatchQueue.main.async {
						DialogUtil.error("unable_to_call_device")
					}
				}
				
				if (call.state == Call.State.IncomingReceived && lc.callsNb > 1) {
					try?call.decline(reason: .Busy)
					return
				}
				
				if ([Call.State.IncomingReceived, Call.State.IncomingEarlyMedia].contains(call.state)) {
                    // Set notification title for post-call notification as missed call
                    if let callId = call.callLog?.callId {
                        let incomingName = DeviceStore.getDeviceNameForExtension(address: call.remoteAddress!)
                        UserDefaults(suiteName: Config.appGroupName)?.set(incomingName, forKey: "notification_title_"+callId)
                        // Increase counter for missed call
                        let badgeCount = NSNumber(value: Core.get().missedCount() + 1)
                        UserDefaults(suiteName: Config.appGroupName)?.set(badgeCount, forKey: "notification_badge_"+callId)
                    }
                    if(Config.useInAppCallKit){
                        if let callId = call.callLog?.callId, self.callKitAcceptedCallIds.contains(callId) {
                            Log.info("Accepting call answered via CallKit before INVITE arrived: \(callId)")
                            self.callKitAcceptedCallIds.remove(callId)
                            call.extendedAccept(core: Core.get())
                            return
                        }
                    }
					if let callId = call.callLog?.callId, let userDefaults = UserDefaults(suiteName: Config.appGroupName), userDefaults.bool(forKey: "accepted_calls_via_notif_"+callId) {
						Log.info("Accepting call Id in app (accept button pressed on notif) : \(callId)")
						if (GSMActivityHelper.it.ongoingGSMCall.value == true) {
							NavigationManager.it.navigateTo(childClass: CallIncomingView.self, asRoot:false, argument:Pair(call, [Call.State.IncomingReceived, Call.State.IncomingEarlyMedia]))
							DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) {
								DialogUtil.toast(textKey: "unable_to_accept_call_gsm_call_in_progress")
							}
						} else {
							call.extendedAccept(core : Core.get())
						}
						return
					}
					if let log = call.callLog, let userDefaults = UserDefaults(suiteName: Config.appGroupName), userDefaults.bool(forKey: "declined_calls_via_notif_\(log.callId)") {
						Log.info("Declining call Id in app (accept button pressed on notif) : \(log.callId)")
						try?call.decline(reason: .Declined)
						return
					}
				}
                if (cstate == Call.State.IncomingEarlyMedia && !Config.useInAppCallKit) {
                    Core.get().activateAudioSession(activated: true)
                }
				if (cstate == Call.State.IncomingReceived && !self.hasBeenConnected.contains(call.callLog?.callId ?? nil)) {
                    if(Config.useInAppCallKit){
                        self.appCallDelegate = CallDelegateStub(
                            onNextVideoFrameDecoded: { (call: Call) -> Void in
                                if let event = call.callLog?.getHistoryEvent() {
                                    if (!event.hasVideo) {
                                        event.hasVideo = true
                                        event.persist()
                                    }
                                    if (!event.hasMediaThumbnail()) {
                                        try? call.takeVideoSnapshot(filePath: event.mediaThumbnailFileName)
                                    }
                                }
                            }
                        )
                        call.addDelegate(delegate: self.appCallDelegate!)
                        call.requestNotifyNextVideoFrameDecoded()
                        call.extendedAcceptEarlyMedia(core: Core.get())
                    }
					DispatchQueue.main.async {
						NavigationManager.it.navigateTo(childClass: CallIncomingView.self, asRoot:false, argument:Pair(call, [Call.State.IncomingReceived, Call.State.IncomingEarlyMedia]))
					}
				}
				if (cstate == Call.State.Connected) {
					call.callLog.map{self.hasBeenConnected.append($0.callId)}
					DispatchQueue.main.async {
						NavigationManager.it.navigateTo(childClass: CallInProgressView.self, asRoot:false, argument:Pair(call, [Call.State.Connected, Call.State.StreamsRunning, Call.State.Updating, Call.State.UpdatedByRemote]))
					}
				}
				if (cstate == Call.State.OutgoingInit) {
					DispatchQueue.main.async {
						NavigationManager.it.navigateTo(childClass: CallOutgoingView.self, asRoot:false, argument:Pair(call, [Call.State.OutgoingRinging, Call.State.OutgoingProgress, Call.State.OutgoingInit, Call.State.OutgoingEarlyMedia]))
					}
				}
			},
			onConfiguringStatus: { (core, status, message) in
				if (status == .Successful) {
					core.config?.cleanEntry(section: "video", key: "displaytype")
				}
			}
		)
		
		requestMirophonePermission()
		
		Core.get().addDelegate(delegate: self.coreDelegate!)
        Core.get().friendListSubscriptionEnabled = false
        
		return true
	}

    private func processEndOfCallinBkg(call: Call) async {
        do{
            self.backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Post process call") {
                Log.warn("Terminating processing end of call in background due no time left")
                // End the task if time expires.
                UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
                self.backgroundTaskID = UIBackgroundTaskIdentifier.invalid
            }
            if #available(iOS 16.0, *) {
                try await Task.sleep(for: .milliseconds(500))
            } else {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            self.storeSnapshotForDevice(call: call)
            if(Config.useInAppCallKit) {
                if let callId = call.callLog?.callId {
                    self.notifyMissedCall(callId: callId)
                }
            }
            if #available(iOS 16.0, *) {
                try await Task.sleep(for: .milliseconds(500))
            } else {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            if (UIApplication.shared.applicationState == .background) {
                self.enterBackground()
            }
            // End the task assertion.
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
            self.backgroundTaskID = UIBackgroundTaskIdentifier.invalid
        }catch{
            Log.info("Error in processing end of call in background: \(error.localizedDescription)")
        }
    }
    
    private func storeSnapshotForDevice(call: Call){
        DeviceStore.it.readDevicesFromFriends()
        if let device = DeviceStore.it.findDeviceByAddress(address: call.remoteAddress!) {
            if (CorePreferences.them.showLatestSnapshot || !device.hasThumbNail()) {
                if let event = call.callLog?.getHistoryEvent() {
                    if (event.hasMediaThumbnail()) {
                        FileUtil.copy(event.mediaThumbnailFileName, device.thumbNail, overWrite: true)
                        DeviceStore.it.updatedSnapshotDeviceId.value = device.id
                    }
                }
            }
        }
    }
    
    private func setupCallKit() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.ringtoneSound = "bell.caf"
        config.includesCallsInRecents = true
        callKitProvider = CXProvider(configuration: config)
        callKitProvider?.setDelegate(self, queue: .main)
    }

    private func setupVoIPPush() {
        voipRegistry = PKPushRegistry(queue: .main)
        voipRegistry?.delegate = self
        voipRegistry?.desiredPushTypes = [.voIP]
    }
	
	func registerForPushNotifications() {
		let options: UNAuthorizationOptions = [.alert, .sound, .badge]
		UNUserNotificationCenter.current().requestAuthorization(options: options) {
			(didAllow, error) in
			if !didAllow {
				DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500+Customisation.it.themeConfig.getInt(section: "arbitrary-values", key: "splash_display_duration_ms", defaultValue: 2000))) {
					DialogUtil.info("service_description")
				}
			} else {
				DispatchQueue.main.async {
					// Add the actions here as the user can take the decision to refuse/accept from the caller ID ( no need to wait to receive the call)
					let accept = UNNotificationAction(identifier: "accept", title: Texts.get("call_button_accept"), options: [.foreground, .authenticationRequired])
					let decline = UNNotificationAction(identifier: "decline", title: Texts.get("call_button_decline"), options: [.destructive])
					let earlyMediaCategoryIdentifier = UNNotificationCategory(identifier: Config.earlymediaContentExtensionCagetoryIdentifier,
																			  actions: [accept, decline],
																			  intentIdentifiers: [],
																			  options: .customDismissAction)
					UNUserNotificationCenter.current().setNotificationCategories([earlyMediaCategoryIdentifier])
					
					UIApplication.shared.registerForRemoteNotifications()
					UNUserNotificationCenter.current().delegate = self
				}
			}
		}
	}
	
	func requestMirophonePermission() {
		AVAudioSession.sharedInstance().requestRecordPermission { granted in
			if !granted {
				DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500+Customisation.it.themeConfig.getInt(section: "arbitrary-values", key: "splash_display_duration_ms", defaultValue: 2000))) {
					DialogUtil.info("record_audio_permission_denied_dont_ask_again")
				}
			}
		}
	}
	
	func applicationWillTerminate(_ application: UIApplication) {
		Core.get().stop()
	}
	
	func application(_ application: UIApplication,
					 didFailToRegisterForRemoteNotificationsWithError
					 error: Error) {
		Log.error("Failed registering to remote notifications \(error)")
		Core.get().didRegisterForRemotePush(deviceToken: nil)
	}
	
	func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let apnsToken = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        DispatchQueue.main.async() {
            if(!Config.useInAppCallKit){
                Core.get().configurePushNotifications(deviceToken)
            }
		}
	}
	
	func applicationDidBecomeActive(_ application: UIApplication) {
		DeviceStore.it.enteringBackground = false
		displayWaitIndicatorIfFromPush()
		HistoryEventStore.refresh()
		if let userDefaults = UserDefaults(suiteName: Config.appGroupName) {
			userDefaults.set(true, forKey: "appactive")
            userDefaults.synchronize()
		}
		try?Config.get().sync()
        
        registerForPushNotifications()
        
        DispatchQueue.main.async {
            if(Config.useInAppCallKit){
                if Core.get().globalState != .On {
                    UserDefaults(suiteName: Config.appGroupName)?.setValue(0, forKey: "ACTIVE_SHARED_CORE")
                    try?Core.get().start()
                }
                Core.get().enterForeground()
            }else{
                UserDefaults(suiteName: Config.appGroupName)?.setValue(0, forKey: "ACTIVE_SHARED_CORE")
                try?Core.get().start()
                Core.get().enterForeground()
            }
			NavigationManager.it.mainView?.tabbarViewModel.updateUnreadCount()
            // Re-check for incoming call that arrived while in background
            if (Config.useInAppCallKit) {
               if let connectedCall = Core.get().calls.first(where: {
                [Call.State.Connected, Call.State.StreamsRunning, Call.State.Updating, Call.State.UpdatedByRemote].contains($0.state)
               }),
                  !NavigationManager.it.viewStack.contains(where: { $0 is CallInProgressView }) {
                   NavigationManager.it.navigateTo(
                    childClass: CallInProgressView.self,
                    asRoot: false,
                    argument: Pair(connectedCall, [Call.State.Connected, Call.State.StreamsRunning, Call.State.Updating, Call.State.UpdatedByRemote])
                   )
               }
            }else{
                if let incomingCall = Core.get().calls.first(where: {
                    [Call.State.IncomingReceived, Call.State.IncomingEarlyMedia].contains($0.state)
                    }), !NavigationManager.it.incomingViewDisplaying {
                        NavigationManager.it.navigateTo(
                                childClass: CallIncomingView.self,
                                asRoot: false,
                                argument: Pair(incomingCall, [Call.State.IncomingReceived, Call.State.IncomingEarlyMedia])
                        )
                }
            }
            // For the case the App is awoken in background over VoIP push and opened with empty stack
            // ViewWillAppear of the main view won't trigger in that moment
            if NavigationManager.it.viewStack.isEmpty {
                NavigationManager.it.mainView?.viewWillAppear(false)
            }
		}
		appOpenedTime = Date()
        /*messagePort = CFMessagePortCreateLocal(nil, "group.eu.divus.videophonemobile.isActive" as CFString, { _, _, _, _ in
                    Unmanaged.passRetained(CFDataCreate(nil, [], 0))
                    }, nil, nil)
        CFMessagePortSetDispatchQueue(messagePort, DispatchQueue.main)
        */
	}
	
	func applicationWillResignActive(_ application: UIApplication) {
        /*CFMessagePortInvalidate(messagePort)
        messagePort = nil
        */
		if (preventEnterinBackground) {
			return
		}
        if (Config.useInAppCallKit && Core.get().callsNb > 0) {
            return
        }
		if let userDefaults = UserDefaults(suiteName: Config.appGroupName) {
			userDefaults.set(false, forKey: "appactive")
            userDefaults.synchronize()
		}
		try?Config.get().sync()
		enterBackground()
	}
	
	// UNUserNotificationCenterDelegate functions
	
	func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
		Log.info("willPresentnotification : \(notification.request.content.userInfo)")
		if let aps = notification.request.content.userInfo["aps"] as? [String: Any], let alert = aps["alert"] as? [String: Any], let locKey = alert["loc-key"] as? String, locKey == "IC_MSG" {
			if  let callId = notification.request.content.userInfo["call-id"] as! String? {
				Call.requestOwnerShip(callId)
			}
			if (!NavigationManager.it.incomingViewDisplaying) {
				//SVProgressHUD.show()
			}
		}
		
		
		if #available(iOS 14.0, *) {
			let appActive = UserDefaults(suiteName: Config.appGroupName)?.bool(forKey: "appactive") == true
			let isMissedInForeGround = notification.request.content.title == Texts.get("notif_missed_call_title") && appActive
			completionHandler(isMissedInForeGround ? [.banner] : [.sound,.list])
		} else {
			completionHandler(.sound)
		}
	}
	
	
	func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
		Log.info("didReceiveRemoteNotification - remote notification \(userInfo)")
		
		if let payload = userInfo["customPayload"] as? [String: Any], let token = payload["token"] as? String {
			Config.flexiApiToken = token
			flexiApiTokenReceived.value = true
		}
		
		if let aps = userInfo["aps"] as? [String: Any], let alert = aps["alert"] as? [String: Any], let locKey = alert["loc-key"] as? String, locKey == "Missing call" {
			historyNotifTapped = true
		}
		
		if (Core.get().globalState != .On) {
			UserDefaults(suiteName: Config.appGroupName)?.setValue(0, forKey: "ACTIVE_SHARED_CORE")
			try?Core.get().start()
			Core.get().enterForeground()
		}
		Core.get().accountList.forEach {
			$0.refreshRegister()
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(5)) {
			if (UserDefaults(suiteName: Config.appGroupName)?.bool(forKey: "appactive") != true) {
				self.enterBackground()
			}
			completionHandler(.newData)
		}
	}
	
	func enterBackground() {
		if (preventEnterinBackground) {
			return
		}
		DeviceStore.it.enteringBackground = true
		Core.get().enterBackground()
        if (Core.get().callsNb == 0) {
			Core.get().stop()
		}
	}
	
	// Actions on the notification here. If the user press too quick on the actions it comes directly here.
	
	func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
		Log.info("User pressed action in notification. (app) : \(response)")
		
        if response.notification.request.content.userInfo["actionTag"] as? String == "missed_calls" {
            historyNotifTapped = true
            if ( UIApplication.shared.applicationState == .active && coreState.value == .On) {
                coreState.notifyValue()
            }
            completionHandler()
            return
        }
        
		if (response.notification.request.content.title == Texts.get("notif_missed_call_title")) {
			historyNotifTapped = true
			if ( UIApplication.shared.applicationState == .active && coreState.value == .On) {
				coreState.notifyValue()
			}
			return
		}
		
		guard  let callId = response.notification.request.content.userInfo["call-id"] as! String?, let userDefaults = UserDefaults(suiteName: Config.appGroupName) else {
			Log.warn("No call ID found in notification or failed getting user detaults : \(response.actionIdentifier)")
			return
		}
		
		if response.actionIdentifier == "accept" {
			SVProgressHUD.show()
			DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3)) {
				SVProgressHUD.dismiss()
			}
			Log.info("Accept call button pressed for call Id : \(callId)")
			userDefaults.set(true, forKey: "accepted_calls_via_notif_"+callId)
		}
		if response.actionIdentifier == "decline"{
			Log.info("Decline call button pressed for call Id : \(callId)")
			userDefaults.set(true, forKey: "declined_calls_via_notif_"+callId)
		}
		completionHandler()
	}
    
    func closeCallKit(call: Call){
        if(Config.useInAppCallKit){
            if let callId = call.callLog?.callId,
               let uuid = self.pendingCallKitIds.first(where: { $0.value == callId })?.key,
                let provider = self.callKitProvider {
                provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
                self.pendingCallKitIds.removeValue(forKey: uuid)
            }
        }
    }
    
    func waitForCallKitClosed(completion: @escaping () -> Void) {
        if callObserver.calls.allSatisfy({ $0.hasEnded }) {
            completion() // already closed
        } else {
            onCallKitClosed = completion
        }
    }

    func answerCallViaCallKit(callId: String) {
        guard let uuid = pendingCallKitIds.first(where: { $0.value == callId })?.key else {
            Core.get().calls.first(where: { $0.callLog?.callId == callId })?.extendedAccept(core: Core.get())
            return
        }
        callController.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { error in
            if let error = error { Log.error("[CallKit] in-app CXAnswerCallAction failed: \(error)") }
        }
    }
    
    func notifyMissedCall(callId: String) {
        let ud = UserDefaults(suiteName: Config.appGroupName)!
        /*if let preId = missedCallPreId, !preId.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [preId])
        }*/
        //let unread = ud.integer(forKey: "notification_badge_" + callId)
        let unread = Core.get().missedCount()
        if ( unread < 1 ) {
            return
        }
            
        let title = Texts.get("notif_missed_call_title")
        let body: String
        if unread > 1 {
            body = Texts.get("notif_missed_calls", oneArg: "\(unread)")
        } else {
            let name = ud.string(forKey: "notification_title_" + callId)
            body = Texts.get("notif_missed_call", oneArg: name ?? "")
        }
        missedCallPreId = showLocalNotification(
            title: title,
            body: body,
            badge: NSNumber(value: unread),
            actionTag: "missed_calls"
        )
        // Cleanup all notifications
        let semaphore = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let idsToRemove = notifications.map { $0.request.identifier }.filter { $0 != self.missedCallPreId }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: idsToRemove)
            semaphore.signal()
        }
        semaphore.wait()
    }

    func showLocalNotification(title: String, body: String, sound: UNNotificationSound? = .default, badge: NSNumber? = nil, actionTag: String? = nil, identifier: String = UUID().uuidString) -> String {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["actionTag": actionTag]
        if let sound = sound { content.sound = sound }
        if let badge = badge { content.badge = badge }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { Log.error("[Notification] Failed to show banner: \(error)") }
        }
        return identifier
    }
}

extension AppDelegate: CXCallObserverDelegate {
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if call.hasEnded {
            onCallKitClosed?()
            onCallKitClosed = nil
        }
    }
}

extension AppDelegate: PKPushRegistryDelegate {

    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        let token = credentials.token.map { String(format: "%02.2hhx", $0) }.joined()
        Log.info("VoIP push token received in app delegate: \(token)")
        Core.get().configureVoIPPushNotifications(credentials)
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        let userInfo = payload.dictionaryPayload
        Log.info("VoIP push received in app delegate: \(userInfo)")

        let aps = userInfo["aps"] as? [String: Any]
        let callId = aps?["call-id"] as? String ?? UUID().uuidString
        var displayName = userInfo["display-name"] as? String ?? "Incoming Call"

        // Deduplicate: SDK's internal PKPushRegistry (pushNotificationEnabled=true) may also
        // receive this same push. Only report to CallKit once per call-id.
        let alreadyReported = pendingCallKitIds.values.contains(callId)
        Log.info("VoIP push callId=\(callId) alreadyReported=\(alreadyReported)")

        // iOS 13+ kills the app if reportNewIncomingCall is not called synchronously here.
        // Always call completion(), even if we skip reporting (already handled).
        guard !alreadyReported, let provider = callKitProvider else {
            if alreadyReported {
                Log.info("CallKit already reported for callId=\(callId), skipping duplicate")
            } else {
                Log.error("callKitProvider is nil — cannot report incoming call to CallKit")
            }
            completion()
            return
        }

        let uuid = UUID()
        pendingCallKitIds[uuid] = callId

        var update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: displayName)
        update.localizedCallerName = displayName
        update.hasVideo = true
        update.supportsHolding = false
        update.supportsDTMF = true

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error = error {
                Log.error("reportNewIncomingCall failed: \(error)")
                self.pendingCallKitIds.removeValue(forKey: uuid)
            }
            completion()
        }

        // Wake the SIP core so the INVITE can arrive and be matched to this CallKit call
        if Core.get().globalState != .On {
            UserDefaults(suiteName: Config.appGroupName)?.setValue(0, forKey: "ACTIVE_SHARED_CORE")
            try? Core.get().start()
            DeviceStore.it.readDevicesFromFriends()
        }
        Core.get().accountList.forEach { $0.refreshRegister() }
        
        // Try to show device name if defined
        let fromUri = userInfo["from-uri"] as? String ?? ""
        if let device = DeviceStore.it.findDeviceByAddress(address:fromUri) {
            displayName = device.name
            update.localizedCallerName = displayName
            provider.reportCall(with: uuid, updated: update)
        }
    }
}

extension AppDelegate: CXProviderDelegate {

    func providerDidReset(_ provider: CXProvider) {
        pendingCallKitIds.removeAll()
        callKitAcceptedCallIds.removeAll()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Defer accept to didActivate so audio session is ready before streams start
        if let callId = pendingCallKitIds[action.callUUID] {
            callKitAcceptedCallIds.insert(callId)
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let callId = pendingCallKitIds[action.callUUID] {
            callKitAcceptedCallIds.remove(callId)
            if let call = Core.get().calls.first(where: { $0.callLog?.callId == callId }) {
                try? call.decline(reason: .Declined)
            }
            pendingCallKitIds.removeValue(forKey: action.callUUID)
        } else if let call = Core.get().currentCall {
            try? call.terminate()
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Core.get().enterForeground()
        Core.get().activateAudioSession(activated: true)
        // Accept calls deferred from CXAnswerCallAction — audio session is now ready
        let pending = callKitAcceptedCallIds
        pending.forEach { callId in
            if let call = Core.get().calls.first(where: { $0.callLog?.callId == callId }) {
                callKitAcceptedCallIds.remove(callId)
                call.extendedAccept(core: Core.get())
            }
            // If INVITE not yet arrived, onCallStateChanged will accept it when IncomingReceived fires
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Core.get().activateAudioSession(activated: false)
    }
}

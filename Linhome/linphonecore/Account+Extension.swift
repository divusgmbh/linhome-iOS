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


import Foundation
import linphonesw

extension Account {
	
    public func configurePushNotificationParameters() {
		params?.clone().map {newParams in
            if(Config.useInAppCallKit){
                newParams.addCustomParam(key: "pn-msg-str", value: "VOIP")
                newParams.addCustomParam(key: "pn-call-str", value: "VOIP")
                newParams.pushNotificationConfig?.provider = Config.pushProvider
                newParams.pushNotificationConfig?.remotePushInterval = "\(Config.pushNotificationsInterval)"
                newParams.pushNotificationAllowed = true
                newParams.remotePushNotificationAllowed = false
                newParams.pushNotificationConfig?.teamId = Config.teamID
                newParams.pushNotificationConfig?.bundleIdentifier = Bundle.main.bundleIdentifier
                newParams.pushNotificationConfig?.param = "\(Config.teamID).\(Bundle.main.bundleIdentifier!).voip"
                newParams.pushNotificationConfig?.voipToken = Core.voipToken
                if let voipToken = Core.voipToken {
                    newParams.contactUriParameters =
                    "pn-provider=\(Config.pushProvider);" +
                    "pn-prid=\(voipToken);" +
                    "pn-param=\(Config.teamID).\(Bundle.main.bundleIdentifier!).voip;" +
                    "pn-silent=1;pn-timeout=0"
                }
            }else{
                newParams.pushNotificationConfig?.provider = Config.pushProvider
                newParams.pushNotificationConfig?.remotePushInterval = "\(Config.pushNotificationsInterval)"
                newParams.pushNotificationAllowed = true
                newParams.remotePushNotificationAllowed = true // Enable Remote notifications
                newParams.pushNotificationConfig?.teamId = Config.teamID
                newParams.pushNotificationConfig?.bundleIdentifier = Bundle.main.bundleIdentifier
                newParams.pushNotificationConfig?.param = "\(Config.teamID).\(Bundle.main.bundleIdentifier!).remote"
                newParams.pushNotificationConfig?.voipToken = nil // Forces removal of voip notification service in SDK.
            }
			params = newParams
		}
		refreshRegister()
	}
}

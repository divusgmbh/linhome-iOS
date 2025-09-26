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
import linphone


class CreateLinhomeAccountViewModel : CreatorAssistantViewModel {
	
	var username: Pair<MutableLiveData<String>, MutableLiveData<Bool>> = Pair(MutableLiveData<String>(), MutableLiveData<Bool>(false))
	var email: Pair<MutableLiveData<String>, MutableLiveData<Bool>> = Pair(MutableLiveData<String>(), MutableLiveData<Bool>(false))
	var pass1: Pair<MutableLiveData<String>, MutableLiveData<Bool>> = Pair(MutableLiveData<String>(), MutableLiveData<Bool>(false))
	var pass2: Pair<MutableLiveData<String>, MutableLiveData<Bool>> = Pair(MutableLiveData<String>(), MutableLiveData<Bool>(false))
	var creationResult = MutableLiveData<AccountCreator.Status>()
	
	// New api for account creation
	var accountManagerServices: AccountManagerServices? = try?Core.get().createAccountManagerServices()
	var accountManagerServicesRequestListener: AccountManagerServicesRequestDelegateStub? = nil

	
	init() {
		super.init(defaultValuePath: CorePreferences.them.linhomeAccountDefaultValuesPath)
		
		accountManagerServicesRequestListener = AccountManagerServicesRequestDelegateStub(
			onRequestSuccessful: { (request: AccountManagerServicesRequest, data: String) ->Void in
				if request.type == .CreateAccountUsingToken {
					DispatchQueue.main.async {
						self.creatorDelegate?.onCreateAccount(creator: self.accountCreator, status: .AccountCreated, response: "")
					}
				}
			},
			onRequestError: { (request: AccountManagerServicesRequest, statusCode: Int, errorMessage: String, parameterErrors: Dictionary?) -> Void in
				self.creationResult.value = .UnexpectedError
			}
		)
		
		creatorDelegate = AccountCreatorDelegateStub(
			onCreateAccount:  { (creator:AccountCreator, status:AccountCreator.Status, response:String) -> Void in
			if (status == AccountCreator.Status.AccountCreated) {
				Log.info("[Assistant] [Account Creation] Account created")
				Config.flexiApiToken = nil
				self.linhomeAccountCreateProxyConfig( checkRegistration: false,registrationOk: nil)
				self.creationResult.value = status
			} else if (status == AccountCreator.Status.MissingArguments) {
				Log.info("[Assistant] [Account Creation] Creation request not authorized, requesting a new token.")
				Config.flexiApiToken = nil
				self.requestFlexiApiToken()
			} else {
				self.creationResult.value = status
				Log.error("[Assistant] [Account Creation] fail creating an account \(status)")
			}
		},
			onIsAccountExist: { (creator:AccountCreator, status:AccountCreator.Status, response:String) -> Void in
			if (status == AccountCreator.Status.AccountExist) {
				Log.info("[Assistant] [Account Creation] Account exists")
				self.creationResult.value = status
			} else if (status == AccountCreator.Status.AccountNotExist) {
				DispatchQueue.main.async {
					let request = try?self.accountManagerServices?.createNewAccountUsingTokenRequest(
						username: self.username.first.value!,
						password: self.pass1.first.value!,
						algorithm: CorePreferences.them.passwordAlgo,
						token: Config.flexiApiToken!
					)
					request?.addDelegate(delegate: self.accountManagerServicesRequestListener!)
					request?.submit()
				}
			} else {
				self.creationResult.value = status
				Log.error("[Assistant] [Account Creation] fail verifying if account exists\(status)")
			}
		},
			onSendToken: { (creator:AccountCreator, status:AccountCreator.Status, response:String) -> Void in
				Log.info("[Assistant] [Account Creation] get push token \(status) \(response)")
				if (status == AccountCreator.Status.RequestTooManyRequests) {
					self.creationResult.value = status
				}
			}
		)
	}
	
	func valid() -> Bool {
		return username.second.value! && email.second.value! && pass1.second.value! && pass2.second.value!
	}
	
	override func onStart() {
		super.onStart()
		creatorDelegate.map{accountCreator.addDelegate(delegate:$0)}
	}
	
	override func onEnd() {
		creatorDelegate.map{accountCreator.removeDelegate(delegate:$0)}
		super.onEnd()
	}
	
	func create() {
		let token = Config.flexiApiToken
		if (token != nil) {
			accountCreator.token = token
			Log.info("[Assistant] [Account Creation] We already have an auth token from FlexiAPI \(String(describing: token)), continue")
			onFlexiApiTokenReceived()
		} else {
			Log.info("[Assistant] [Account Creation] Requesting an auth token from FlexiAPI")
			requestFlexiApiToken()
		}
	}
	
	override func onFlexiApiTokenReceived() {
		Log.info("[Assistant] [Account Creation] Using FlexiAPI auth token \(accountCreator.token)]")
		let status = accountCreator.isAccountExist()
		Log.info("[Assistant] [Account Creation] Account exists returned \(status)")
		if (status != AccountCreator.Status.RequestOk) {
			self.creationResult.value = status
		}
	}
	
	override func onFlexiApiTokenRequestError() {
		Log.error("[Assistant] [Account Creation] Failed to get an auth token from FlexiAPI")
		self.creationResult.value = .UnexpectedError
	}
	
	
}




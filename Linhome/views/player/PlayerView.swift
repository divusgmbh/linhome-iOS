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
import Foundation
import linphonesw

class PlayerView : ViewWithModel {
	
	let videoPreviewPercentageOfScreenWidth: CGFloat = UIDevice.ipad() && UIScreen.isLandscape ? 0.75 : 0.95
	let videoAspectRatio: CGFloat = 4/3
	let iconPercentageOfScreenWidth: CGFloat = 0.4
	var playerViewModel : PlayerViewModel?
	
	public required init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
		super.init(nibName: nibNameOrNil,bundle: nibBundleOrNil)
	}
	
	required init?(coder: NSCoder) {
		super.init(coder: coder)
	}
	
	override func viewDidLoad() {
		super.viewDidLoad()
		
		guard
			let callId = NavigationManager.it.nextViewArgument as? String,
			let event = Core.get().workAroundFindCallLogFromCallId(callId: callId)?.getHistoryEvent(),
			let player = try?Core.get().createLocalPlayer(soundCardName: getSoundCard(), videoDisplayName: "IOSDisplay", windowId: nil) else {
				NavigationManager.it.navigateUp()
				return
		}
		
		HistoryEventStore.it.markAsRead(historyEventId: event.id)
		
		self.view.backgroundColor = Theme.getColor("color_j")
		
		playerViewModel = PlayerViewModel(callId: callId, player: player)
		manageModel(playerViewModel!)
		
		// Close button
		
		let close = UIButton(frame: CGRect(x: 0,y: 0,width: 20,height: 20))
		close.prepare(iconName: "icons/cancel", tintColor: "color_c")
		self.view.addSubview(close)
		close.snp.makeConstraints { (make) in
			make.right.equalToSuperview().offset(-40)
			make.top.equalToSuperview().offset(40)
		}
		close.onClick {
			close.alpha = 0.3
			NavigationManager.it.navigateUp()
		}
		
		
		// Controls
		
		let controls = PlayerControls(viewModel: playerViewModel!)
		addChild(controls)
		self.view.addSubview(controls.view)
		controls.view.snp.makeConstraints { (make) in
			make.bottom.equalToSuperview().offset(-50)
			make.left.equalToSuperview().offset(20)
			make.right.equalToSuperview().offset(-20)
			make.height.equalTo(40)
		}
		controls.didMove(toParent: self)
		
				
		// Video/Audio view
		
		if (event.hasVideo) {
			let videoView = UIView()
			videoView.backgroundColor = .black
			let videoPreviewWidth = UIScreen.main.bounds.size.width * videoPreviewPercentageOfScreenWidth
			videoView.frame = CGRect(x: 0,y: 0,width: videoPreviewWidth ,height: videoPreviewWidth / videoAspectRatio)
			self.view.addSubview(videoView)
			player.windowId = UnsafeMutableRawPointer(Unmanaged.passRetained(videoView).toOpaque())
			videoView.snp.makeConstraints { (make) in
				make.center.equalToSuperview()
				make.width.equalTo(videoPreviewWidth)
				make.height.equalTo(videoPreviewWidth / videoAspectRatio)
			}
		} else {
			let iconSize = UIScreen.main.bounds.size.width * iconPercentageOfScreenWidth
			let audio = UIImageView(frame: CGRect(x: 0,y: 0,width: iconSize ,height: iconSize))
			audio.prepareSwiftSVG(iconName: "icons/audio_media", fillColor: "color_c", bgColor: nil)
			self.view.addSubview(audio)
			audio.snp.makeConstraints { (make) in
				make.center.equalToSuperview()
				make.width.height.equalTo(iconSize)
			}
			
		}
	}
	
	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		playerViewModel?.playFromStart()
	}
	
	override func isCallView() -> Bool {
		return true
	}
	
	func getSoundCard() -> String? {
		var speakerCard: String? = nil
		var earpieceCard: String? = nil
		Core.get().audioDevices.forEach { device in
			if (device.hasCapability(capability: .CapabilityPlay)) {
				if (device.type == .Speaker) {
					speakerCard = device.id
				} else if (device.type == .Earpiece) {
					earpieceCard = device.id
				}
			}
		}
		return speakerCard != nil ? speakerCard : earpieceCard
	}
	
	
	override func viewWillDisappear(_ animated: Bool) {
		playerViewModel?.pausePlay()
		playerViewModel?.end()
		super.viewWillDisappear(animated)
	}
	
	
}

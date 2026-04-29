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

extension Call {
    
    enum RecordMode{
        case NO_VIDEO_RECORDING
        case DURATION_TIMER_START_IMMEDIATELY
        case DURATION_TIMER_START_WITH_FIRST_FRAME
        case DURATION_TIMER_START_WITH_SNAPSHOT_PROCESSED
        case DURATION_RECORDER_START_IMMEDIATELY
        case DURATION_RECORDER_START_WITH_FIRST_FRAME
        case DURATION_RECORDER_START_WITH_SNAPSHOT_PROCESSED
    }
        
	func extendedAcceptEarlyMedia(core:Core) {
		do {
			let earlyMediaCallParams: CallParams = try core.createCallParams(call: self)
			earlyMediaCallParams.recordFile = callLog!.getHistoryEvent().mediaFileName!
			cameraEnabled = false
            muteAudioPLayBack()
            earlyMediaCallParams.videoEnabled = true
			earlyMediaCallParams.audioEnabled = true
            earlyMediaCallParams.audioDirection = MediaDirection.RecvOnly
            earlyMediaCallParams.videoDirection = MediaDirection.RecvOnly
            earlyMediaCallParams.micEnabled = false
            earlyMediaCallParams.earlyMediaSendingEnabled = true
            earlyMediaCallParams.cameraEnabled = false
			try acceptEarlyMediaWithParams(params: earlyMediaCallParams)
            extendedStartRecording()
			sendVfuRequest()
		} catch {
			Log.error("[extendedAcceptEarlyMedia] exception \(error) ")
		}
	}
	
	func extendedAccept(core:Core) {
		do {
			let inCallParams: CallParams = try!core.createCallParams(call: self)
			inCallParams.recordFile = callLog!.getHistoryEvent().mediaFileName!
			cameraEnabled = false
			inCallParams.audioEnabled = true
            inCallParams.videoEnabled = true
            inCallParams.cameraEnabled = false
            inCallParams.audioDirection = MediaDirection.SendRecv
            inCallParams.videoDirection = MediaDirection.SendRecv
            microphoneVolumeGain = 1.0
            unMuteAudioPLayBack()
			if let device = DeviceStore.it.findDeviceByAddress(address: remoteAddress!) {
				Core.get().useRfc2833ForDtmf = device.actionsMethodType == "method_dtmf_rfc_4733"
				Core.get().useInfoForDtmf = device.actionsMethodType == "method_dtmf_sip_info"
			}
			try acceptWithParams(params: inCallParams)
            extendedStartRecording()
		} catch {
			Log.error("[extendedAccept] exception \(error) ")
		}
	}
	
	
	// Sharing between extension & app
	
	static  let userDefaults = UserDefaults(suiteName: Config.appGroupName)!

	
	static func hasOwnerShip(_ callId:String) -> Bool {
		let result =  Bundle.main.bundleURL.path == userDefaults.object(forKey: "owning"+callId) as! String?
		return result
	}
	
	static func ownerShipRequessted(_ callId:String) -> Bool {
		let result = Bundle.main.bundleURL.path == userDefaults.object(forKey: "owning"+callId) as! String? && userDefaults.bool(forKey:"requesting"+callId)
		return result
	}
		
	static func requestOwnerShip(_ callId:String){
		Log.info("[OwnerShip] requestOwnerShip "+callId)
		userDefaults.setValue(true, forKey:"requesting"+callId)
	}
	
	static func takeOwnerShip(_ callId:String){
		Log.info("[OwnerShip] takeOwnerShip "+callId)
		userDefaults.setValue(Bundle.main.bundleURL.path, forKey:"owning"+callId)
	}
	
	static func releaseOwnerShip(_ callId:String) {
		Log.info("[OwnerShip] releaseOwnerShip "+callId)
		userDefaults.removeObject(forKey: "owning"+callId)
		userDefaults.removeObject(forKey: "requesting"+callId)
	}
	
	static func ownerShipReleased(_ callId:String) -> Bool {
		let result = userDefaults.object(forKey: "owning"+callId)  == nil
		Log.info("[OwnerShip] ownerShipReleased ? = \(result) "+callId)
		return result
	}
	
	static func waitSyncForReleased(timeoutSec:Int,_ callId:String) -> Bool {
		var i = 0
		while (!ownerShipReleased(callId) && i < timeoutSec*50 && !hasOwnerShip(callId)) {
			usleep(20000)
			i+=1
		}
		Log.info("[OwnerShip]  waitSyncForReleased ? \(i < timeoutSec*50) "+callId)
		return i < timeoutSec*50
	}
	
	
	
	static func requestAndWaitForOwnerShip(_ callId:String) {
		Log.warn("[OwnerShip] requestAndWaitForOwnerShip  "+callId)
		requestOwnerShip(callId)
		if (!Call.waitSyncForReleased(timeoutSec: 5,callId)) {
			Log.warn("[OwnerShip] Timed out waiting for call to be released in Service Extension "+callId)
			return
		}
		takeOwnerShip(callId)
	}
	
	func requestAndWaitForOwnerShip(_ callId:String) {
		Call.requestAndWaitForOwnerShip(callId)
	}
	
	// Early media phase - work around to avoid playing audio back to user, but still have the stream
	public func muteAudioPLayBack() {
		speakerVolumeGain = -1000.0
	}

	public func unMuteAudioPLayBack() {
		speakerVolumeGain = 0.0
	}
    
    public func extendedStartRecording(){
        let isRecordRunning = callLog!.getHistoryEvent().isRecordRunning
        if(!isRecordRunning){
            callLog!.getHistoryEvent().isRecordRunning = true
            switch(Config.recordMode){
            case .NO_VIDEO_RECORDING:
                callLog!.getHistoryEvent().isRecordRunning = false
                return
            case .DURATION_RECORDER_START_IMMEDIATELY:
                do {
                    var recordParams = try core?.createRecorderParams()
                    recordParams?.fileFormat = MediaFileFormat.Mkv
                    recordParams?.videoCodec = "H264"
                    callLog!.getHistoryEvent().recorder = try core?.createRecorder(params: recordParams!)
                    if(callLog!.getHistoryEvent().recorder != nil){
                        try callLog!.getHistoryEvent().recorder?.open(file: params?.recordFile ?? "")
                        try callLog!.getHistoryEvent().recorder?.start()
                        startRecording()
                        callLog!.getHistoryEvent().rdTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
                            let duration: Int = self.callLog!.getHistoryEvent().recorder?.duration ?? 0
                            if (duration >= Config.recordMaxDuration) {
                                self.extendedStopRecording()
                                let path = self.params?.recordFile
                                self.params?.recordFile = ""
                                self.params?.recordFile = path
                                timer.invalidate()
                                Log.info("[Call+Extension] recording stopped due max. duration reached")
                            }
                        }
                    }
                }catch {
                    Log.error("[Call+Extension] unable to create recorder: \(error)")
                }
                break
            case .DURATION_TIMER_START_IMMEDIATELY:
                Log.error("[Call+Extension] record mode not supported: \(RecordMode.DURATION_TIMER_START_IMMEDIATELY)")
                break
            case .DURATION_TIMER_START_WITH_FIRST_FRAME:
                Log.error("[Call+Extension] record mode not supported: \(RecordMode.DURATION_TIMER_START_WITH_FIRST_FRAME)")
                break
            case .DURATION_TIMER_START_WITH_SNAPSHOT_PROCESSED:
                Log.error("[Call+Extension] record mode not supported: \(RecordMode.DURATION_TIMER_START_WITH_SNAPSHOT_PROCESSED)")
                break
            case .DURATION_RECORDER_START_WITH_FIRST_FRAME:
                Log.error("[Call+Extension] record mode not supported: \(RecordMode.DURATION_RECORDER_START_WITH_FIRST_FRAME)")
                break
            case .DURATION_RECORDER_START_WITH_SNAPSHOT_PROCESSED:
                Log.error("[Call+Extension] record mode not supported: \(RecordMode.DURATION_RECORDER_START_WITH_SNAPSHOT_PROCESSED)")
                break
            }
        }
    }
    
    public func extendedStopRecording(){
        callLog!.getHistoryEvent().isRecordRunning = false
        callLog!.getHistoryEvent().recorder?.close()
        callLog!.getHistoryEvent().rdTimer?.invalidate()
        stopRecording()
    }
    
    public func extendedClose(core: Core){
        extendedStopRecording()
        HistoryEventStore.it.rotateRecordings(cleanup: false, core: core)
    }
	
}

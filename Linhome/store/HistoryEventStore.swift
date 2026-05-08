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

class HistoryEventStore {
	
	static var it = HistoryEventStore()
	
	private var historyEventsConfig: Config
	
	var historyEvents  =   [String: HistoryEvent]() // CallId / History event
	var historyEventsXml = StorageManager.it.historyEventsXml
	
	init () {
		FileUtil.ensureFileExists(path: historyEventsXml)
		historyEventsConfig = try!Factory.Instance.createConfig(path: "") // we want to store in XML, not in rc as there could be some funny names.
		let _ = historyEventsConfig.loadFromXmlFile(filename: historyEventsXml)
		historyEvents = readFromXml()
	}
	
	static func refresh() {
		it = HistoryEventStore()
	}
	
	func readFromXml() -> [String: HistoryEvent]  {
		var result =  [String: HistoryEvent]()
		historyEventsConfig.sectionsNamesList.forEach { it in
			historyEventsConfig.getString(section: it, key: "call_id").map{
				result[$0] = HistoryEvent(id: it,
										  callId: historyEventsConfig.getString(section: it, key: "call_id")!,
										  viewedByUser: historyEventsConfig.getBool(section: it, key: "viewed_by_user", defaultValue: false),
										  mediaFileName: historyEventsConfig.getString(section: it, key: "media_file_name") ?? "",
										  mediaThumbnailFileName: historyEventsConfig.getString(section: it, key: "media_thumbnail_file_name") ?? "",
                                          hasVideo: Config.forceNoVideo ? false :  historyEventsConfig.getBool(section: it, key: "has_video", defaultValue: false),
										  forcedMissed: historyEventsConfig.getBool(section: it, key: "forced_missed", defaultValue: false)
				)
			}
		}
		return result
	}
	
	
	func sync() {
		historyEventsConfig.sectionsNamesList.forEach { it in
			historyEventsConfig.cleanSection(section: it)
		}
		historyEvents.forEach { entry in
			historyEventsConfig.setBool(section: entry.value.id, key: "viewed_by_user", value: entry.value.viewedByUser)
			historyEventsConfig.setString(
				section: entry.value.id,
				key: "media_file_name",
				value: entry.value.mediaFileName
			)
			historyEventsConfig.setString(
				section: entry.value.id,
				key: "media_thumbnail_file_name",
				value: entry.value.mediaThumbnailFileName
			)
			historyEventsConfig.setString(section: entry.value.id, key: "call_id", value: entry.value.callId)
            historyEventsConfig.setBool(section: entry.value.id, key: "has_video", value: Config.forceNoVideo ? false : entry.value.hasVideo)
			historyEventsConfig.setBool(section: entry.value.id, key: "forced_missed", value: entry.value.forcedMissed)
		}
		FileUtil.write(string: historyEventsConfig.dumpAsXml(), toPath: historyEventsXml)
	}
	
	
	
	func persistHistoryEvent(entry: HistoryEvent) {
		entry.callId.map { it in
			historyEvents[it] = entry
			sync()
		}
	}
	
	func removeHistoryEvent(entry: HistoryEvent) {
		if (FileUtil.fileExists(path: entry.mediaFileName)) {
			FileUtil.delete(path: entry.mediaFileName)
		}
		
		if (FileUtil.fileExists(path: entry.mediaThumbnailFileName)) {
			FileUtil.delete(path: entry.mediaThumbnailFileName)
		}
		
		historyEvents = historyEvents.filter { $0.key != entry.callId }
		sync()
	}
	
	func removeHistoryEventByCallId(callId: String) {
		if let event = findHistoryEventByCallId(callId: callId) {
			removeHistoryEvent(entry: event)
		}
	}
	
	func findHistoryEventByCallId(callId: String) -> HistoryEvent? {
		return historyEvents[callId]
	}
	
	
	func markAsRead(historyEventId: String) {
		historyEvents.filter { $0.value.id ==  historyEventId }.forEach { event in
			event.value.viewedByUser = true
			persistHistoryEvent(entry: event.value)
		}
	}
    
    func rotateRecordings(cleanup: Bool, core: Core){
        Log.info("[HistoryEventStore] rotating files now")
        if(core.globalState != GlobalState.On){
            Log.warn("[HistoryEventStore] rotating files not possible, core not ready, current state:\(core.globalState)")
            return
        }
        let max = Config.historyMaxCount
        let directory = StorageManager.it.callsRecordingsDir
        
        var callIdsToRemove = [String]()
        var filesToKeep = [String]()
        core.callLogs
            .sorted(by: { $0.startDate > $1.startDate })
            .enumerated()
            .forEach { index, log in
                if index < max {
                    let event = log.getHistoryEvent()
                    filesToKeep.append(event.mediaFileName)
                    filesToKeep.append(event.mediaThumbnailFileName)
                } else {
                    callIdsToRemove.append(log.callId ?? "")
                }
            }
        // Remove from historyevent data
        callIdsToRemove.forEach { callId in
            historyEvents.removeValue(forKey: callId)
            Log.info("[HistoryEventStore] rotate data, remove obsolete event for call id: \(callId)")
            // remove rom call log
            if let log = core.workAroundFindCallLogFromCallId(callId: callId) {
                core.removeCallLog(callLog: log)
                Log.info("[HistoryEventStore] rotate data, remove obsolete call log for call id: \(callId)")
            }
        }
        
        //Get all files in the directory, finish if no files available
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(atPath: directory), !files.isEmpty else {
            if !callIdsToRemove.isEmpty { sync() }
            return
        }
        
        // Sort by modification time (Newest First)
        let filePaths = files.map { directory + $0 }
        let sortedFiles = filePaths.sorted { path1, path2 in
            let date1 = (try? fileManager.attributesOfItem(atPath: path1))?[.modificationDate] as? Date ?? Date.distantPast
            let date2 = (try? fileManager.attributesOfItem(atPath: path2))?[.modificationDate] as? Date ?? Date.distantPast
            return date1 > date2
        }
        
        // Delete mkv files and according
        var filesToDelete = [String]()
        sortedFiles.forEach { filePath in
            if filesToKeep.contains(filePath) {
                if filePath.hasSuffix(".mkv") {
                    //stripAudio(filePath)
                }
            } else {
                filesToDelete.append(filePath)
            }
        }
        filesToDelete.forEach { path in
            if cleanup {
                FileUtil.delete(path: path)
                Log.info("[HistoryEventStore] cleanup files, deleting file: \((path as NSString).lastPathComponent)")
            } else if !path.lowercased().hasSuffix(".part") {
                FileUtil.delete(path: path)
                Log.info("[HistoryEventStore] rotating files, deleting obsolete file: \((path as NSString).lastPathComponent)")
            }
        }
        
        if !callIdsToRemove.isEmpty {
            sync()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("historyDidSync"), object: nil)
            }
        }
    }
}

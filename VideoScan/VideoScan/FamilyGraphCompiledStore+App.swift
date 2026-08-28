// FamilyGraphCompiledStore+App.swift
// The app's production store: VideoScanCore's layout + the app log.
import Foundation
import VideoScanCore

extension FamilyGraphCompiledStore {
    static var app: FamilyGraphCompiledStore {
        var store = production
        store.log = { appLog.write($0) }
        return store
    }
}

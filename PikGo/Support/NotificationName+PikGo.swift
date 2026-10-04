//
//  NotificationName+PikGo.swift
//  PikGo
//

import Foundation

extension Notification.Name {
    static let restoreRealLocation = Notification.Name("RestoreRealLocation")
    static let simulateSavedCoordinate = Notification.Name("SimulateSavedCoordinate")
    static let openPairingImporter = Notification.Name("OpenPairingImporter")
    static let appRuntimeStateDidChange = Notification.Name("AppRuntimeStateDidChange")
}

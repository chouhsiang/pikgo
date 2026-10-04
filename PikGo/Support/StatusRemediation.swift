//
//  StatusRemediation.swift
//  PikGo
//

import UIKit

enum StatusRemediation {
    static let localDevVPNAppStore = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    private static let localDevVPNSchemes = [
        URL(string: "localdevvpn://")!,
        URL(string: "LocalDevVPN://")!
    ]

    static func openLocalDevVPN() {
        let application = UIApplication.shared
        func openStore() {
            application.open(localDevVPNAppStore)
        }

        func tryScheme(at index: Int) {
            guard localDevVPNSchemes.indices.contains(index) else {
                openStore()
                return
            }
            application.open(localDevVPNSchemes[index]) { success in
                if !success {
                    tryScheme(at: index + 1)
                }
            }
        }

        tryScheme(at: 0)
    }

    static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    static func openPairingImporter() {
        UserDefaults.standard.set(AppFeature.settings.id, forKey: "primaryTabSelection")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: .openPairingImporter, object: nil)
        }
    }
}

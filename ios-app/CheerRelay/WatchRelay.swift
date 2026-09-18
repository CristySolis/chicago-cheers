import Foundation
import Combine
import ConnectIQ // Garmin Connect IQ Mobile SDK — add via CocoaPods `pod 'ConnectIQ'`
                 // or the framework from developer.garmin.com/connect-iq/sdk/

/// Thin wrapper around the Connect IQ Mobile SDK: finds your paired watch,
/// confirms the Cheer Squad data field is installed on it, and sends
/// message payloads to it.
///
/// NOTE: method/class names below match the ConnectIQ iOS SDK's long-stable
/// public API (ConnectIQ / IQDevice / IQApp / sendMessage). Cross-check
/// against the exact SDK version you download — Garmin occasionally
/// revises signatures — this file is a faithful starting point, not something
/// that's been compiled against the real framework (that needs Xcode).
final class WatchRelay: NSObject, ObservableObject {

    @Published var connectedDeviceName: String?
    @Published var lastSendError: String?
    @Published var lastSentAt: Date?

    private var device: IQDevice?
    private var app: IQApp?

    func initializeSDK() {
        ConnectIQ.sharedInstance().initialize(
            withUrlScheme: Config.urlScheme,
            uiOverrideDelegate: nil
        )
        restoreKnownDevice()
    }

    /// Call from your root view's .onOpenURL / application(_:open:options:) —
    /// this is how Garmin Connect Mobile hands control back after the user
    /// picks a device in the device-selection flow.
    func handle(url: URL) {
        let devices = ConnectIQ.sharedInstance().parseDeviceSelectionResponse(from: url) as? [IQDevice]
        guard let picked = devices?.first else { return }
        adopt(device: picked)
    }

    /// Presents Garmin Connect Mobile's "choose a device" screen. Only
    /// needed once — after that we remember the device.
    func selectDevice() {
        ConnectIQ.sharedInstance().showDeviceSelection()
    }

    // The SDK doesn't persist the chosen device across launches, so we archive
    // it ourselves — otherwise every cold start needs a trip through Garmin
    // Connect Mobile's picker.
    private static let storedDeviceKey = "cheerrelay.selectedDevice"

    private func restoreKnownDevice() {
        guard let data = UserDefaults.standard.data(forKey: Self.storedDeviceKey),
              let known = try? NSKeyedUnarchiver.unarchivedObject(ofClass: IQDevice.self, from: data)
        else { return }
        adopt(device: known)
    }

    private func adopt(device: IQDevice) {
        self.device = device
        self.app = IQApp(uuid: UUID(uuidString: Config.watchAppId),
                          store: UUID(uuidString: Config.watchAppStoreId),
                          device: device)
        ConnectIQ.sharedInstance().register(forDeviceEvents: device, delegate: self)
        connectedDeviceName = device.friendlyName

        if let data = try? NSKeyedArchiver.archivedData(withRootObject: device,
                                                        requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: Self.storedDeviceKey)
        }
    }

    func send(_ message: CheerMessage) {
        guard let app else {
            lastSendError = "No watch selected yet — tap Connect."
            return
        }
        ConnectIQ.sharedInstance().sendMessage(
            message.payload,
            to: app,
            progress: nil,
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self?.lastSentAt = Date()
                        self?.lastSendError = nil
                    default:
                        let reason = NSStringFromSendMessageResult(result) ?? "unknown"
                        self?.lastSendError = "Delivery failed (\(reason)) — will retry next poll."
                    }
                }
            }
        )
    }
}

extension WatchRelay: IQDeviceEventDelegate {
    func deviceStatusChanged(_ device: IQDevice!, status: IQDeviceStatus) {
        DispatchQueue.main.async {
            self.connectedDeviceName = status == .connected ? device.friendlyName : nil
        }
    }
}

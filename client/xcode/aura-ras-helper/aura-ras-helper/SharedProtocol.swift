import Foundation

@objc protocol AuraRASTunnelProtocol {
    func establishBridge(toRemotePort remotePort: String, withReply reply: @escaping (String?) -> Void)
    func teardownBridge(localPort: String)
}

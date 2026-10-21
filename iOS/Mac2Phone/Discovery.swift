import Foundation
import Network
import Combine

typealias Discovery = NearbyService
extension NearbyService {
    typealias Found = Device
    var all: [Device] { devices }
    var probing: Bool { devices.isEmpty }
    func start(port: UInt16, extraHosts: [String] = []) { start() }
}

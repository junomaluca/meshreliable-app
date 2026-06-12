//
//  MQTTVirtualTransport.swift
//  Meshtastic
//
//  Transport implementation for Virtual MQTT mode.
//  Discovers stored devices that have MQTT config and presents them as connectable.
//

import Foundation
import OSLog
@preconcurrency import SwiftData

class MQTTVirtualTransport: Transport {

	let type: TransportType = .mqttVirtual
	var status: TransportStatus { .ready }
	let requiresPeriodicHeartbeat: Bool = false
	let supportsManualConnection: Bool = false

	func discoverDevices() async -> AsyncStream<DiscoveryEvent> {
		// Virtual MQTT devices are surfaced from the Connect UI directly via SwiftData query.
		// Discovery is not needed since they're persisted.
		return AsyncStream { continuation in
			continuation.finish()
		}
	}

	func connect(to device: Device) async throws -> any Connection {
		// Connection is created externally via connectToVirtualMQTT() and injected.
		throw AccessoryError.connectionFailed("MQTTVirtualTransport.connect(to:) should not be called directly. Use connectToVirtualMQTT().")
	}

	func device(forManualConnection: String) -> Device? {
		nil
	}

	func manuallyConnect(toDevice: Device) async throws {
		// Not supported
	}
}

//
//  AccessoryManager+VirtualMQTT.swift
//  Meshtastic
//
//  Virtual MQTT connection support — connects to stored devices via MQTT.
//

import Foundation
import OSLog
@preconcurrency import SwiftData

extension AccessoryManager {

	/// Connect to a previously-seen device via Virtual MQTT using stored credentials.
	func connectToVirtualMQTT(nodeNum: Int64) async throws {
		let descriptor = FetchDescriptor<NodeInfoEntity>(
			predicate: #Predicate<NodeInfoEntity> { $0.num == nodeNum }
		)
		guard let nodeInfo = try context.fetch(descriptor).first else {
			throw AccessoryError.connectionFailed("No stored node info for \(nodeNum)")
		}
		guard let mqttConfig = nodeInfo.mqttConfig, mqttConfig.enabled else {
			throw AccessoryError.connectionFailed("Node \(nodeNum) has no MQTT config or MQTT is disabled")
		}
		guard let myInfo = nodeInfo.myInfo else {
			throw AccessoryError.connectionFailed("Node \(nodeNum) has no MyInfo")
		}

		// Build MQTT snapshot
		let originalAddress = mqttConfig.address ?? "mqtt.meshtastic.org"
		var host = originalAddress
		var port: UInt16 = mqttConfig.tlsEnabled ? 8883 : 1883
		if originalAddress.contains(":") {
			let parts = originalAddress.components(separatedBy: ":")
			host = parts[0]
			port = UInt16(parts[1]) ?? port
		}
		// Force TLS for public server
		var tlsEnabled = mqttConfig.tlsEnabled
		if host.lowercased() == "mqtt.meshtastic.org" {
			tlsEnabled = true
			port = 8883
		}

		let mqttSnapshot = MQTTSnapshot(
			address: host,
			port: port,
			username: mqttConfig.username,
			password: mqttConfig.password,
			root: (mqttConfig.root?.isEmpty == false) ? mqttConfig.root! : "msh",
			tlsEnabled: tlsEnabled
		)

		// Build user snapshot
		let userSnapshot = UserSnapshot(
			longName: nodeInfo.user?.longName ?? "Unknown",
			shortName: nodeInfo.user?.shortName ?? "?",
			nodeNum: nodeNum,
			publicKey: nodeInfo.user?.publicKey
		)

		// Build channel snapshots
		let virtualChannels: [VirtualChannel] = myInfo.channels.compactMap { channel in
			// Skip disabled channels (role == 0 means DISABLED)
			guard channel.role != 0 else { return nil }
			return VirtualChannel(
				index: channel.index,
				name: channel.name ?? "",
				psk: channel.psk ?? Data([0x01]), // default PSK if nil
				role: channel.role,
				uplinkEnabled: channel.uplinkEnabled,
				downlinkEnabled: channel.downlinkEnabled
			)
		}

		guard !virtualChannels.isEmpty else {
			throw AccessoryError.connectionFailed("No active channels found for node \(nodeNum)")
		}

		// Create connection
		let connection = MQTTVirtualConnection(
			mqtt: mqttSnapshot,
			user: userSnapshot,
			channels: virtualChannels
		)

		// Create device struct
		let deviceId = String(nodeNum).toUUIDFormatHash()
		let device = Device(
			id: deviceId,
			name: userSnapshot.longName,
			transportType: .mqttVirtual,
			identifier: "mqtt-virtual-\(nodeNum)",
			num: nodeNum
		)

		// Connect with config/database/version checks skipped
		try await connect(
			to: device,
			withConnection: connection,
			wantConfig: false,
			wantDatabase: false,
			versionCheck: false
		)
	}
}

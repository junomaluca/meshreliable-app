//
//  MeshReliableDefaults.swift
//  Meshtastic
//
//  Auto-provisioning: applies MeshReliable default config to freshly-flashed nodes.
//

import Foundation
import MeshtasticProtobufs
import OSLog

struct MeshReliableDefaults {

	private static let configDelay: Duration = .seconds(2)

	// MARK: - Detection

	/// Returns true if the connected node appears to have factory-default settings
	/// and needs MeshReliable provisioning applied.
	static func needsProvisioning(node: NodeInfoEntity) -> Bool {
		// Check LoRa channel_num — factory default is 0, MeshReliable uses 20
		if let loraConfig = node.loRaConfig {
			if loraConfig.channelNum == 0 {
				return true
			}
		} else {
			// No LoRa config entity at all means unconfigured
			return true
		}

		// Check MQTT address — factory default is empty or mqtt.meshtastic.org
		if let mqttConfig = node.mqttConfig {
			let addr = mqttConfig.address ?? ""
			if addr.isEmpty || addr.contains("mqtt.meshtastic.org") {
				return true
			}
		} else {
			return true
		}

		return false
	}

	// MARK: - Apply All Defaults

	@MainActor
	static func applyAll(accessoryManager: AccessoryManager) async {
		guard let deviceNum = accessoryManager.activeDeviceNum else {
			Logger.services.error("[Provisioning] No active device num")
			return
		}

		let context = accessoryManager.context
		guard let connectedNode = getNodeInfo(id: deviceNum, context: context),
			  let user = connectedNode.user else {
			Logger.services.error("[Provisioning] Cannot find connected node or user for provisioning")
			return
		}

		Logger.services.info("[Provisioning] Node needs provisioning — applying MeshReliable defaults...")

		do {
			// 1. LoRa Config
			try await applyLoRaConfig(accessoryManager: accessoryManager, fromUser: user, toUser: user)
			try await Task.sleep(for: configDelay)

			// 2. Channel 0 — maluca (primary)
			try await applyPrimaryChannel(accessoryManager: accessoryManager, fromUser: user, toUser: user)
			try await Task.sleep(for: configDelay)

			// 3. Channel 1 — LongFast (secondary)
			try await applySecondaryChannel(accessoryManager: accessoryManager, fromUser: user, toUser: user)
			try await Task.sleep(for: configDelay)

			// 4. Bluetooth
			try await applyBluetoothConfig(accessoryManager: accessoryManager, fromUser: user, toUser: user)
			try await Task.sleep(for: configDelay)

			// 5. Device (timezone)
			try await applyDeviceConfig(accessoryManager: accessoryManager, fromUser: user, toUser: user)
			try await Task.sleep(for: configDelay)

			// 6. Position
			try await applyPositionConfig(accessoryManager: accessoryManager, fromUser: user, toUser: user)
			try await Task.sleep(for: configDelay)

			// 7. MQTT
			try await applyMQTTConfig(accessoryManager: accessoryManager, fromUser: user, toUser: user)
			try await Task.sleep(for: configDelay)

			// 8. Canned Messages
			try await applyCannedMessageConfig(accessoryManager: accessoryManager, fromUser: user, toUser: user)
			try await Task.sleep(for: configDelay)

			// 9. External Notifications
			try await applyExternalNotificationConfig(accessoryManager: accessoryManager, fromUser: user, toUser: user)
			try await Task.sleep(for: configDelay)

			// 10. Store and Forward
			try await applyStoreForwardConfig(accessoryManager: accessoryManager, fromUser: user, toUser: user)
			try await Task.sleep(for: configDelay)

			Logger.services.info("[Provisioning] All defaults applied successfully")
		} catch {
			Logger.services.error("[Provisioning] Failed during provisioning: \(error.localizedDescription)")
		}
	}

	// MARK: - Individual Config Appliers

	private static func applyLoRaConfig(accessoryManager: AccessoryManager, fromUser: UserEntity, toUser: UserEntity) async throws {
		var config = Config.LoRaConfig()
		config.region = .us
		config.modemPreset = .longFast
		config.configOkToMqtt = true
		config.txEnabled = true
		config.hopLimit = 7
		config.channelNum = 20
		config.usePreset = true

		_ = try await accessoryManager.saveLoRaConfig(config: config, fromUser: fromUser, toUser: toUser)
		Logger.services.info("[Provisioning] LoRa config applied")
	}

	private static func applyPrimaryChannel(accessoryManager: AccessoryManager, fromUser: UserEntity, toUser: UserEntity) async throws {
		var channel = Channel()
		channel.index = 0
		channel.role = .primary
		channel.settings.name = "maluca"
		// PSK from restore-settings.sh: QnMwZnZaUlJkQmhnSTg3ZGlnckhBYzMyU3FVOXpRcm4=
		if let pskData = Data(base64Encoded: "QnMwZnZaUlJkQmhnSTg3ZGlnckhBYzMyU3FVOXpRcm4=") {
			channel.settings.psk = pskData
		}
		channel.settings.uplinkEnabled = true
		channel.settings.downlinkEnabled = true
		channel.settings.moduleSettings.positionPrecision = 32

		_ = try await accessoryManager.saveChannel(channel: channel, fromUser: fromUser, toUser: toUser)
		Logger.services.info("[Provisioning] Primary channel (maluca) applied")
	}

	private static func applySecondaryChannel(accessoryManager: AccessoryManager, fromUser: UserEntity, toUser: UserEntity) async throws {
		var channel = Channel()
		channel.index = 1
		channel.role = .secondary
		channel.settings.name = "LongFast"
		// PSK: AQW== (standard LongFast key)
		if let pskData = Data(base64Encoded: "AQW==") {
			channel.settings.psk = pskData
		}
		channel.settings.uplinkEnabled = true
		channel.settings.downlinkEnabled = true
		channel.settings.moduleSettings.positionPrecision = 0

		_ = try await accessoryManager.saveChannel(channel: channel, fromUser: fromUser, toUser: toUser)
		Logger.services.info("[Provisioning] Secondary channel (LongFast) applied")
	}

	private static func applyBluetoothConfig(accessoryManager: AccessoryManager, fromUser: UserEntity, toUser: UserEntity) async throws {
		var config = Config.BluetoothConfig()
		config.enabled = true
		config.mode = .noPin

		_ = try await accessoryManager.saveBluetoothConfig(config: config, fromUser: fromUser, toUser: toUser)
		Logger.services.info("[Provisioning] Bluetooth config applied (NO_PIN mode)")
	}

	private static func applyDeviceConfig(accessoryManager: AccessoryManager, fromUser: UserEntity, toUser: UserEntity) async throws {
		var config = Config.DeviceConfig()
		config.tzdef = "PST8PDT,M3.2.0/2:00:00,M11.1.0/2:00:00"

		_ = try await accessoryManager.saveTimeZone(config: config, user: Int64(toUser.num))
		Logger.services.info("[Provisioning] Device timezone config applied")
	}

	private static func applyPositionConfig(accessoryManager: AccessoryManager, fromUser: UserEntity, toUser: UserEntity) async throws {
		var config = Config.PositionConfig()
		config.positionBroadcastSecs = 3600
		config.positionFlags = 1

		_ = try await accessoryManager.savePositionConfig(config: config, fromUser: fromUser, toUser: toUser)
		Logger.services.info("[Provisioning] Position config applied")
	}

	private static func applyMQTTConfig(accessoryManager: AccessoryManager, fromUser: UserEntity, toUser: UserEntity) async throws {
		var config = ModuleConfig.MQTTConfig()
		config.enabled = true
		config.proxyToClientEnabled = true
		config.encryptionEnabled = true
		config.mapReportingEnabled = true
		config.mapReportSettings.publishIntervalSecs = 3600
		config.root = "msh/US"
		config.address = "home.yazdikann.com:1883"
		config.username = "admin"
		config.password = "admin"
		config.tlsEnabled = false

		_ = try await accessoryManager.saveMQTTConfig(config: config, fromUser: fromUser, toUser: toUser)
		Logger.services.info("[Provisioning] MQTT config applied")
	}

	private static func applyCannedMessageConfig(accessoryManager: AccessoryManager, fromUser: UserEntity, toUser: UserEntity) async throws {
		var config = ModuleConfig.CannedMessageConfig()
		config.enabled = true
		config.sendBell = true

		_ = try await accessoryManager.saveCannedMessageModuleConfig(config: config, fromUser: fromUser, toUser: toUser)
		try await Task.sleep(for: configDelay)

		let messages = "Are you ok?|I am ok|I am lost|I need help|I want to leave|Where are you?|Meet at the meeting point|I need to drink/eat|Yes|No|OK"
		_ = try await accessoryManager.saveCannedMessageModuleMessages(messages: messages, fromUser: fromUser, toUser: toUser)
		Logger.services.info("[Provisioning] Canned message config applied")
	}

	private static func applyExternalNotificationConfig(accessoryManager: AccessoryManager, fromUser: UserEntity, toUser: UserEntity) async throws {
		var config = ModuleConfig.ExternalNotificationConfig()
		config.enabled = true
		config.alertBell = true
		config.alertMessage = true
		config.nagTimeout = 1

		_ = try await accessoryManager.saveExternalNotificationModuleConfig(config: config, fromUser: fromUser, toUser: toUser)
		Logger.services.info("[Provisioning] External notification config applied")
	}

	private static func applyStoreForwardConfig(accessoryManager: AccessoryManager, fromUser: UserEntity, toUser: UserEntity) async throws {
		var config = ModuleConfig.StoreForwardConfig()
		config.enabled = true
		config.heartbeat = true
		config.records = 100
		config.historyReturnMax = 100
		config.historyReturnWindow = 72000

		_ = try await accessoryManager.saveStoreForwardModuleConfig(config: config, fromUser: fromUser, toUser: toUser)
		Logger.services.info("[Provisioning] Store & Forward config applied")
	}
}

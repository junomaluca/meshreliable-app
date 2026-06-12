//
//  MQTTVirtualConnection.swift
//  Meshtastic
//
//  Virtual MQTT connection that impersonates the physical device on MQTT.
//

import Foundation
import CocoaMQTT
import OSLog
import MeshtasticProtobufs

actor MQTTVirtualConnection: Connection {

	let type: TransportType = .mqttVirtual
	private(set) var isConnected: Bool = false

	private let mqttSnapshot: MQTTSnapshot
	private let userSnapshot: UserSnapshot
	private let channels: [VirtualChannel]

	private var mqttClient: CocoaMQTT?
	private var delegate: MQTTVirtualDelegate?
	private var streamContinuation: AsyncStream<ConnectionEvent>.Continuation?

	private var nodeNum: UInt32 { UInt32(userSnapshot.nodeNum) }
	private var nodeHex: String { String(format: "%08x", nodeNum) }
	private var gatewayId: String { "!\(nodeHex)" }

	init(mqtt: MQTTSnapshot, user: UserSnapshot, channels: [VirtualChannel]) {
		self.mqttSnapshot = mqtt
		self.userSnapshot = user
		self.channels = channels
	}

	func connect() async throws -> AsyncStream<ConnectionEvent> {
		let (stream, continuation) = AsyncStream<ConnectionEvent>.makeStream()
		self.streamContinuation = continuation

		let clientId = "MeshtasticVirtual-\(nodeHex)-\(Int.random(in: 1000...9999))"
		let client = CocoaMQTT(clientID: clientId, host: mqttSnapshot.address, port: mqttSnapshot.port)
		client.enableSSL = mqttSnapshot.tlsEnabled
		client.allowUntrustCACertificate = true
		client.username = mqttSnapshot.username
		client.password = mqttSnapshot.password
		client.keepAlive = 60
		client.cleanSession = true
		client.autoReconnect = true

		let handler: @Sendable (MQTTVirtualDelegateEvent) -> Void = { [weak self] event in
			guard let self else { return }
			Task { await self.handleDelegateEvent(event) }
		}
		let mqttDelegate = MQTTVirtualDelegate(handler: handler)
		client.delegate = mqttDelegate

		self.mqttClient = client
		self.delegate = mqttDelegate

		let success = client.connect()
		if !success {
			continuation.yield(.error(ConnectionError.ioError("MQTT Virtual: connect() returned false")))
		}

		return stream
	}

	func send(_ data: ToRadio) async throws {
		guard isConnected else { return }

		// Only handle outgoing MeshPackets
		guard case .packet(var packet) = data.payloadVariant else { return }

		// Only handle decoded packets (we need to encrypt them)
		guard case .decoded(let decoded) = packet.payloadVariant else { return }

		let plaintext: Data
		do {
			plaintext = try decoded.serializedData()
		} catch {
			Logger.mqtt.error("[MQTT Virtual] Failed to serialize decoded payload: \(error.localizedDescription)")
			return
		}

		// Find the channel for this packet
		let channelIndex = Int(packet.channel)
		guard let channel = channels.first(where: { Int($0.index) == channelIndex }) else {
			Logger.mqtt.error("[MQTT Virtual] No channel found for index \(channelIndex)")
			return
		}

		// Generate a packet ID if none set
		if packet.id == 0 {
			packet.id = UInt32.random(in: 1...UInt32.max)
		}

		// Set packet origin
		packet.from = nodeNum
		if packet.hopStart == 0 {
			packet.hopStart = packet.hopLimit > 0 ? packet.hopLimit : 3
		}

		// Encrypt the payload
		guard let ciphertext = MeshtasticCrypto.encrypt(
			plaintext: plaintext,
			psk: channel.psk,
			packetId: packet.id,
			fromNode: nodeNum
		) else {
			Logger.mqtt.error("[MQTT Virtual] Encryption failed")
			return
		}

		// Replace decoded with encrypted
		packet.payloadVariant = .encrypted(ciphertext)

		// Build the ServiceEnvelope
		var envelope = ServiceEnvelope()
		envelope.packet = packet
		let channelName = channel.name.isEmpty ? "LongFast" : channel.name
		envelope.channelID = channelName
		envelope.gatewayID = gatewayId

		// Publish
		let topic = "\(mqttSnapshot.root)/2/e/\(channelName)/\(gatewayId)"
		do {
			let envelopeData = try envelope.serializedData()
			let message = CocoaMQTTMessage(topic: topic, payload: [UInt8](envelopeData), qos: .qos1, retained: false)
			mqttClient?.publish(message)
			Logger.mqtt.info("[MQTT Virtual] Published to \(topic, privacy: .public)")
		} catch {
			Logger.mqtt.error("[MQTT Virtual] Failed to serialize envelope: \(error.localizedDescription)")
		}
	}

	func disconnect(withError: Error?, shouldReconnect: Bool) async throws {
		isConnected = false
		mqttClient?.disconnect()
		mqttClient = nil
		delegate = nil
		if let error = withError {
			streamContinuation?.yield(.error(error))
		} else {
			streamContinuation?.yield(.disconnected(shouldReconnect: shouldReconnect))
		}
		streamContinuation?.finish()
		streamContinuation = nil
	}

	func drainPendingPackets() async throws {
		// No-op: MQTT is push-based
	}

	func startDrainPendingPackets() throws {
		// No-op: MQTT is push-based
	}

	func appDidEnterBackground() {
		// MQTT stays connected in background via system networking
	}

	func appDidBecomeActive() {
		// Nothing needed
	}

	// MARK: - Private

	private func handleDelegateEvent(_ event: MQTTVirtualDelegateEvent) {
		switch event {
		case .connected:
			isConnected = true
			// Subscribe to mesh topic
			let topic = "\(mqttSnapshot.root)/2/e/#"
			mqttClient?.subscribe(topic, qos: .qos1)
			Logger.mqtt.info("[MQTT Virtual] Connected, subscribed to \(topic, privacy: .public)")
			streamContinuation?.yield(.logMessage("MQTT Virtual connected to \(mqttSnapshot.address)"))

		case .disconnected(let error):
			isConnected = false
			if let error {
				streamContinuation?.yield(.error(ConnectionError.ioError("MQTT Virtual disconnected: \(error.localizedDescription)")))
			} else {
				streamContinuation?.yield(.disconnected(shouldReconnect: true))
			}

		case .message(let topic, let payload):
			handleIncomingMessage(topic: topic, payload: payload)
		}
	}

	private func handleIncomingMessage(topic: String, payload: [UInt8]) {
		// Skip status topics
		if topic.contains("/stat/") { return }

		// Parse ServiceEnvelope
		let data = Data(payload)
		guard let envelope = try? ServiceEnvelope(serializedBytes: data) else {
			Logger.mqtt.debug("[MQTT Virtual] Failed to parse ServiceEnvelope")
			return
		}

		var packet = envelope.packet

		// Skip self-originated packets (we already show them locally)
		if packet.from == nodeNum {
			// Allow routing/ack packets back through
			if case .decoded(let decoded) = packet.payloadVariant,
			   decoded.portnum == .routingApp {
				// pass through
			} else {
				return
			}
		}

		// Handle encrypted payload
		guard case .encrypted(let encrypted) = packet.payloadVariant else {
			// Already decoded or empty — pass through
			var fromRadio = FromRadio()
			fromRadio.payloadVariant = .packet(packet)
			streamContinuation?.yield(.data(fromRadio))
			return
		}

		// Find matching channel by channelId name
		let channelName = envelope.channelID
		guard let channel = findChannel(forName: channelName) else {
			Logger.mqtt.debug("[MQTT Virtual] No matching channel for '\(channelName, privacy: .public)'")
			return
		}

		// Decrypt
		guard let plaintext = MeshtasticCrypto.decrypt(
			encrypted: encrypted,
			psk: channel.psk,
			packetId: packet.id,
			fromNode: packet.from
		) else {
			Logger.mqtt.debug("[MQTT Virtual] Decryption failed for packet \(packet.id)")
			return
		}

		// Decode the inner Data message
		guard let decoded = try? DataMessage(serializedBytes: plaintext) else {
			Logger.mqtt.debug("[MQTT Virtual] Failed to decode DataMessage from decrypted payload")
			return
		}

		packet.payloadVariant = .decoded(decoded)
		// Set the channel index so the app knows which channel this came from
		packet.channel = UInt32(channel.index)

		var fromRadio = FromRadio()
		fromRadio.payloadVariant = .packet(packet)
		streamContinuation?.yield(.data(fromRadio))
	}

	private func findChannel(forName name: String) -> VirtualChannel? {
		// Primary channel has empty name but uses "LongFast" on MQTT
		if let ch = channels.first(where: {
			let chName = $0.name.isEmpty ? "LongFast" : $0.name
			return chName == name
		}) {
			return ch
		}
		// Fallback: try matching by channel hash
		return nil
	}
}

// MARK: - Delegate Bridge

enum MQTTVirtualDelegateEvent: Sendable {
	case connected
	case disconnected(Error?)
	case message(String, [UInt8])
}

class MQTTVirtualDelegate: NSObject, CocoaMQTTDelegate, @unchecked Sendable {
	private let handler: @Sendable (MQTTVirtualDelegateEvent) -> Void

	init(handler: @escaping @Sendable (MQTTVirtualDelegateEvent) -> Void) {
		self.handler = handler
	}

	func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
		if ack == .accept {
			handler(.connected)
		} else {
			handler(.disconnected(ConnectionError.ioError("MQTT connect rejected: \(ack)")))
		}
	}

	func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
		handler(.disconnected(err))
	}

	func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
		handler(.message(message.topic, message.payload))
	}

	func mqtt(_ mqtt: CocoaMQTT, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
		completionHandler(true)
	}

	func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
	func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
	func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
	func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
	func mqttDidPing(_ mqtt: CocoaMQTT) {}
	func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
}

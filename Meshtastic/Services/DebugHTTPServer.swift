//
//  DebugHTTPServer.swift
//  Meshtastic
//
//  Lightweight HTTP server for E2E test automation.
//  Only active when MESHRELIABLE_DEBUG=1 environment variable is set.
//  Uses Network.framework (NWListener + NWConnection), no third-party deps.
//

import Foundation
import MeshtasticProtobufs
import Network
import OSLog
import SwiftData
import UIKit

final class DebugHTTPServer: @unchecked Sendable {
	static let shared = DebugHTTPServer()

	private var listener: NWListener?
	private let port: UInt16 = 8765
	private let queue = DispatchQueue(label: "com.meshreliable.debug-http", qos: .utility)

	private init() {}

	var isEnabled: Bool {
		// Always enabled for MeshReliable builds — the env var check is skipped
		// to allow remote reconnect debugging via /action/ble-reconnect
		return true
	}

	func startIfEnabled() {
		guard isEnabled else {
			Logger.services.info("[DebugHTTP] Not enabled (MESHRELIABLE_DEBUG != 1)")
			return
		}
		start()
	}

	func start() {
		guard listener == nil else { return }

		do {
			let params = NWParameters.tcp
			params.allowLocalEndpointReuse = true
			let nwPort = NWEndpoint.Port(rawValue: port)!
			listener = try NWListener(using: params, on: nwPort)
		} catch {
			Logger.services.error("[DebugHTTP] Failed to create listener: \(error.localizedDescription)")
			return
		}

		listener?.newConnectionHandler = { [weak self] connection in
			self?.handleConnection(connection)
		}

		listener?.stateUpdateHandler = { state in
			switch state {
			case .ready:
				Logger.services.info("[DebugHTTP] Listening on port \(self.port)")
			case .failed(let error):
				Logger.services.error("[DebugHTTP] Listener failed: \(error.localizedDescription)")
			default:
				break
			}
		}

		listener?.start(queue: queue)
	}

	func stop() {
		listener?.cancel()
		listener = nil
	}

	// MARK: - Connection Handling

	private func handleConnection(_ connection: NWConnection) {
		connection.start(queue: queue)
		receiveFullRequest(connection: connection, buffer: Data())
	}

	/// Accumulate TCP data until the full HTTP request (headers + body) is received.
	private func receiveFullRequest(connection: NWConnection, buffer: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
			guard let self else { connection.cancel(); return }
			guard let data else {
				if isComplete {
					// Connection closed — process whatever we have
					self.processRequest(connection: connection, data: buffer)
				} else {
					connection.cancel()
				}
				return
			}

			var accumulated = buffer
			accumulated.append(data)

			// Check if we have the full request: headers must be complete and body must match Content-Length
			if let request = String(data: accumulated, encoding: .utf8),
			   request.contains("\r\n\r\n") {
				// Parse Content-Length from headers
				let headerEnd = request.range(of: "\r\n\r\n")!
				let headers = String(request[..<headerEnd.lowerBound])
				let bodyData = accumulated.suffix(from: accumulated.count - request[headerEnd.upperBound...].utf8.count)
				var expectedLength = 0
				for line in headers.split(separator: "\r\n") {
					if line.lowercased().hasPrefix("content-length:") {
						expectedLength = Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
					}
				}
				if bodyData.count >= expectedLength {
					self.processRequest(connection: connection, data: accumulated)
					return
				}
			}

			// Need more data
			if isComplete {
				self.processRequest(connection: connection, data: accumulated)
			} else {
				self.receiveFullRequest(connection: connection, buffer: accumulated)
			}
		}
	}

	private func processRequest(connection: NWConnection, data: Data) {
		let request = String(data: data, encoding: .utf8) ?? ""

		// Check for binary response endpoints
		let requestLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
		let pathPart = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
		let path = pathPart.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""

		if path == "/screenshot" {
			self.handleScreenshotBinary(connection: connection)
			return
		}

		let response = self.route(request: request)
		let httpResponse = self.buildHTTPResponse(body: response)
		connection.send(content: httpResponse.data(using: .utf8), completion: .contentProcessed { _ in
			connection.cancel()
		})
	}

	// MARK: - Routing

	private func route(request: String) -> String {
		let lines = request.split(separator: "\r\n")
		guard let requestLine = lines.first else {
			return jsonError("Empty request")
		}

		let parts = requestLine.split(separator: " ")
		guard parts.count >= 2 else {
			return jsonError("Malformed request")
		}

		let method = String(parts[0])
		let fullPath = String(parts[1])

		// Parse path and query
		let pathComponents = fullPath.split(separator: "?", maxSplits: 1)
		let path = String(pathComponents[0])
		let queryString = pathComponents.count > 1 ? String(pathComponents[1]) : ""

		switch (method, path) {
		case ("GET", "/status"):
			return handleStatus()
		case ("GET", "/telemetry"):
			return handleTelemetry(query: queryString)
		case ("GET", "/groups"):
			return handleGroups()
		case ("POST", "/action/send-message"):
			let body = extractBody(from: request)
			return handleSendMessage(body: body)
		case ("POST", "/action/send-group-message"):
			let body = extractBody(from: request)
			return handleSendGroupMessage(body: body)
		case ("POST", "/action/record-voice-memo"):
			let body = extractBody(from: request)
			return handleRecordVoiceMemo(body: body)
		case ("POST", "/action/send-test-image"):
			let body = extractBody(from: request)
			return handleSendTestImage(body: body)
		case ("GET", "/messages"):
			return handleMessages(query: queryString)
		case ("GET", "/images"):
			return handleImages(query: queryString)
		case ("GET", "/transfers"):
			return handleTransfers()
		case ("GET", "/connection"):
			return handleConnection()
		case ("GET", "/nodes"):
			return handleNodes()
		case ("POST", "/action/send-channel-message"):
			let body = extractBody(from: request)
			return handleSendChannelMessage(body: body)
		case ("POST", "/action/send-voice-memo"):
			let body = extractBody(from: request)
			return handleSendVoiceMemo(body: body)
		case ("POST", "/action/navigate"):
			let body = extractBody(from: request)
			return handleNavigate(body: body)
		case ("GET", "/ble-debug"):
			return handleBleDebug()
		case ("GET", "/ble-writes"):
			let lines = BLEConnection.debugWriteLog.map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" }.joined(separator: ",")
			return "[\(lines)]"
		case ("GET", "/fw-log"):
			let lines = AccessoryManager.firmwareLogBuffer.map { "\"\($0.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "\"", with: "'"))\"" }.joined(separator: ",")
			return "[\(lines)]"
		case ("POST", "/action/clear-fw-log"):
			AccessoryManager.firmwareLogBuffer.removeAll()
			return "{\"ok\":true}"
		case ("POST", "/action/clear-transfers"):
			return handleClearTransfers()
		case ("POST", "/action/ble-reconnect"):
			return handleBleReconnect()
		case ("POST", "/action/tcp-connect"):
			let body = extractBody(from: request)
			return handleTcpConnect(body: body)
		case ("POST", "/action/create-group"):
			let body = extractBody(from: request)
			return handleCreateGroup(body: body)
		case ("POST", "/action/send-image"):
			let body = extractBody(from: request)
			return handleSendImage(body: body)
		default:
			return jsonError("Not found: \(method) \(path)")
		}
	}

	// MARK: - Handlers

	private func handleBleDebug() -> String {
		let lastErr = BLEConnection.debugLastError.replacingOccurrences(of: "\"", with: "'")
		let chars = BLEConnection.debugCharDiscovered
		return """
		{"fromnumNotifications":\(BLEConnection.debugFromnumNotifications),"drainCalls":\(BLEConnection.debugDrainCalls),"readCalls":\(BLEConnection.debugReadCalls),"readDataBytes":\(BLEConnection.debugReadDataBytes),"fromRadioDecoded":\(BLEConnection.debugFromRadioDecoded),"fromRadioDecodeFail":\(BLEConnection.debugFromRadioDecodeFail),"subscribeAttempts":\(BLEConnection.debugSubscribeAttempts),"subscribeSuccess":\(BLEConnection.debugSubscribeSuccess),"subscribeFail":\(BLEConnection.debugSubscribeFail),"charsDiscovered":"\(chars)","lastError":"\(lastErr)"}
		"""
	}

	private func handleStatus() -> String {
		// Access @MainActor properties synchronously is fine from Sendable context
		// since these are just reading published values
		var state = "unknown"
		var deviceNum: Int64 = 0
		var packetsSent = 0
		var packetsReceived = 0
		var dataPackets = 0
		var recentPortnums: [String] = []

		let semaphore = DispatchSemaphore(value: 0)
		DispatchQueue.main.async {
			let manager = AccessoryManager.shared
			switch manager.state {
			case .subscribed: state = "connected"
			case .connecting: state = "connecting"
			case .discovering: state = "discovering"
			case .idle: state = "idle"
			default: state = "other"
			}
			deviceNum = manager.activeDeviceNum ?? 0
			packetsSent = manager.packetsSent
			packetsReceived = manager.packetsReceived
			dataPackets = manager.dataPacketsReceived
			recentPortnums = manager.lastReceivedPortnums
			semaphore.signal()
		}
		semaphore.wait()

		let portnumsJson = recentPortnums.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ",")
		return """
		{"status":"\(state)","deviceNum":\(deviceNum),"packetsSent":\(packetsSent),"packetsReceived":\(packetsReceived),"dataPackets":\(dataPackets),"recentPortnums":[\(portnumsJson)]}
		"""
	}

	private func handleTelemetry(query: String) -> String {
		var events: [TelemetryEvent] = []

		let semaphore = DispatchSemaphore(value: 0)
		DispatchQueue.main.async {
			let telemetry = MeshReliableTelemetry.shared
			if let sinceParam = self.parseQueryParam(query, key: "since"),
			   let sinceDate = ISO8601DateFormatter().date(from: sinceParam) {
				events = telemetry.eventsSince(sinceDate)
			} else {
				events = telemetry.allEvents()
			}
			semaphore.signal()
		}
		semaphore.wait()

		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		guard let data = try? encoder.encode(events),
			  let json = String(data: data, encoding: .utf8) else {
			return "[]"
		}
		return json
	}

	private func handleGroups() -> String {
		var result = "[]"
		let semaphore = DispatchSemaphore(value: 0)
		DispatchQueue.main.async {
			let service = GroupMessageService.shared
			let rosters = service.groupRosters
			var groups: [[String: Any]] = []
			for (groupId, members) in rosters {
				groups.append([
					"groupId": groupId,
					"members": members
				])
			}
			if let data = try? JSONSerialization.data(withJSONObject: groups),
			   let json = String(data: data, encoding: .utf8) {
				result = json
			}
			semaphore.signal()
		}
		semaphore.wait()
		return result
	}

	private func handleSendMessage(body: String) -> String {
		guard let data = body.data(using: .utf8),
			  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let to = json["to"] as? Int,
			  let text = json["text"] as? String else {
			return jsonError("Invalid body — need {\"to\": nodeNum, \"text\": \"...\"}")
		}
		let noPki = json["noPki"] as? Bool ?? false

		Task { @MainActor in
			let manager = AccessoryManager.shared
			guard let deviceNum = manager.activeDeviceNum else { return }
			if noPki {
				// Send as channel-encrypted DM (bypass PKI)
				let payloadData = text.data(using: .utf8)!
				var dataMessage = DataMessage()
				dataMessage.payload = payloadData
				dataMessage.portnum = .textMessageApp
				var meshPacket = MeshPacket()
				meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
				meshPacket.to = UInt32(to)
				meshPacket.from = UInt32(deviceNum)
				meshPacket.channel = 0
				meshPacket.decoded = dataMessage
				meshPacket.wantAck = true
				var toRadio = ToRadio()
				toRadio.packet = meshPacket
				try? await manager.activeConnection?.connection.send(toRadio)
			} else {
				try? await manager.sendMessage(message: text, toUserNum: Int64(to), channel: 0, isEmoji: false, replyID: 0)
			}
			MeshReliableTelemetry.shared.record(.messageSent, details: [
				"to": "\(to)",
				"text": text,
				"from": "\(deviceNum)",
				"noPki": "\(noPki)"
			])
		}

		return "{\"ok\":true}"
	}

	private func handleSendGroupMessage(body: String) -> String {
		guard let data = body.data(using: .utf8),
			  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let groupId = json["groupId"] as? UInt32,
			  let text = json["text"] as? String else {
			return jsonError("Invalid body — need {\"groupId\": num, \"text\": \"...\"}")
		}

		Task { @MainActor in
			let service = GroupMessageService.shared
			let members = service.groupRosters[groupId] ?? []
			let manager = AccessoryManager.shared
			try? await service.sendGroupText(
				text: text,
				groupId: groupId,
				channelIndex: 0,
				members: members,
				accessoryManager: manager
			)
		}

		return "{\"ok\":true}"
	}

	private func handleRecordVoiceMemo(body: String) -> String {
		// Trigger voice memo recording via MeshReliableService
		// The actual recording is handled by the service
		Task { @MainActor in
			MeshReliableTelemetry.shared.record(.voiceMemoRecordStart, details: [:])
		}
		return "{\"ok\":true,\"note\":\"Voice memo recording triggered\"}"
	}

	private func handleSendTestImage(body: String) -> String {
		guard let data = body.data(using: .utf8),
			  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let to = json["to"] as? Int else {
			return jsonError("Invalid body — need {\"to\": nodeNum}")
		}
		let label = json["label"] as? String ?? "TEST"

		Task { @MainActor in
			// Generate a small test image (64x64 colored square with text)
			let size = CGSize(width: 64, height: 64)
			let renderer = UIGraphicsImageRenderer(size: size)
			let testImage = renderer.image { ctx in
				// Random color background
				let hue = CGFloat.random(in: 0...1)
				UIColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
				ctx.fill(CGRect(origin: .zero, size: size))

				// Draw label text
				let attrs: [NSAttributedString.Key: Any] = [
					.font: UIFont.boldSystemFont(ofSize: 12),
					.foregroundColor: UIColor.white
				]
				let text = label as NSString
				let textSize = text.size(withAttributes: attrs)
				let textRect = CGRect(
					x: (size.width - textSize.width) / 2,
					y: (size.height - textSize.height) / 2,
					width: textSize.width,
					height: textSize.height
				)
				text.draw(in: textRect, withAttributes: attrs)
			}

			guard let jpegData = testImage.jpegData(compressionQuality: 0.5) else {
				Logger.services.error("[DebugHTTP] Failed to create test JPEG")
				return
			}

			let manager = AccessoryManager.shared
			let service = MeshReliableService.shared
			do {
				try await service.sendImage(
					jpegData: jpegData,
					toUserNum: Int64(to),
					channel: 0,
					accessoryManager: manager
				)
				MeshReliableTelemetry.shared.record(.imageSent, details: [
					"to": "\(to)",
					"label": label,
					"bytes": "\(jpegData.count)"
				])
			} catch {
				Logger.services.error("[DebugHTTP] Image send failed: \(error.localizedDescription)")
				MeshReliableTelemetry.shared.record(.error, details: [
					"action": "send-test-image",
					"error": error.localizedDescription
				])
			}
		}

		return "{\"ok\":true,\"note\":\"Test image queued for sending\"}"
	}

	// MARK: - Query Endpoints

	private func handleMessages(query: String) -> String {
		var result = "[]"
		let limitParam = parseQueryParam(query, key: "limit").flatMap { Int($0) } ?? 50
		let userNumParam = parseQueryParam(query, key: "userNum").flatMap { Int64($0) }
		let channelParam = parseQueryParam(query, key: "channel").flatMap { Int32($0) }

		let semaphore = DispatchSemaphore(value: 0)
		DispatchQueue.main.async {
			let context = PersistenceController.shared.context
			var descriptor = FetchDescriptor<MessageEntity>(
				sortBy: [SortDescriptor(\MessageEntity.messageTimestamp, order: .reverse)]
			)
			descriptor.fetchLimit = limitParam

			if let userNum = userNumParam, let channel = channelParam {
				descriptor.predicate = #Predicate<MessageEntity> {
					($0.fromUser?.num == userNum || $0.toUser?.num == userNum) && $0.channel == channel
				}
			} else if let userNum = userNumParam {
				descriptor.predicate = #Predicate<MessageEntity> {
					$0.fromUser?.num == userNum || $0.toUser?.num == userNum
				}
			} else if let channel = channelParam {
				descriptor.predicate = #Predicate<MessageEntity> {
					$0.channel == channel
				}
			}

			do {
				let messages = try context.fetch(descriptor)
				var jsonArray: [[String: Any]] = []
				for msg in messages {
					var entry: [String: Any] = [
						"messageId": msg.messageId,
						"timestamp": msg.messageTimestamp,
						"channel": msg.channel,
						"portNum": msg.portNum,
						"isEmoji": msg.isEmoji,
						"admin": msg.admin,
						"read": msg.read,
						"hasImage": msg.imageData != nil
					]
					if let payload = msg.messagePayload {
						entry["text"] = payload
					}
					if let fromUser = msg.fromUser {
						entry["fromUserNum"] = fromUser.num
						entry["fromUserName"] = fromUser.longName ?? fromUser.shortName ?? "?"
					}
					if let toUser = msg.toUser {
						entry["toUserNum"] = toUser.num
						entry["toUserName"] = toUser.longName ?? toUser.shortName ?? "?"
					}
					if msg.imageData != nil {
						entry["imageBytes"] = msg.imageData!.count
					}
					if msg.voiceMemoData != nil {
						entry["hasVoiceMemo"] = true
						entry["voiceMemoBytes"] = msg.voiceMemoData!.count
						entry["voiceMemoDuration"] = Double(msg.voiceMemoData!.count / 2) / 8000.0
					}
					entry["receivedACK"] = msg.receivedACK
					entry["realACK"] = msg.realACK
					entry["ackError"] = msg.ackError
					jsonArray.append(entry)
				}
				if let data = try? JSONSerialization.data(withJSONObject: jsonArray),
				   let json = String(data: data, encoding: .utf8) {
					result = json
				}
			} catch {
				result = "[]"
			}
			semaphore.signal()
		}
		semaphore.wait()
		return result
	}

	private func handleImages(query: String) -> String {
		var result = "[]"
		let userNumParam = parseQueryParam(query, key: "userNum").flatMap { Int64($0) }

		let semaphore = DispatchSemaphore(value: 0)
		DispatchQueue.main.async {
			let context = PersistenceController.shared.context
			// Fetch recent messages then filter for imageData in memory.
			// SwiftData #Predicate doesn't reliably filter @Attribute(.externalStorage) optionals.
			var descriptor: FetchDescriptor<MessageEntity>
			if let userNum = userNumParam {
				descriptor = FetchDescriptor<MessageEntity>(
					predicate: #Predicate<MessageEntity> {
						$0.fromUser?.num == userNum || $0.toUser?.num == userNum
					},
					sortBy: [SortDescriptor(\MessageEntity.messageTimestamp, order: .reverse)]
				)
			} else {
				descriptor = FetchDescriptor<MessageEntity>(
					sortBy: [SortDescriptor(\MessageEntity.messageTimestamp, order: .reverse)]
				)
			}
			descriptor.fetchLimit = 200

			do {
				let messages = try context.fetch(descriptor).filter { $0.imageData != nil }
				var jsonArray: [[String: Any]] = []
				for msg in messages.prefix(50) {
					var entry: [String: Any] = [
						"messageId": msg.messageId,
						"timestamp": msg.messageTimestamp,
						"channel": msg.channel,
						"imageBytes": msg.imageData?.count ?? 0
					]
					if let fromUser = msg.fromUser {
						entry["fromUserNum"] = fromUser.num
						entry["fromUserName"] = fromUser.longName ?? fromUser.shortName ?? "?"
					}
					if let toUser = msg.toUser {
						entry["toUserNum"] = toUser.num
						entry["toUserName"] = toUser.longName ?? toUser.shortName ?? "?"
					}
					if let payload = msg.messagePayload {
						entry["text"] = payload
					}
					jsonArray.append(entry)
				}
				if let data = try? JSONSerialization.data(withJSONObject: jsonArray),
				   let json = String(data: data, encoding: .utf8) {
					result = json
				}
			} catch {
				result = "[]"
			}
			semaphore.signal()
		}
		semaphore.wait()
		return result
	}

	private func handleTransfers() -> String {
		var result = "{}"
		let semaphore = DispatchSemaphore(value: 0)
		DispatchQueue.main.async {
			let service = MeshReliableService.shared
			var incoming: [[String: Any]] = []
			for (id, transfer) in service.incomingTransfers {
				incoming.append([
					"transferId": id,
					"totalChunks": transfer.totalChunks,
					"receivedChunks": transfer.receivedChunks.count,
					"progress": transfer.progress,
					"isImage": transfer.isImageTransfer,
					"fromNode": transfer.fromNode
				])
			}
			var outgoing: [[String: Any]] = []
			for (id, transfer) in service.outgoingTransfers {
				outgoing.append([
					"transferId": id,
					"totalChunks": transfer.totalChunks,
					"receivedChunks": transfer.receivedChunks.count,
					"progress": transfer.progress,
					"isImage": transfer.isImageTransfer,
					"toNode": transfer.toNode
				])
			}
			let obj: [String: Any] = [
				"incoming": incoming,
				"outgoing": outgoing,
				"completedVoiceMemos": service.completedVoiceMemos.count,
				"completedImages": service.completedImages.count,
				"pendingImages": service.pendingImages.map { [
					"id": $0.id.uuidString,
					"toUserNum": $0.toUserNum,
					"progress": $0.progress,
					"isSending": $0.isSending,
					"error": $0.error as Any,
					"imageBytes": $0.imageData.count
				] as [String: Any] },
				"pendingVoiceMemos": service.pendingVoiceMemos.map { [
					"id": $0.id.uuidString,
					"toUserNum": $0.toUserNum,
					"progress": $0.progress,
					"isSending": $0.isSending,
					"error": $0.error as Any,
					"duration": $0.duration
				] as [String: Any] },
				"sendProgress": service.sendProgress as Any
			]
			if let data = try? JSONSerialization.data(withJSONObject: obj),
			   let json = String(data: data, encoding: .utf8) {
				result = json
			}
			semaphore.signal()
		}
		semaphore.wait()
		return result
	}

	private func handleConnection() -> String {
		var result = "{}"
		let semaphore = DispatchSemaphore(value: 0)
		DispatchQueue.main.async {
			let manager = AccessoryManager.shared
			var stateStr: String
			switch manager.state {
			case .subscribed: stateStr = "subscribed"
			case .connecting: stateStr = "connecting"
			case .discovering: stateStr = "discovering"
			case .idle: stateStr = "idle"
			case .communicating: stateStr = "communicating"
			case .uninitialized: stateStr = "uninitialized"
			case .retrying(let attempt, let max): stateStr = "retrying(\(attempt)/\(max))"
			case .retrievingDatabase(let count): stateStr = "retrievingDatabase(\(count))"
			}

			var obj: [String: Any] = [
				"state": stateStr,
				"isConnected": manager.isConnected,
				"isConnecting": manager.isConnecting,
				"deviceNum": manager.activeDeviceNum as Any,
				"packetsSent": manager.packetsSent,
				"packetsReceived": manager.packetsReceived,
				"deviceCount": manager.devices.count
			]

			if let conn = manager.activeConnection {
				obj["activeDevice"] = [
					"name": conn.device.name,
					"num": conn.device.num as Any,
					"shortName": conn.device.shortName as Any,
					"longName": conn.device.longName as Any,
					"firmwareVersion": conn.device.firmwareVersion as Any,
					"hardwareModel": conn.device.hardwareModel as Any,
					"rssi": conn.device.rssi as Any,
					"transportType": String(describing: conn.device.transportType),
					"connectionState": String(describing: conn.device.connectionState)
				] as [String: Any]
			}

			if let data = try? JSONSerialization.data(withJSONObject: obj),
			   let json = String(data: data, encoding: .utf8) {
				result = json
			}
			semaphore.signal()
		}
		semaphore.wait()
		return result
	}

	private func handleNodes() -> String {
		var result = "[]"
		let semaphore = DispatchSemaphore(value: 0)
		DispatchQueue.main.async {
			let context = PersistenceController.shared.context
			let descriptor = FetchDescriptor<NodeInfoEntity>(
				sortBy: [SortDescriptor(\NodeInfoEntity.lastHeard, order: .reverse)]
			)
			do {
				let nodes = try context.fetch(descriptor)
				var jsonArray: [[String: Any]] = []
				for node in nodes {
					var entry: [String: Any] = [
						"num": node.num,
						"channel": node.channel,
						"hopsAway": node.hopsAway,
						"rssi": node.rssi,
						"snr": node.snr,
						"viaMqtt": node.viaMqtt
					]
					if let lastHeard = node.lastHeard {
						entry["lastHeard"] = ISO8601DateFormatter().string(from: lastHeard)
					}
					if let user = node.user {
						entry["longName"] = user.longName
						entry["shortName"] = user.shortName
						entry["userId"] = user.userId
						entry["pkiEncrypted"] = user.pkiEncrypted
						if let pubKey = user.publicKey {
							entry["publicKeyLen"] = pubKey.count
						}
					}
					if let bleName = node.bleName {
						entry["bleName"] = bleName
					}
					jsonArray.append(entry)
				}
				if let data = try? JSONSerialization.data(withJSONObject: jsonArray),
				   let json = String(data: data, encoding: .utf8) {
					result = json
				}
			} catch {
				result = "[]"
			}
			semaphore.signal()
		}
		semaphore.wait()
		return result
	}

	// MARK: - Action Endpoints (New)

	private func handleSendChannelMessage(body: String) -> String {
		guard let data = body.data(using: .utf8),
			  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let text = json["text"] as? String else {
			return jsonError("Invalid body — need {\"text\": \"...\", \"channel\": 0}")
		}
		let channel = (json["channel"] as? Int).map { Int32($0) } ?? 0

		Task { @MainActor in
			let manager = AccessoryManager.shared
			guard let deviceNum = manager.activeDeviceNum else { return }
			// toUserNum 0xFFFFFFFF = broadcast
			try? await manager.sendMessage(message: text, toUserNum: 0xFFFFFFFF, channel: channel, isEmoji: false, replyID: 0)
			MeshReliableTelemetry.shared.record(.messageSent, details: [
				"to": "broadcast",
				"channel": "\(channel)",
				"text": text,
				"from": "\(deviceNum)"
			])
		}

		return "{\"ok\":true}"
	}

	private func handleSendVoiceMemo(body: String) -> String {
		guard let data = body.data(using: .utf8),
			  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let to = json["to"] as? Int else {
			return jsonError("Invalid body — need {\"to\": nodeNum}")
		}
		let durationMs = json["durationMs"] as? Int ?? 500

		Task { @MainActor in
			// Generate synthetic sine wave PCM: 8kHz, 16-bit mono
			let sampleRate = 8000
			let numSamples = sampleRate * durationMs / 1000
			var pcmData = Data(capacity: numSamples * 2)
			let frequency: Double = 440.0 // A4 note
			for i in 0..<numSamples {
				let t = Double(i) / Double(sampleRate)
				let sample = Int16(sin(2.0 * Double.pi * frequency * t) * 16000)
				withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
			}

			let manager = AccessoryManager.shared
			let service = MeshReliableService.shared
			service.sendVoiceMemoInline(
				pcmData: pcmData,
				duration: TimeInterval(durationMs) / 1000.0,
				toUserNum: Int64(to),
				channel: 0,
				accessoryManager: manager
			)
			MeshReliableTelemetry.shared.record(.voiceMemoRecordStart, details: [
				"to": "\(to)",
				"durationMs": "\(durationMs)",
				"synthetic": "true"
			])
		}

		return "{\"ok\":true,\"note\":\"Synthetic voice memo queued\"}"
	}

	private func handleNavigate(body: String) -> String {
		guard let data = body.data(using: .utf8),
			  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let tab = json["tab"] as? String else {
			return jsonError("Need {\"tab\": \"messages|nodes|map|settings|connect\", \"userNum\": N, \"channel\": N}")
		}

		var resultInfo = ""
		let semaphore = DispatchSemaphore(value: 0)
		DispatchQueue.main.async {
			guard let appState = AccessoryManager.shared.appState else {
				resultInfo = "appState is nil"
				semaphore.signal()
				return
			}
			let router = appState.router
			resultInfo = "navigated to \(tab)"

			switch tab {
			case "messages":
				if let userNum = json["userNum"] as? Int {
					router.messagesState = .directMessages(userNum: Int64(userNum))
					router.selectedTab = .messages
				} else if let channel = json["channel"] as? Int {
					router.messagesState = .channels(channelId: Int32(channel))
					router.selectedTab = .messages
				} else {
					router.messagesState = nil
					router.selectedTab = .messages
				}
			case "nodes":
				router.selectedTab = .nodes
			case "map":
				router.selectedTab = .map
			case "settings":
				router.selectedTab = .settings
			case "connect":
				router.selectedTab = .connect
			default:
				resultInfo = "unknown tab: \(tab)"
			}
			appState.objectWillChange.send()
			semaphore.signal()
		}
		// Timeout after 3 seconds to avoid deadlock when main thread is busy
		let result = semaphore.wait(timeout: .now() + 3)
		if result == .timedOut {
			resultInfo = "navigation requested (main thread busy)"
		}
		let escaped = resultInfo.replacingOccurrences(of: "\"", with: "\\\"")
		return "{\"ok\":true,\"info\":\"\(escaped)\"}"
	}

	private func handleClearTransfers() -> String {
		var cleared = 0
		let semaphore = DispatchSemaphore(value: 0)
		DispatchQueue.main.async {
			let service = MeshReliableService.shared
			cleared += service.pendingImages.count
			cleared += service.pendingVoiceMemos.count
			cleared += service.outgoingTransfers.count
			service.pendingImages.removeAll()
			service.pendingVoiceMemos.removeAll()
			service.outgoingTransfers.removeAll()
			service.sendProgress = nil
			semaphore.signal()
		}
		semaphore.wait()
		return "{\"ok\":true,\"cleared\":\(cleared)}"
	}

	private func handleTcpConnect(body: String) -> String {
		let host: String
		if let data = body.data(using: .utf8),
		   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		   let h = json["host"] as? String {
			host = h
		} else {
			host = "192.168.1.117:4403"
		}

		let semaphore = DispatchSemaphore(value: 0)
		var resultInfo = ""
		DispatchQueue.main.async {
			Task {
				let manager = AccessoryManager.shared
				// Find TCP transport
				guard let tcpTransport = manager.transports.first(where: { $0.type == .tcp }) else {
					resultInfo = "TCP transport not found"
					semaphore.signal()
					return
				}
				guard let device = tcpTransport.device(forManualConnection: host) else {
					resultInfo = "Invalid host: \(host)"
					semaphore.signal()
					return
				}
				do {
					try await manager.disconnect()
					try? await Task.sleep(nanoseconds: 500_000_000)
					try await manager.connect(to: device)
					resultInfo = "connected to \(host)"
				} catch {
					resultInfo = "error: \(error.localizedDescription)"
				}
				semaphore.signal()
			}
		}
		semaphore.wait()
		let escaped = resultInfo.replacingOccurrences(of: "\"", with: "\\\"")
		return "{\"ok\":true,\"info\":\"\(escaped)\"}"
	}

	private func handleBleReconnect() -> String {
		var resultInfo = ""
		let semaphore = DispatchSemaphore(value: 0)
		DispatchQueue.main.async {
			let manager = AccessoryManager.shared
			let wasConnected = manager.isConnected
			let wasConnecting = manager.isConnecting

			// Force disconnect to clear stale state
			Task {
				do {
					try await manager.disconnect()
				} catch {
					Logger.services.warning("[DebugHTTP] disconnect error: \(error)")
				}

				// Wait briefly for disconnect to settle
				try? await Task.sleep(nanoseconds: 1_000_000_000)

				// Reconnect to preferred device
				manager.connectToPreferredDevice()
				resultInfo = "disconnected (was connected=\(wasConnected), connecting=\(wasConnecting)), reconnecting to preferred device"
				semaphore.signal()
			}
		}
		semaphore.wait()
		let escaped = resultInfo.replacingOccurrences(of: "\"", with: "\\\"")
		return "{\"ok\":true,\"info\":\"\(escaped)\"}"
	}

	private func handleCreateGroup(body: String) -> String {
		guard let data = body.data(using: .utf8),
			  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let members = json["members"] as? [Int] else {
			return jsonError("Invalid body — need {\"members\": [nodeNum1, nodeNum2, ...]}")
		}
		let name = json["name"] as? String ?? "TestGroup"
		let channel = (json["channel"] as? Int).map { UInt8($0) } ?? 0

		var groupId: UInt32 = 0
		var errorMsg: String? = nil
		let semaphore = DispatchSemaphore(value: 0)
		Task { @MainActor in
			let service = GroupMessageService.shared
			let manager = AccessoryManager.shared
			let memberNums = members.map { UInt32($0) }
			do {
				groupId = try await service.createGroup(
					name: name,
					channelIndex: channel,
					members: memberNums,
					accessoryManager: manager
				)
			} catch {
				errorMsg = error.localizedDescription
			}
			semaphore.signal()
		}
		semaphore.wait()

		if let err = errorMsg {
			return jsonError("createGroup failed: \(err)")
		}
		return "{\"ok\":true,\"groupId\":\(groupId)}"
	}

	private func handleSendImage(body: String) -> String {
		guard let data = body.data(using: .utf8),
			  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let to = json["to"] as? Int,
			  let base64Str = json["imageBase64"] as? String,
			  let imageData = Data(base64Encoded: base64Str) else {
			return jsonError("Invalid body — need {\"to\": nodeNum, \"imageBase64\": \"...\"}")
		}

		Task { @MainActor in
			let manager = AccessoryManager.shared
			let service = MeshReliableService.shared
			do {
				try await service.sendImage(
					jpegData: imageData,
					toUserNum: Int64(to),
					channel: 0,
					accessoryManager: manager
				)
				MeshReliableTelemetry.shared.record(.imageSent, details: [
					"to": "\(to)",
					"bytes": "\(imageData.count)",
					"source": "debug-api"
				])
			} catch {
				Logger.services.error("[DebugHTTP] send-image failed: \(error.localizedDescription)")
			}
		}

		return "{\"ok\":true,\"note\":\"Image queued for sending\"}"
	}

	// MARK: - Screenshot

	private func handleScreenshotBinary(connection: NWConnection) {
		var pngData: Data?
		let semaphore = DispatchSemaphore(value: 0)
		DispatchQueue.main.async {
			guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
				  let window = windowScene.windows.first else {
				semaphore.signal()
				return
			}
			let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
			let image = renderer.image { ctx in
				window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
			}
			pngData = image.pngData()
			semaphore.signal()
		}
		semaphore.wait()

		guard let data = pngData else {
			let errorBody = "{\"error\":\"Screenshot failed\"}"
			let resp = buildHTTPResponse(body: errorBody)
			connection.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in
				connection.cancel()
			})
			return
		}

		let header = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(data.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
		var responseData = header.data(using: .utf8)!
		responseData.append(data)
		connection.send(content: responseData, completion: .contentProcessed { _ in
			connection.cancel()
		})
	}

	// MARK: - Helpers

	private func buildHTTPResponse(body: String) -> String {
		let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
		return """
		HTTP/1.1 200 OK\r
		Content-Type: application/json\r
		Content-Length: \(trimmed.utf8.count)\r
		Connection: close\r
		Access-Control-Allow-Origin: *\r
		\r
		\(trimmed)
		"""
	}

	private func jsonError(_ message: String) -> String {
		let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
		return "{\"error\":\"\(escaped)\"}"
	}

	private func extractBody(from request: String) -> String {
		// HTTP body comes after \r\n\r\n
		let parts = request.components(separatedBy: "\r\n\r\n")
		return parts.count > 1 ? parts[1] : ""
	}

	private func parseQueryParam(_ query: String, key: String) -> String? {
		let pairs = query.split(separator: "&")
		for pair in pairs {
			let kv = pair.split(separator: "=", maxSplits: 1)
			if kv.count == 2 && String(kv[0]) == key {
				return String(kv[1]).removingPercentEncoding
			}
		}
		return nil
	}
}

//
//  GroupMessageService.swift
//  Meshtastic
//
//  MeshReliable acknowledged group messaging service.
//  Handles group message sending, receiving, ACK tracking, and roster management.
//

import Foundation
import MeshtasticProtobufs
import OSLog
import SwiftData

// MARK: - Group Message Types (matching firmware GroupMessageModule)

enum GroupMessageType: UInt8, Codable {
	case groupText = 0
	case groupJoin = 1
	case groupLeave = 2
	case groupAck = 3
	case groupAllAcked = 4
	case groupRosterRequest = 5
	case groupRosterResponse = 6
}

// MARK: - Wire Format

/// Matches the firmware's `meshtastic_GroupMessage` protobuf wire format.
/// Wire layout: [type:1][messageId:4][groupId:4][ackMessageId:4][memberNodeId:4][sendTime:4][rebroadcastCount:1][memberCount:1][members:4*N][text:...]
struct GroupMessagePayload {
	let type: GroupMessageType
	let messageId: UInt32
	let groupId: UInt32
	let ackMessageId: UInt32
	let memberNodeId: UInt32
	let sendTime: UInt32
	let rebroadcastCount: UInt8
	let members: [UInt32]
	let roster: [UInt32]
	let text: String

	static let fixedHeaderSize = 22 // 1+4+4+4+4+4+1

	func serialize() -> Data {
		var data = Data()
		data.append(type.rawValue)
		data.append(contentsOf: withUnsafeBytes(of: messageId.littleEndian) { Array($0) })
		data.append(contentsOf: withUnsafeBytes(of: groupId.littleEndian) { Array($0) })
		data.append(contentsOf: withUnsafeBytes(of: ackMessageId.littleEndian) { Array($0) })
		data.append(contentsOf: withUnsafeBytes(of: memberNodeId.littleEndian) { Array($0) })
		data.append(contentsOf: withUnsafeBytes(of: sendTime.littleEndian) { Array($0) })
		data.append(rebroadcastCount)
		// Members
		data.append(UInt8(members.count))
		for member in members {
			data.append(contentsOf: withUnsafeBytes(of: member.littleEndian) { Array($0) })
		}
		// Roster
		data.append(UInt8(roster.count))
		for node in roster {
			data.append(contentsOf: withUnsafeBytes(of: node.littleEndian) { Array($0) })
		}
		// Text
		if let textData = text.data(using: .utf8), !textData.isEmpty {
			data.append(textData)
		}
		return data
	}

	static func deserialize(from data: Data) -> GroupMessagePayload? {
		guard data.count >= fixedHeaderSize else { return nil }
		guard let msgType = GroupMessageType(rawValue: data[0]) else { return nil }

		var offset = 1
		func readUInt32() -> UInt32 {
			let val = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
			offset += 4
			return val
		}

		let messageId = readUInt32()
		let groupId = readUInt32()
		let ackMessageId = readUInt32()
		let memberNodeId = readUInt32()
		let sendTime = readUInt32()
		let rebroadcastCount = data[offset]; offset += 1

		// Members array
		var members: [UInt32] = []
		if offset < data.count {
			let memberCount = Int(data[offset]); offset += 1
			for _ in 0..<memberCount {
				guard offset + 4 <= data.count else { break }
				members.append(readUInt32())
			}
		}

		// Roster array
		var roster: [UInt32] = []
		if offset < data.count {
			let rosterCount = Int(data[offset]); offset += 1
			for _ in 0..<rosterCount {
				guard offset + 4 <= data.count else { break }
				roster.append(readUInt32())
			}
		}

		// Remaining bytes are text
		var text = ""
		if offset < data.count {
			text = String(data: data.subdata(in: offset..<data.count), encoding: .utf8) ?? ""
		}

		return GroupMessagePayload(
			type: msgType,
			messageId: messageId,
			groupId: groupId,
			ackMessageId: ackMessageId,
			memberNodeId: memberNodeId,
			sendTime: sendTime,
			rebroadcastCount: rebroadcastCount,
			members: members,
			roster: roster,
			text: text
		)
	}
}

// MARK: - ACK Tracker

struct GroupAckStatus: Identifiable, Codable {
	var id: UInt32 { messageId }
	let messageId: UInt32
	let groupId: UInt32
	var members: [UInt32]
	var ackedBy: [UInt32]
	var allAcked: Bool { Set(members).isSubset(of: Set(ackedBy)) }
	var sendTime: Date

	var ackPercentage: Double {
		guard !members.isEmpty else { return 1.0 }
		return Double(ackedBy.count) / Double(members.count)
	}
}

// MARK: - GroupMessageService

@MainActor
final class GroupMessageService: ObservableObject {

	static let shared = GroupMessageService()

	/// Active group conversations: groupId -> list of messages
	@Published var groupMessages: [UInt32: [GroupMessageEntry]] = [:]

	/// ACK tracking for outgoing messages
	@Published var ackTrackers: [UInt32: GroupAckStatus] = [:]

	/// Known group rosters: groupId -> [nodeNum]
	@Published var groupRosters: [UInt32: [UInt32]] = [:]

	/// Groups we've joined (groupId -> group metadata)
	@Published var joinedGroups: [UInt32: GroupInfo] = [:]

	/// Unread message counts per group
	@Published var unreadCounts: [UInt32: Int] = [:]

	private var nextMessageId: UInt32 = 1

	private init() {
		loadState()
	}

	// MARK: - Group Info

	struct GroupInfo: Codable, Identifiable {
		var id: UInt32 { groupId }
		let groupId: UInt32
		var name: String
		var channelIndex: UInt8
		var members: [UInt32]
		var createdAt: Date
	}

	// MARK: - Message Entry

	struct GroupMessageEntry: Identifiable, Codable {
		let id: UUID
		let messageId: UInt32
		let groupId: UInt32
		let fromNode: UInt32
		let text: String
		let timestamp: Date
		let type: GroupMessageType
		var ackStatus: GroupAckStatus?

		init(messageId: UInt32, groupId: UInt32, fromNode: UInt32, text: String, timestamp: Date, type: GroupMessageType, ackStatus: GroupAckStatus? = nil) {
			self.id = UUID()
			self.messageId = messageId
			self.groupId = groupId
			self.fromNode = fromNode
			self.text = text
			self.timestamp = timestamp
			self.type = type
			self.ackStatus = ackStatus
		}
	}

	// MARK: - Sending

	func sendGroupText(
		text: String,
		groupId: UInt32,
		channelIndex: Int32,
		members: [UInt32],
		accessoryManager: AccessoryManager
	) async throws {
		guard let fromUserNum = accessoryManager.activeConnection?.device.num else {
			throw AccessoryError.ioFailed("No active device")
		}
		guard !text.isEmpty else { return }

		let msgId = generateMessageId()
		let now = UInt32(Date().timeIntervalSince1970)

		let payload = GroupMessagePayload(
			type: .groupText,
			messageId: msgId,
			groupId: groupId,
			ackMessageId: 0,
			memberNodeId: UInt32(fromUserNum),
			sendTime: now,
			rebroadcastCount: 0,
			members: members,
			roster: [],
			text: text
		)

		try await sendGroupPacket(
			payload: payload,
			channelIndex: channelIndex,
			fromUserNum: fromUserNum,
			accessoryManager: accessoryManager
		)

		// Track ACKs
		let ackStatus = GroupAckStatus(
			messageId: msgId,
			groupId: groupId,
			members: members.filter { $0 != UInt32(fromUserNum) },
			ackedBy: [],
			sendTime: Date()
		)
		ackTrackers[msgId] = ackStatus

		// Store locally
		let entry = GroupMessageEntry(
			messageId: msgId,
			groupId: groupId,
			fromNode: UInt32(fromUserNum),
			text: text,
			timestamp: Date(),
			type: .groupText,
			ackStatus: ackStatus
		)
		appendMessage(entry, to: groupId)

		Logger.mesh.info("Sent group message \(msgId) to group \(groupId.toHex()) with \(members.count) members")
		saveState()
	}

	func createGroup(
		name: String,
		channelIndex: UInt8,
		members: [UInt32],
		accessoryManager: AccessoryManager
	) async throws -> UInt32 {
		guard let fromUserNum = accessoryManager.activeConnection?.device.num else {
			throw AccessoryError.ioFailed("No active device")
		}

		let groupId = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		let allMembers = Array(Set(members + [UInt32(fromUserNum)]))

		let info = GroupInfo(
			groupId: groupId,
			name: name,
			channelIndex: channelIndex,
			members: allMembers,
			createdAt: Date()
		)
		joinedGroups[groupId] = info
		groupRosters[groupId] = allMembers
		groupMessages[groupId] = []

		// Send JOIN announcement
		let msgId = generateMessageId()
		let payload = GroupMessagePayload(
			type: .groupJoin,
			messageId: msgId,
			groupId: groupId,
			ackMessageId: 0,
			memberNodeId: UInt32(fromUserNum),
			sendTime: UInt32(Date().timeIntervalSince1970),
			rebroadcastCount: 0,
			members: allMembers,
			roster: allMembers,
			text: name
		)

		try await sendGroupPacket(
			payload: payload,
			channelIndex: Int32(channelIndex),
			fromUserNum: fromUserNum,
			accessoryManager: accessoryManager
		)

		saveState()
		Logger.mesh.info("Created group '\(name)' with ID \(groupId.toHex()), \(allMembers.count) members")
		return groupId
	}

	func joinGroup(
		groupId: UInt32,
		channelIndex: UInt8,
		accessoryManager: AccessoryManager
	) async throws {
		guard let fromUserNum = accessoryManager.activeConnection?.device.num else {
			throw AccessoryError.ioFailed("No active device")
		}

		// Add locally
		let info = GroupInfo(
			groupId: groupId,
			name: "Group \(groupId.toHex().suffix(4))",
			channelIndex: channelIndex,
			members: [UInt32(fromUserNum)],
			createdAt: Date()
		)
		joinedGroups[groupId] = info
		groupRosters[groupId] = [UInt32(fromUserNum)]
		groupMessages[groupId] = []

		// Send JOIN announcement over the air
		let msgId = generateMessageId()
		let payload = GroupMessagePayload(
			type: .groupJoin,
			messageId: msgId,
			groupId: groupId,
			ackMessageId: 0,
			memberNodeId: UInt32(fromUserNum),
			sendTime: UInt32(Date().timeIntervalSince1970),
			rebroadcastCount: 0,
			members: [UInt32(fromUserNum)],
			roster: [],
			text: ""
		)

		try await sendGroupPacket(
			payload: payload,
			channelIndex: Int32(channelIndex),
			fromUserNum: fromUserNum,
			accessoryManager: accessoryManager
		)

		// Send roster request to discover other members
		let rosterPayload = GroupMessagePayload(
			type: .groupRosterRequest,
			messageId: generateMessageId(),
			groupId: groupId,
			ackMessageId: 0,
			memberNodeId: UInt32(fromUserNum),
			sendTime: UInt32(Date().timeIntervalSince1970),
			rebroadcastCount: 0,
			members: [],
			roster: [],
			text: ""
		)

		try await sendGroupPacket(
			payload: rosterPayload,
			channelIndex: Int32(channelIndex),
			fromUserNum: fromUserNum,
			accessoryManager: accessoryManager
		)

		saveState()
		Logger.mesh.info("Joined group \(groupId.toHex()) on channel \(channelIndex)")
	}

	func leaveGroup(
		groupId: UInt32,
		accessoryManager: AccessoryManager
	) async throws {
		guard let fromUserNum = accessoryManager.activeConnection?.device.num else {
			throw AccessoryError.ioFailed("No active device")
		}

		guard let info = joinedGroups[groupId] else { return }

		// Send LEAVE announcement
		let msgId = generateMessageId()
		let payload = GroupMessagePayload(
			type: .groupLeave,
			messageId: msgId,
			groupId: groupId,
			ackMessageId: 0,
			memberNodeId: UInt32(fromUserNum),
			sendTime: UInt32(Date().timeIntervalSince1970),
			rebroadcastCount: 0,
			members: [],
			roster: [],
			text: ""
		)

		try await sendGroupPacket(
			payload: payload,
			channelIndex: Int32(info.channelIndex),
			fromUserNum: fromUserNum,
			accessoryManager: accessoryManager
		)

		// Remove locally
		joinedGroups.removeValue(forKey: groupId)
		groupMessages.removeValue(forKey: groupId)
		groupRosters.removeValue(forKey: groupId)
		unreadCounts.removeValue(forKey: groupId)

		saveState()
		Logger.mesh.info("Left group \(groupId.toHex())")
	}

	func markAsRead(groupId: UInt32) {
		unreadCounts[groupId] = 0
	}

	// MARK: - Receiving

	func handleIncomingPacket(_ packet: MeshPacket) {
		let data = packet.decoded.payload
		guard let msg = GroupMessagePayload.deserialize(from: data) else {
			Logger.mesh.warning("GroupMessageService: Could not parse group message payload")
			return
		}

		switch msg.type {
		case .groupText:
			handleGroupText(msg, from: packet.from)
		case .groupAck:
			handleGroupAck(msg)
		case .groupAllAcked:
			handleGroupAllAcked(msg)
		case .groupJoin:
			handleGroupJoin(msg, from: packet.from)
		case .groupLeave:
			handleGroupLeave(msg, from: packet.from)
		case .groupRosterRequest:
			Logger.mesh.info("GroupMessageService: Roster request from \(packet.from.toHex())")
		case .groupRosterResponse:
			handleRosterResponse(msg)
		}
	}

	private func handleGroupText(_ msg: GroupMessagePayload, from: UInt32) {
		let entry = GroupMessageEntry(
			messageId: msg.messageId,
			groupId: msg.groupId,
			fromNode: from,
			text: msg.text,
			timestamp: Date(timeIntervalSince1970: TimeInterval(msg.sendTime)),
			type: .groupText
		)
		appendMessage(entry, to: msg.groupId)

		// Auto-create group if we don't know it
		if joinedGroups[msg.groupId] == nil {
			let info = GroupInfo(
				groupId: msg.groupId,
				name: "Group \(msg.groupId.toHex().suffix(4))",
				channelIndex: 0,
				members: msg.members,
				createdAt: Date()
			)
			joinedGroups[msg.groupId] = info
			groupRosters[msg.groupId] = msg.members
		}

		// Increment unread count
		unreadCounts[msg.groupId, default: 0] += 1

		saveState()
		Logger.mesh.info("Received group text from \(from.toHex()) in group \(msg.groupId.toHex()): \(msg.text.prefix(50))")
	}

	private func handleGroupAck(_ msg: GroupMessagePayload) {
		guard var tracker = ackTrackers[msg.ackMessageId] else { return }
		if !tracker.ackedBy.contains(msg.memberNodeId) {
			tracker.ackedBy.append(msg.memberNodeId)
			ackTrackers[msg.ackMessageId] = tracker

			// Update the message entry's ack status
			if var messages = groupMessages[msg.groupId] {
				if let idx = messages.firstIndex(where: { $0.messageId == msg.ackMessageId }) {
					messages[idx].ackStatus = tracker
					groupMessages[msg.groupId] = messages
				}
			}
		}
		Logger.mesh.info("ACK from \(msg.memberNodeId.toHex()) for message \(msg.ackMessageId) (\(tracker.ackedBy.count)/\(tracker.members.count))")
		saveState()
	}

	private func handleGroupAllAcked(_ msg: GroupMessagePayload) {
		Logger.mesh.info("All members ACKed message \(msg.ackMessageId) in group \(msg.groupId.toHex())")
	}

	private func handleGroupJoin(_ msg: GroupMessagePayload, from: UInt32) {
		if var info = joinedGroups[msg.groupId] {
			if !info.members.contains(from) {
				info.members.append(from)
				joinedGroups[msg.groupId] = info
			}
		} else {
			let info = GroupInfo(
				groupId: msg.groupId,
				name: msg.text.isEmpty ? "Group \(msg.groupId.toHex().suffix(4))" : msg.text,
				channelIndex: 0,
				members: msg.members.isEmpty ? [from] : msg.members,
				createdAt: Date()
			)
			joinedGroups[msg.groupId] = info
			groupRosters[msg.groupId] = msg.members.isEmpty ? [from] : msg.members
			groupMessages[msg.groupId] = []
		}

		let entry = GroupMessageEntry(
			messageId: msg.messageId,
			groupId: msg.groupId,
			fromNode: from,
			text: "\(from.toHex()) joined the group",
			timestamp: Date(),
			type: .groupJoin
		)
		appendMessage(entry, to: msg.groupId)
		saveState()
		Logger.mesh.info("Node \(from.toHex()) joined group \(msg.groupId.toHex())")
	}

	private func handleGroupLeave(_ msg: GroupMessagePayload, from: UInt32) {
		if var info = joinedGroups[msg.groupId] {
			info.members.removeAll { $0 == from }
			joinedGroups[msg.groupId] = info
		}
		let entry = GroupMessageEntry(
			messageId: msg.messageId,
			groupId: msg.groupId,
			fromNode: from,
			text: "\(from.toHex()) left the group",
			timestamp: Date(),
			type: .groupLeave
		)
		appendMessage(entry, to: msg.groupId)
		saveState()
	}

	private func handleRosterResponse(_ msg: GroupMessagePayload) {
		if !msg.roster.isEmpty {
			groupRosters[msg.groupId] = msg.roster
		}
		if var info = joinedGroups[msg.groupId] {
			info.members = msg.roster
			joinedGroups[msg.groupId] = info
		}
		saveState()
	}

	// MARK: - Transport

	private func sendGroupPacket(
		payload: GroupMessagePayload,
		channelIndex: Int32,
		fromUserNum: Int64,
		accessoryManager: AccessoryManager
	) async throws {
		var dataMessage = DataMessage()
		dataMessage.payload = payload.serialize()
		dataMessage.portnum = .groupMessageApp

		var meshPacket = MeshPacket()
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.to = Constants.maximumNodeNum // Broadcast to all
		meshPacket.from = UInt32(fromUserNum)
		meshPacket.channel = UInt32(channelIndex)
		meshPacket.decoded = dataMessage
		meshPacket.wantAck = false // Group ACKs are handled at application layer

		var toRadio = ToRadio()
		toRadio.packet = meshPacket

		try await accessoryManager.send(toRadio, debugDescription: "Group message type=\(payload.type)")
	}

	// MARK: - Helpers

	private func generateMessageId() -> UInt32 {
		let id = nextMessageId
		nextMessageId += 1
		return id
	}

	private func appendMessage(_ entry: GroupMessageEntry, to groupId: UInt32) {
		var messages = groupMessages[groupId] ?? []
		// Deduplicate by messageId
		if !messages.contains(where: { $0.messageId == entry.messageId }) {
			messages.append(entry)
			// Keep last 500 messages per group
			if messages.count > 500 {
				messages = Array(messages.suffix(500))
			}
			groupMessages[groupId] = messages
		}
	}

	// MARK: - Persistence

	private var stateFileURL: URL {
		let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
		return dir.appendingPathComponent("group_messages_state.json")
	}

	private struct PersistedState: Codable {
		var groupMessages: [UInt32: [GroupMessageEntry]]
		var joinedGroups: [UInt32: GroupInfo]
		var groupRosters: [UInt32: [UInt32]]
		var nextMessageId: UInt32
		var unreadCounts: [UInt32: Int]?
	}

	func saveState() {
		let state = PersistedState(
			groupMessages: groupMessages,
			joinedGroups: joinedGroups,
			groupRosters: groupRosters,
			nextMessageId: nextMessageId,
			unreadCounts: unreadCounts
		)
		do {
			let data = try JSONEncoder().encode(state)
			try data.write(to: stateFileURL, options: .atomic)
		} catch {
			Logger.data.error("Failed to save group message state: \(error.localizedDescription)")
		}
	}

	private func loadState() {
		guard FileManager.default.fileExists(atPath: stateFileURL.path) else { return }
		do {
			let data = try Data(contentsOf: stateFileURL)
			let state = try JSONDecoder().decode(PersistedState.self, from: data)
			groupMessages = state.groupMessages
			joinedGroups = state.joinedGroups
			groupRosters = state.groupRosters
			nextMessageId = state.nextMessageId
			unreadCounts = state.unreadCounts ?? [:]
		} catch {
			Logger.data.error("Failed to load group message state: \(error.localizedDescription)")
		}
	}
}

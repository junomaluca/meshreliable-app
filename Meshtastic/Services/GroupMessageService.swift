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
import UserNotifications

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

/// Encodes/decodes the firmware's `meshtastic_GroupMessage` protobuf (portnum 258) so that the app,
/// the firmware GroupMessageModule, and bare devices all interoperate. (Previously this used a
/// hand-rolled binary layout that nanopb could not decode, so app group messages were invisible to
/// devices.) See `serialize()`/`deserialize()` for the protobuf field numbers.
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

	// Protobuf field numbers — MUST match the firmware's meshtastic_GroupMessage (.proto):
	//   type=1, message_id=2, group_id=3, text=4, members=5, ack_message_id=6,
	//   member_node_id=7, roster=8, send_time=9, rebroadcast_count=10
	private enum Field {
		static let type = 1, messageId = 2, groupId = 3, text = 4, members = 5
		static let ackMessageId = 6, memberNodeId = 7, roster = 8, sendTime = 9, rebroadcastCount = 10
	}

	private static func encodeVarint(_ value: UInt64) -> [UInt8] {
		var v = value
		var out: [UInt8] = []
		repeat {
			var byte = UInt8(v & 0x7F)
			v >>= 7
			if v != 0 { byte |= 0x80 }
			out.append(byte)
		} while v != 0
		return out
	}

	/// Encode as the firmware's `meshtastic_GroupMessage` protobuf so devices (nanopb) can decode it.
	/// Repeated members/roster are written UNPACKED (one tag+varint each) — that is what the firmware
	/// decoder and the proven test harness use.
	func serialize() -> Data {
		var out: [UInt8] = []
		func tag(_ field: Int, _ wire: Int) { out += Self.encodeVarint(UInt64((field << 3) | wire)) }
		func varint(_ field: Int, _ value: UInt32, force: Bool = false) {
			if value == 0 && !force { return }
			tag(field, 0); out += Self.encodeVarint(UInt64(value))
		}
		varint(Field.type, UInt32(type.rawValue), force: true) // proto3 omits 0, but type=0 is meaningful
		varint(Field.messageId, messageId)
		varint(Field.groupId, groupId)
		if !text.isEmpty, let t = text.data(using: .utf8) {
			tag(Field.text, 2); out += Self.encodeVarint(UInt64(t.count)); out += [UInt8](t)
		}
		for m in members { varint(Field.members, m, force: true) }
		varint(Field.ackMessageId, ackMessageId)
		varint(Field.memberNodeId, memberNodeId)
		for r in roster { varint(Field.roster, r, force: true) }
		varint(Field.sendTime, sendTime)
		varint(Field.rebroadcastCount, UInt32(rebroadcastCount))
		return Data(out)
	}

	static func deserialize(from data: Data) -> GroupMessagePayload? {
		var type: GroupMessageType = .groupText
		var messageId: UInt32 = 0, groupId: UInt32 = 0, ackMessageId: UInt32 = 0
		var memberNodeId: UInt32 = 0, sendTime: UInt32 = 0
		var rebroadcastCount: UInt8 = 0
		var members: [UInt32] = [], roster: [UInt32] = []
		var text = ""

		let bytes = [UInt8](data)
		var i = 0
		func readVarint() -> UInt64? {
			var shift: UInt64 = 0, result: UInt64 = 0
			while i < bytes.count {
				let b = bytes[i]; i += 1
				result |= UInt64(b & 0x7F) << shift
				if b & 0x80 == 0 { return result }
				shift += 7
				if shift >= 64 { return nil }
			}
			return nil
		}
		// Decode a length-delimited blob as packed repeated uint32 (fallback if a peer packs them).
		func appendPacked(_ sub: ArraySlice<UInt8>, into arr: inout [UInt32]) {
			var j = sub.startIndex
			while j < sub.endIndex {
				var shift: UInt64 = 0, r: UInt64 = 0
				while j < sub.endIndex {
					let b = sub[j]; j += 1
					r |= UInt64(b & 0x7F) << shift
					if b & 0x80 == 0 { break }
					shift += 7
				}
				arr.append(UInt32(truncatingIfNeeded: r))
			}
		}

		while i < bytes.count {
			guard let key = readVarint() else { break }
			let field = Int(key >> 3)
			let wire = Int(key & 0x7)
			switch wire {
			case 0: // varint
				guard let v = readVarint() else { return nil }
				switch field {
				case Field.type: type = GroupMessageType(rawValue: UInt8(truncatingIfNeeded: v)) ?? .groupText
				case Field.messageId: messageId = UInt32(truncatingIfNeeded: v)
				case Field.groupId: groupId = UInt32(truncatingIfNeeded: v)
				case Field.members: members.append(UInt32(truncatingIfNeeded: v))
				case Field.ackMessageId: ackMessageId = UInt32(truncatingIfNeeded: v)
				case Field.memberNodeId: memberNodeId = UInt32(truncatingIfNeeded: v)
				case Field.roster: roster.append(UInt32(truncatingIfNeeded: v))
				case Field.sendTime: sendTime = UInt32(truncatingIfNeeded: v)
				case Field.rebroadcastCount: rebroadcastCount = UInt8(truncatingIfNeeded: v)
				default: break
				}
			case 2: // length-delimited
				guard let len = readVarint() else { return nil }
				let n = Int(len)
				guard i + n <= bytes.count else { return nil }
				let sub = bytes[i..<(i + n)]; i += n
				switch field {
				case Field.text: text = String(bytes: sub, encoding: .utf8) ?? ""
				case Field.members: appendPacked(sub, into: &members)
				case Field.roster: appendPacked(sub, into: &roster)
				default: break
				}
			case 5: i += 4 // fixed32 — skip
			case 1: i += 8 // fixed64 — skip
			default: return nil
			}
		}

		return GroupMessagePayload(
			type: type, messageId: messageId, groupId: groupId, ackMessageId: ackMessageId,
			memberNodeId: memberNodeId, sendTime: sendTime, rebroadcastCount: rebroadcastCount,
			members: members, roster: roster, text: text)
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

	/// Members who never confirmed a group-join invite (groupId -> [nodeNum]). In-memory only; surfaced in UI.
	@Published var unconfirmedMembers: [UInt32: [UInt32]] = [:]

	/// Total unread group messages across all groups
	var totalUnreadCount: Int {
		unreadCounts.values.reduce(0, +)
	}

	private var nextMessageId: UInt32 = 1

	// MARK: - Reliable join (ACK + retransmit)

	/// A group-join we sent that we are still trying to confirm was received by every member.
	/// groupJoin is critical: a member that never receives it is silently excluded from the group,
	/// so we retransmit (same messageId) to un-ACKed members on a backoff until confirmed or exhausted.
	private struct PendingJoin {
		let messageId: UInt32
		let groupId: UInt32
		let channelIndex: Int32
		let fromUserNum: Int64
		let payload: GroupMessagePayload
		let membersToConfirm: [UInt32]
		var attempts: Int
		var nextAttemptAt: Date
	}

	/// Joins awaiting confirmation, keyed by the join's messageId.
	private var pendingJoins: [UInt32: PendingJoin] = [:]
	/// Single driver task that walks `pendingJoins` until it drains.
	private var retransmitTask: Task<Void, Never>?

	/// Retransmit cadence and ceiling. Counts the initial send as attempt 1, so 6 ≈ 5 retries ≈ ~100s.
	private static let joinRetryInterval: TimeInterval = 20
	private static let maxJoinAttempts = 6

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

		// Track ACKs — set up before send so UI shows pending state immediately
		let ackStatus = GroupAckStatus(
			messageId: msgId,
			groupId: groupId,
			members: members.filter { $0 != UInt32(fromUserNum) },
			ackedBy: [],
			sendTime: Date()
		)
		ackTrackers[msgId] = ackStatus

		// Store message locally BEFORE sending so it appears in chat immediately
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
		saveState()

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

		Logger.mesh.info("Sent group message \(msgId) to group \(groupId.toHex()) with \(members.count) members")
		MeshReliableTelemetry.shared.record(.groupMessageSent, details: [
			"messageId": "\(msgId)",
			"groupId": "\(groupId)",
			"memberCount": "\(members.count)",
			"text": String(text.prefix(100))
		])
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

		// Reliable join: keep retransmitting to any member that doesn't ACK the invite.
		registerReliableJoin(messageId: msgId, groupId: groupId, channelIndex: Int32(channelIndex),
							  fromUserNum: fromUserNum, payload: payload, members: allMembers)

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

	func addMember(nodeNum: UInt32, to groupId: UInt32, accessoryManager: AccessoryManager) async throws {
		guard let fromUserNum = accessoryManager.activeConnection?.device.num else {
			throw AccessoryError.ioFailed("No active device")
		}
		guard var info = joinedGroups[groupId] else {
			throw AccessoryError.ioFailed("Group not found")
		}

		// Add member to local roster
		if !info.members.contains(nodeNum) {
			info.members.append(nodeNum)
			joinedGroups[groupId] = info
			groupRosters[groupId] = info.members
		}

		// Send a JOIN announcement with the updated roster so the new member learns about the group
		let msgId = generateMessageId()
		let payload = GroupMessagePayload(
			type: .groupJoin,
			messageId: msgId,
			groupId: groupId,
			ackMessageId: 0,
			memberNodeId: nodeNum,
			sendTime: UInt32(Date().timeIntervalSince1970),
			rebroadcastCount: 0,
			members: info.members,
			roster: info.members,
			text: info.name
		)

		try await sendGroupPacket(
			payload: payload,
			channelIndex: Int32(info.channelIndex),
			fromUserNum: fromUserNum,
			accessoryManager: accessoryManager
		)

		// Reliable join: confirm every member (esp. the new one) received the updated roster.
		registerReliableJoin(messageId: msgId, groupId: groupId, channelIndex: Int32(info.channelIndex),
							  fromUserNum: fromUserNum, payload: payload, members: info.members)

		// Add system message to chat
		let entry = GroupMessageEntry(
			messageId: msgId,
			groupId: groupId,
			fromNode: UInt32(fromUserNum),
			text: "\(nodeNum.toHex()) was added to the group",
			timestamp: Date(),
			type: .groupJoin
		)
		appendMessage(entry, to: groupId)
		saveState()
		Logger.mesh.info("Added member \(nodeNum.toHex()) to group \(groupId.toHex())")
	}

	func markAsRead(groupId: UInt32) {
		unreadCounts[groupId] = 0
	}

	// MARK: - Reliable join machinery

	/// Begin tracking ACKs for a sent groupJoin and start retransmitting to members that don't confirm.
	private func registerReliableJoin(messageId: UInt32, groupId: UInt32, channelIndex: Int32,
									  fromUserNum: Int64, payload: GroupMessagePayload, members: [UInt32]) {
		let toConfirm = members.filter { $0 != UInt32(fromUserNum) }
		guard !toConfirm.isEmpty else { return }
		// Track which members have ACKed this join (handleGroupAck populates ackedBy).
		ackTrackers[messageId] = GroupAckStatus(
			messageId: messageId, groupId: groupId, members: toConfirm, ackedBy: [], sendTime: Date())
		unconfirmedMembers[groupId] = nil
		pendingJoins[messageId] = PendingJoin(
			messageId: messageId, groupId: groupId, channelIndex: channelIndex, fromUserNum: fromUserNum,
			payload: payload, membersToConfirm: toConfirm, attempts: 1,
			nextAttemptAt: Date().addingTimeInterval(Self.joinRetryInterval))
		ensureRetransmitLoop()
	}

	/// Run a single driver task that retransmits pending joins until they all confirm or exhaust.
	private func ensureRetransmitLoop() {
		guard retransmitTask == nil else { return }
		retransmitTask = Task { @MainActor in
			while !self.pendingJoins.isEmpty {
				try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s tick
				await self.processPendingJoins()
			}
			self.retransmitTask = nil
		}
	}

	private func processPendingJoins() async {
		let now = Date()
		for (msgId, pending) in pendingJoins {
			let acked = Set(ackTrackers[msgId]?.ackedBy ?? [])
			let missing = pending.membersToConfirm.filter { !acked.contains($0) }
			if missing.isEmpty {
				pendingJoins.removeValue(forKey: msgId)
				Logger.mesh.info("Group join \(msgId) confirmed by all \(pending.membersToConfirm.count) member(s)")
				continue
			}
			guard now >= pending.nextAttemptAt else { continue }
			if pending.attempts >= Self.maxJoinAttempts {
				pendingJoins.removeValue(forKey: msgId)
				markJoinUnconfirmed(groupId: pending.groupId, members: missing)
				continue
			}
			var updated = pending
			updated.attempts += 1
			updated.nextAttemptAt = now.addingTimeInterval(Self.joinRetryInterval)
			pendingJoins[msgId] = updated
			do {
				try await sendGroupPacket(payload: pending.payload, channelIndex: pending.channelIndex,
										  fromUserNum: pending.fromUserNum, accessoryManager: AccessoryManager.shared)
				Logger.mesh.info("Group join \(msgId) retransmit \(updated.attempts)/\(Self.maxJoinAttempts); \(missing.count) member(s) unconfirmed")
			} catch {
				Logger.mesh.error("Group join \(msgId) retransmit failed: \(error.localizedDescription)")
			}
		}
	}

	private func markJoinUnconfirmed(groupId: UInt32, members: [UInt32]) {
		unconfirmedMembers[groupId, default: []].append(contentsOf: members)
		let names = members.map { $0.toHex() }.joined(separator: ", ")
		Logger.mesh.warning("Group join for group \(groupId.toHex()) unconfirmed by: \(names)")
		let entry = GroupMessageEntry(
			messageId: generateMessageId(), groupId: groupId, fromNode: 0,
			text: "⚠️ Could not confirm group membership for: \(names). They may be offline or out of range and may not have received the invite.",
			timestamp: Date(), type: .groupJoin)
		appendMessage(entry, to: groupId)
		saveState()
	}

	/// Acknowledge a received groupJoin so the sender's reliable-join loop can confirm us.
	private func sendGroupAck(ackMessageId: UInt32, groupId: UInt32, channel: UInt32) {
		guard let myNum = AccessoryManager.shared.activeConnection?.device.num else { return }
		let ackPayload = GroupMessagePayload(
			type: .groupAck, messageId: generateMessageId(), groupId: groupId, ackMessageId: ackMessageId,
			memberNodeId: UInt32(myNum), sendTime: UInt32(Date().timeIntervalSince1970),
			rebroadcastCount: 0, members: [], roster: [], text: "")
		Task {
			do {
				try await sendGroupPacket(payload: ackPayload, channelIndex: Int32(channel),
										  fromUserNum: myNum, accessoryManager: AccessoryManager.shared)
				Logger.mesh.info("Sent group join ACK for msg \(ackMessageId) in group \(groupId.toHex())")
			} catch {
				Logger.mesh.error("Failed to send group join ACK: \(error.localizedDescription)")
			}
		}
	}

	// MARK: - Receiving

	func handleIncomingPacket(_ packet: MeshPacket) {
		// Filter out echoes of our own broadcasts
		let myNum = UInt32(UserDefaults.preferredPeripheralNum)
		if myNum > 0 && packet.from == myNum {
			Logger.mesh.debug("GroupMessageService: Dropping echoed packet from self")
			return
		}

		let data = packet.decoded.payload
		guard let msg = GroupMessagePayload.deserialize(from: data) else {
			Logger.mesh.warning("GroupMessageService: Could not parse group message payload")
			return
		}

		switch msg.type {
		case .groupText:
			handleGroupText(msg, from: packet.from, channel: packet.channel)
		case .groupAck:
			handleGroupAck(msg)
		case .groupAllAcked:
			handleGroupAllAcked(msg)
		case .groupJoin:
			handleGroupJoin(msg, from: packet.from, channel: packet.channel)
		case .groupLeave:
			handleGroupLeave(msg, from: packet.from)
		case .groupRosterRequest:
			Logger.mesh.info("GroupMessageService: Roster request from \(packet.from.toHex())")
		case .groupRosterResponse:
			handleRosterResponse(msg)
		}
	}

	private func handleGroupText(_ msg: GroupMessagePayload, from: UInt32, channel: UInt32 = 0) {
		let entry = GroupMessageEntry(
			messageId: msg.messageId,
			groupId: msg.groupId,
			fromNode: from,
			text: msg.text,
			timestamp: Date(timeIntervalSince1970: TimeInterval(msg.sendTime)),
			type: .groupText
		)
		let isNew = appendMessage(entry, to: msg.groupId)

		// Auto-create group if we don't know it
		if joinedGroups[msg.groupId] == nil {
			let info = GroupInfo(
				groupId: msg.groupId,
				name: "Group \(msg.groupId.toHex().suffix(4))",
				channelIndex: UInt8(channel),
				members: msg.members,
				createdAt: Date()
			)
			joinedGroups[msg.groupId] = info
			groupRosters[msg.groupId] = msg.members
		}

		// Only increment unread count for genuinely new messages
		if isNew {
			unreadCounts[msg.groupId, default: 0] += 1

			// Schedule a local notification for the incoming group message
			let groupName = joinedGroups[msg.groupId]?.name ?? "Group"
			let senderName = "\(from.toHex())"
			let manager = LocalNotificationManager()
			manager.notifications = [
				Notification(
					id: "notification.group.\(msg.messageId)",
					title: groupName,
					subtitle: senderName,
					content: msg.text,
					target: "messages"
				)
			]
			manager.schedule()

			// Update app badge count to include group unread messages
			UNUserNotificationCenter.current().setBadgeCount(totalUnreadCount)
		}

		saveState()
		MeshReliableTelemetry.shared.record(.groupMessageReceived, details: [
			"from": "\(from)",
			"groupId": "\(msg.groupId)",
			"messageId": "\(msg.messageId)",
			"text": String(msg.text.prefix(100))
		])
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

	private func handleGroupJoin(_ msg: GroupMessagePayload, from: UInt32, channel: UInt32 = 0) {
		// Reliable join: if we're a member of this group, ACK so the sender stops retransmitting.
		// We re-ACK on every received copy (a prior ACK may have been lost); handleGroupAck is idempotent.
		if let myNum = AccessoryManager.shared.activeConnection?.device.num {
			if msg.members.isEmpty || msg.members.contains(UInt32(myNum)) {
				sendGroupAck(ackMessageId: msg.messageId, groupId: msg.groupId, channel: channel)
			}
		}

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

	@discardableResult
	private func appendMessage(_ entry: GroupMessageEntry, to groupId: UInt32) -> Bool {
		var messages = groupMessages[groupId] ?? []
		// Deduplicate by messageId
		if !messages.contains(where: { $0.messageId == entry.messageId }) {
			messages.append(entry)
			// Keep last 500 messages per group
			if messages.count > 500 {
				messages = Array(messages.suffix(500))
			}
			groupMessages[groupId] = messages
			return true
		}
		return false
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

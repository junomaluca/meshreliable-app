//
//  MeshReliableService.swift
//  Meshtastic
//
//  MeshReliable media transfer protocol service.
//  Handles chunked voice memo sending/receiving via privateApp port.
//

import Foundation
import SwiftData
import UIKit
import MeshtasticProtobufs
import OSLog

// MARK: - Transfer Protocol Header

/// Wire format: [type:1][transferId:4][seqNum:2][totalChunks:2][checksum:4][payload...]
/// Total header size: 13 bytes
struct MediaTransferHeader {
	enum MessageType: UInt8 {
		case voiceMemoStart = 0x01
		case voiceMemoChunk = 0x02
		case voiceMemoEnd  = 0x03
		case imageStart    = 0x04
		case imageChunk    = 0x05
		case imageEnd      = 0x06
		case ack           = 0x10
		case nack          = 0x11
	}

	let type: MessageType
	let transferId: UInt32
	let seqNum: UInt16
	let totalChunks: UInt16
	let checksum: UInt32

	static let headerSize = 13

	func serialize() -> Data {
		var data = Data(capacity: Self.headerSize)
		data.append(type.rawValue)
		data.append(contentsOf: withUnsafeBytes(of: transferId.littleEndian) { Array($0) })
		data.append(contentsOf: withUnsafeBytes(of: seqNum.littleEndian) { Array($0) })
		data.append(contentsOf: withUnsafeBytes(of: totalChunks.littleEndian) { Array($0) })
		data.append(contentsOf: withUnsafeBytes(of: checksum.littleEndian) { Array($0) })
		return data
	}

	static func deserialize(from data: Data) -> MediaTransferHeader? {
		guard data.count >= headerSize else { return nil }
		guard let msgType = MessageType(rawValue: data[0]) else { return nil }

		let transferId = data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
		let seqNum = data.subdata(in: 5..<7).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
		let totalChunks = data.subdata(in: 7..<9).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
		let checksum = data.subdata(in: 9..<13).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }

		return MediaTransferHeader(
			type: msgType,
			transferId: transferId,
			seqNum: seqNum,
			totalChunks: totalChunks,
			checksum: checksum
		)
	}
}

// MARK: - Transfer State

/// Tracks an in-progress media transfer (send or receive).
struct MediaTransfer: Identifiable {
	let id: UInt32 // transferId
	let totalChunks: UInt16
	let fromNode: UInt32
	let toNode: UInt32
	let startTime: Date
	var receivedChunks: [UInt16: Data] = [:]
	var isImageTransfer: Bool = false
	var isComplete: Bool { receivedChunks.count == Int(totalChunks) }

	var progress: Double {
		guard totalChunks > 0 else { return 0 }
		return Double(receivedChunks.count) / Double(totalChunks)
	}

	func assemblePayload() -> Data? {
		guard isComplete else { return nil }
		var assembled = Data()
		for seq in 0..<totalChunks {
			guard let chunk = receivedChunks[seq] else { return nil }
			assembled.append(chunk)
		}
		return assembled
	}
}

// MARK: - MeshReliableService

@MainActor
final class MeshReliableService: ObservableObject {

	static let shared = MeshReliableService()

	/// Maximum payload per mesh packet (LoRa constraint).
	/// Meshtastic allows ~233 bytes of payload per DataMessage.
	/// We reserve 13 bytes for our header, leaving room for chunk data.
	/// Using 200 bytes to stay safely within BLE MTU limits after protobuf encoding.
	static let maxChunkPayload = 200
	static let maxVoiceDuration: TimeInterval = 60

	/// Delay between sending each chunk over LoRa.
	/// LoRa LongFast time-on-air for a 213-byte packet is ~500ms, plus
	/// firmware TX queue processing. 2 seconds provides reliable delivery
	/// with no dropped chunks.
	static let interChunkDelay: Duration = .seconds(2)

	/// Fast BLE pacing delay for phone-to-device transfers.
	/// Voice memos are uploaded quickly to the local device via BLE,
	/// then the firmware handles Codec2 encoding and LoRa transmission.
	static let bleChunkDelay: Duration = .milliseconds(100)

	/// Active outgoing transfers keyed by transferId.
	@Published var outgoingTransfers: [UInt32: MediaTransfer] = [:]

	/// Active incoming transfers keyed by transferId.
	@Published var incomingTransfers: [UInt32: MediaTransfer] = [:]

	/// Completed incoming voice memo audio data keyed by messageId.
	/// The view layer reads from here to play back voice memos.
	@Published var completedVoiceMemos: [Int64: Data] = [:]

	/// Completed incoming images keyed by transferId.
	@Published var completedImages: [UInt32: Data] = [:]

	/// Progress for the current outgoing transfer (0..1), nil when idle.
	@Published var sendProgress: Double?

	/// Pending outgoing image messages shown inline in the conversation.
	@Published var pendingImages: [PendingImageMessage] = []

	/// Pending outgoing voice memos shown inline in the conversation.
	@Published var pendingVoiceMemos: [PendingVoiceMemoMessage] = []

	/// When true, a text message send is pending — media upload loops should
	/// yield by pausing until the text message has been sent.
	@Published var textMessagePending = false

	/// Model for an image that's being sent inline (WhatsApp-style).
	struct PendingImageMessage: Identifiable {
		let id: UUID = UUID()
		let imageData: Data
		let toUserNum: Int64
		let channel: Int32
		var progress: Double = 0
		var isSending: Bool = true
		var error: String?
		var transferId: UInt32?
		let timestamp: Date = Date()
	}

	/// Model for a voice memo that's being sent inline.
	struct PendingVoiceMemoMessage: Identifiable {
		let id: UUID = UUID()
		let pcmData: Data
		let duration: TimeInterval
		let toUserNum: Int64
		let channel: Int32
		var progress: Double = 0
		var isSending: Bool = true
		var error: String?
		var transferId: UInt32?
		let timestamp: Date = Date()
	}

	private init() {}

	// MARK: - Helpers

	/// Waits for the active device number to become available (up to 10 seconds).
	/// During BLE connection setup, `device.num` is nil until the config exchange
	/// delivers MyInfo. This avoids an immediate "No active device" failure if the
	/// user sends before config exchange finishes.
	private func waitForDeviceNum(accessoryManager: AccessoryManager) async throws -> Int64 {
		for _ in 0..<20 {
			if let num = accessoryManager.activeConnection?.device.num ?? accessoryManager.activeDeviceNum {
				return num
			}
			try await Task.sleep(for: .milliseconds(500))
		}
		Logger.mesh.error("waitForDeviceNum timed out — connection=\(accessoryManager.activeConnection != nil), deviceNum=\(String(describing: accessoryManager.activeConnection?.device.num)), activeDeviceNum=\(String(describing: accessoryManager.activeDeviceNum))")
		throw AccessoryError.ioFailed("No active device — connection may still be initializing")
	}

	// MARK: - Sending

	/// Sends raw PCM audio data to a destination node via the mesh.
	/// The connected firmware node will handle Codec2 encoding before mesh relay.
	///
	/// - Parameters:
	///   - pcmData: Raw 8kHz 16-bit mono PCM audio.
	///   - toUserNum: Destination user node number (0 for broadcast).
	///   - channel: Channel index.
	///   - accessoryManager: The shared AccessoryManager for BLE transport.
	/// - Returns: The messageId assigned to this voice memo.
	@discardableResult
	func sendVoiceMemo(
		pcmData: Data,
		toUserNum: Int64,
		channel: Int32,
		accessoryManager: AccessoryManager
	) async throws -> Int64 {
		let fromUserNum = try await waitForDeviceNum(accessoryManager: accessoryManager)
		guard !pcmData.isEmpty else {
			throw AccessoryError.ioFailed("Empty audio data")
		}

		let transferId = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		let chunks = pcmData.chunked(size: Self.maxChunkPayload)
		let totalChunks = UInt16(chunks.count)
		let checksum = crc32(pcmData)

		let transfer = MediaTransfer(
			id: transferId,
			totalChunks: totalChunks,
			fromNode: UInt32(fromUserNum),
			toNode: UInt32(toUserNum),
			startTime: Date()
		)
		outgoingTransfers[transferId] = transfer
		sendProgress = 0

		Logger.mesh.info("Starting voice memo transfer \(transferId.toHex()): \(pcmData.count) bytes in \(totalChunks) chunks")

		// Send start header
		let startHeader = MediaTransferHeader(
			type: .voiceMemoStart,
			transferId: transferId,
			seqNum: 0,
			totalChunks: totalChunks,
			checksum: checksum
		)
		try await sendChunk(
			headerData: startHeader.serialize(),
			payload: Data(),
			toUserNum: toUserNum,
			channel: channel,
			fromUserNum: fromUserNum,
			accessoryManager: accessoryManager
		)

		// Send chunks
		for (index, chunk) in chunks.enumerated() {
			let header = MediaTransferHeader(
				type: .voiceMemoChunk,
				transferId: transferId,
				seqNum: UInt16(index),
				totalChunks: totalChunks,
				checksum: checksum
			)
			try await sendChunk(
				headerData: header.serialize(),
				payload: chunk,
				toUserNum: toUserNum,
				channel: channel,
				fromUserNum: fromUserNum,
				accessoryManager: accessoryManager
			)

			sendProgress = Double(index + 1) / Double(totalChunks)

			// Delay between chunks for LoRa reliability — each packet needs
			// ~500ms time-on-air plus firmware TX queue processing time.
			try await Task.sleep(for: Self.interChunkDelay)
		}

		// Send end marker
		let endHeader = MediaTransferHeader(
			type: .voiceMemoEnd,
			transferId: transferId,
			seqNum: 0,
			totalChunks: totalChunks,
			checksum: checksum
		)
		try await sendChunk(
			headerData: endHeader.serialize(),
			payload: Data(),
			toUserNum: toUserNum,
			channel: channel,
			fromUserNum: fromUserNum,
			accessoryManager: accessoryManager
		)

		sendProgress = nil
		outgoingTransfers.removeValue(forKey: transferId)

		let messageId = Int64(transferId)
		MeshReliableTelemetry.shared.record(.voiceMemoSent, details: [
			"transferId": "\(transferId)",
			"toUserNum": "\(toUserNum)",
			"chunks": "\(totalChunks)",
			"bytes": "\(pcmData.count)"
		])
		Logger.mesh.info("Voice memo transfer \(transferId.toHex()) complete")
		return messageId
	}

	/// Sends a compressed JPEG image to a destination node via the mesh.
	@discardableResult
	func sendImage(
		jpegData: Data,
		toUserNum: Int64,
		channel: Int32,
		accessoryManager: AccessoryManager
	) async throws -> UInt32 {
		let fromUserNum = try await waitForDeviceNum(accessoryManager: accessoryManager)
		guard !jpegData.isEmpty else {
			throw AccessoryError.ioFailed("Empty image data")
		}

		let transferId = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		let chunks = jpegData.chunked(size: Self.maxChunkPayload)
		let totalChunks = UInt16(chunks.count)
		let checksum = crc32(jpegData)

		let transfer = MediaTransfer(
			id: transferId,
			totalChunks: totalChunks,
			fromNode: UInt32(fromUserNum),
			toNode: UInt32(toUserNum),
			startTime: Date()
		)
		outgoingTransfers[transferId] = transfer
		sendProgress = 0

		Logger.mesh.info("Starting image transfer \(transferId.toHex()): \(jpegData.count) bytes in \(totalChunks) chunks")

		// Send start header
		let startHeader = MediaTransferHeader(
			type: .imageStart,
			transferId: transferId,
			seqNum: 0,
			totalChunks: totalChunks,
			checksum: checksum
		)
		try await sendChunk(
			headerData: startHeader.serialize(),
			payload: Data(),
			toUserNum: toUserNum,
			channel: channel,
			fromUserNum: fromUserNum,
			accessoryManager: accessoryManager
		)

		// Send chunks
		for (index, chunk) in chunks.enumerated() {
			let header = MediaTransferHeader(
				type: .imageChunk,
				transferId: transferId,
				seqNum: UInt16(index),
				totalChunks: totalChunks,
				checksum: checksum
			)
			try await sendChunk(
				headerData: header.serialize(),
				payload: chunk,
				toUserNum: toUserNum,
				channel: channel,
				fromUserNum: fromUserNum,
				accessoryManager: accessoryManager
			)

			sendProgress = Double(index + 1) / Double(totalChunks)
			try await Task.sleep(for: Self.interChunkDelay)
		}

		// Send end marker
		let endHeader = MediaTransferHeader(
			type: .imageEnd,
			transferId: transferId,
			seqNum: 0,
			totalChunks: totalChunks,
			checksum: checksum
		)
		try await sendChunk(
			headerData: endHeader.serialize(),
			payload: Data(),
			toUserNum: toUserNum,
			channel: channel,
			fromUserNum: fromUserNum,
			accessoryManager: accessoryManager
		)

		sendProgress = nil
		outgoingTransfers.removeValue(forKey: transferId)

		// Persist image to database
		await persistImage(jpegData, fromUserNum: fromUserNum, toUserNum: toUserNum, channel: channel, transferId: transferId)

		MeshReliableTelemetry.shared.record(.imageSent, details: [
			"transferId": "\(transferId)",
			"toUserNum": "\(toUserNum)",
			"chunks": "\(totalChunks)",
			"bytes": "\(jpegData.count)"
		])
		Logger.mesh.info("Image transfer \(transferId.toHex()) complete")
		return transferId
	}

	/// Sends an image inline (WhatsApp-style): creates a pending message immediately,
	/// sends in the background, and updates progress on the pending message.
	func sendImageInline(
		image: UIImage,
		toUserNum: Int64,
		channel: Int32,
		accessoryManager: AccessoryManager
	) {
		guard let compressedData = MeshImageCompressor.compress(
			image: image,
			maxDimension: 128,
			quality: 0.3
		) else {
			Logger.mesh.error("Failed to compress image for inline send")
			return
		}

		let pending = PendingImageMessage(
			imageData: compressedData,
			toUserNum: toUserNum,
			channel: channel
		)
		let pendingId = pending.id
		pendingImages.append(pending)

		Task {
			do {
				Logger.mesh.info("sendImageInline: starting send to \(toUserNum), compressed size: \(compressedData.count) bytes")
				let fromUserNum = try await waitForDeviceNum(accessoryManager: accessoryManager)

				let transferId = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
				updatePending(id: pendingId) { $0.transferId = transferId }

				let chunks = compressedData.chunked(size: Self.maxChunkPayload)
				let totalChunks = UInt16(chunks.count)
				let checksum = crc32(compressedData)
				Logger.mesh.info("sendImageInline: transfer \(transferId.toHex()) — \(totalChunks) chunks, checksum=\(checksum)")

				let transfer = MediaTransfer(
					id: transferId,
					totalChunks: totalChunks,
					fromNode: UInt32(fromUserNum),
					toNode: UInt32(toUserNum),
					startTime: Date()
				)
				outgoingTransfers[transferId] = transfer

				// Send start header
				let startHeader = MediaTransferHeader(
					type: .imageStart,
					transferId: transferId,
					seqNum: 0,
					totalChunks: totalChunks,
					checksum: checksum
				)
				try await sendChunk(
					headerData: startHeader.serialize(),
					payload: Data(),
					toUserNum: toUserNum,
					channel: channel,
					fromUserNum: fromUserNum,
					accessoryManager: accessoryManager
				)

				// Send chunks
				for (index, chunk) in chunks.enumerated() {
					// Yield to text messages if one is pending
					while textMessagePending {
						try await Task.sleep(for: .milliseconds(50))
					}

					let header = MediaTransferHeader(
						type: .imageChunk,
						transferId: transferId,
						seqNum: UInt16(index),
						totalChunks: totalChunks,
						checksum: checksum
					)
					try await sendChunk(
						headerData: header.serialize(),
						payload: chunk,
						toUserNum: toUserNum,
						channel: channel,
						fromUserNum: fromUserNum,
						accessoryManager: accessoryManager
					)

					let progress = Double(index + 1) / Double(totalChunks)
					updatePending(id: pendingId) { $0.progress = progress }
					try await Task.sleep(for: Self.interChunkDelay)
				}

				// Send end marker
				let endHeader = MediaTransferHeader(
					type: .imageEnd,
					transferId: transferId,
					seqNum: 0,
					totalChunks: totalChunks,
					checksum: checksum
				)
				try await sendChunk(
					headerData: endHeader.serialize(),
					payload: Data(),
					toUserNum: toUserNum,
					channel: channel,
					fromUserNum: fromUserNum,
					accessoryManager: accessoryManager
				)

				outgoingTransfers.removeValue(forKey: transferId)
				updatePending(id: pendingId) { $0.isSending = false; $0.progress = 1.0 }

				// Persist image to database so it survives across device connections
				await persistImage(compressedData, fromUserNum: fromUserNum, toUserNum: toUserNum, channel: channel, transferId: transferId)

				// Remove pending image now that it's persisted — avoids duplicate display
				pendingImages.removeAll { $0.id == pendingId }

				MeshReliableTelemetry.shared.record(.imageSent, details: [
					"transferId": "\(transferId)",
					"toUserNum": "\(toUserNum)",
					"chunks": "\(totalChunks)",
					"bytes": "\(compressedData.count)"
				])
				Logger.mesh.info("Inline image transfer \(transferId.toHex()) complete")
			} catch {
				Logger.mesh.error("Inline image send failed: \(error.localizedDescription), type: \(String(describing: type(of: error)))")
				updatePending(id: pendingId) {
					$0.isSending = false
					$0.error = error.localizedDescription
				}
			}
		}
	}

	/// Retry a failed pending image send.
	func retryPendingImage(id: UUID, accessoryManager: AccessoryManager) {
		guard let index = pendingImages.firstIndex(where: { $0.id == id }) else { return }
		let pending = pendingImages[index]
		pendingImages.remove(at: index)

		guard let image = UIImage(data: pending.imageData) else { return }
		sendImageInline(
			image: image,
			toUserNum: pending.toUserNum,
			channel: pending.channel,
			accessoryManager: accessoryManager
		)
	}

	private func updatePending(id: UUID, update: (inout PendingImageMessage) -> Void) {
		if let index = pendingImages.firstIndex(where: { $0.id == id }) {
			update(&pendingImages[index])
		}
	}

	// MARK: - Inline Voice Memo Sending (Fast BLE Upload)

	/// Sends a voice memo via fast BLE upload to the local device.
	/// Raw PCM is sent quickly to the connected firmware, which performs
	/// Codec2 encoding on-device and transmits compressed data over LoRa.
	///
	/// The voiceMemoStart header payload includes the final destination
	/// (destNode + destChannel) so the firmware knows where to relay.
	func sendVoiceMemoInline(
		pcmData: Data,
		duration: TimeInterval,
		toUserNum: Int64,
		channel: Int32,
		accessoryManager: AccessoryManager
	) {
		guard !pcmData.isEmpty else {
			Logger.mesh.error("Empty PCM data for inline voice memo send")
			return
		}

		let pending = PendingVoiceMemoMessage(
			pcmData: pcmData,
			duration: duration,
			toUserNum: toUserNum,
			channel: channel
		)
		let pendingId = pending.id
		pendingVoiceMemos.append(pending)

		Task {
			do {
				let fromUserNum = try await waitForDeviceNum(accessoryManager: accessoryManager)
				// Send to the locally connected device (BLE), not the final destination
				let connectedDeviceNum = fromUserNum

				let transferId = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
				updatePendingVoiceMemo(id: pendingId) { $0.transferId = transferId }

				let chunks = pcmData.chunked(size: Self.maxChunkPayload)
				let totalChunks = UInt16(chunks.count)
				let checksum = crc32(pcmData)

				let transfer = MediaTransfer(
					id: transferId,
					totalChunks: totalChunks,
					fromNode: UInt32(fromUserNum),
					toNode: UInt32(toUserNum),
					startTime: Date()
				)
				outgoingTransfers[transferId] = transfer

				// Build start header with destination info in payload:
				// [destNode:4 LE][destChannel:1]
				let startHeader = MediaTransferHeader(
					type: .voiceMemoStart,
					transferId: transferId,
					seqNum: 0,
					totalChunks: totalChunks,
					checksum: checksum
				)
				var startPayload = Data()
				let destNode = toUserNum > 0 ? UInt32(toUserNum) : UInt32(Constants.maximumNodeNum)
				startPayload.append(contentsOf: withUnsafeBytes(of: destNode.littleEndian) { Array($0) })
				startPayload.append(UInt8(channel))

				try await sendChunk(
					headerData: startHeader.serialize(),
					payload: startPayload,
					toUserNum: connectedDeviceNum,
					channel: 0, // privateApp to local device
					fromUserNum: fromUserNum,
					accessoryManager: accessoryManager
				)

				Logger.mesh.info("Voice memo BLE upload started: \(pcmData.count) bytes in \(totalChunks) chunks to device \(connectedDeviceNum), dest=\(toUserNum) ch=\(channel)")

				// Send chunks with fast BLE pacing (20ms vs 2s LoRa)
				for (index, chunk) in chunks.enumerated() {
					// Yield to text messages if one is pending
					while textMessagePending {
						try await Task.sleep(for: .milliseconds(50))
					}

					let header = MediaTransferHeader(
						type: .voiceMemoChunk,
						transferId: transferId,
						seqNum: UInt16(index),
						totalChunks: totalChunks,
						checksum: checksum
					)
					try await sendChunk(
						headerData: header.serialize(),
						payload: chunk,
						toUserNum: connectedDeviceNum,
						channel: 0,
						fromUserNum: fromUserNum,
						accessoryManager: accessoryManager
					)

					let progress = Double(index + 1) / Double(totalChunks)
					updatePendingVoiceMemo(id: pendingId) { $0.progress = progress }
					try await Task.sleep(for: Self.bleChunkDelay)
				}

				// Send end marker
				let endHeader = MediaTransferHeader(
					type: .voiceMemoEnd,
					transferId: transferId,
					seqNum: 0,
					totalChunks: totalChunks,
					checksum: checksum
				)
				try await sendChunk(
					headerData: endHeader.serialize(),
					payload: Data(),
					toUserNum: connectedDeviceNum,
					channel: 0,
					fromUserNum: fromUserNum,
					accessoryManager: accessoryManager
				)

				outgoingTransfers.removeValue(forKey: transferId)
				updatePendingVoiceMemo(id: pendingId) { $0.isSending = false; $0.progress = 1.0 }

				// Persist voice memo to database so it sorts chronologically with other messages
				await persistVoiceMemo(pcmData, duration: duration, fromUserNum: fromUserNum, toUserNum: toUserNum, channel: channel, transferId: transferId)

				// Remove pending voice memo now that it's persisted — avoids duplicate display
				pendingVoiceMemos.removeAll { $0.id == pendingId }

				MeshReliableTelemetry.shared.record(.voiceMemoSent, details: [
					"transferId": "\(transferId)",
					"toUserNum": "\(toUserNum)",
					"chunks": "\(totalChunks)",
					"bytes": "\(pcmData.count)",
					"mode": "fastBLE"
				])
				Logger.mesh.info("Voice memo BLE upload \(transferId.toHex()) complete — firmware will Codec2 encode and LoRa send")
			} catch {
				Logger.mesh.error("Inline voice memo send failed: \(error.localizedDescription)")
				updatePendingVoiceMemo(id: pendingId) {
					$0.isSending = false
					$0.error = error.localizedDescription
				}
			}
		}
	}

	/// Retry a failed pending voice memo send.
	func retryPendingVoiceMemo(id: UUID, accessoryManager: AccessoryManager) {
		guard let index = pendingVoiceMemos.firstIndex(where: { $0.id == id }) else { return }
		let pending = pendingVoiceMemos[index]
		pendingVoiceMemos.remove(at: index)
		sendVoiceMemoInline(
			pcmData: pending.pcmData,
			duration: pending.duration,
			toUserNum: pending.toUserNum,
			channel: pending.channel,
			accessoryManager: accessoryManager
		)
	}

	private func updatePendingVoiceMemo(id: UUID, update: (inout PendingVoiceMemoMessage) -> Void) {
		if let index = pendingVoiceMemos.firstIndex(where: { $0.id == id }) {
			update(&pendingVoiceMemos[index])
		}
	}

	private func sendChunk(
		headerData: Data,
		payload: Data,
		toUserNum: Int64,
		channel: Int32,
		fromUserNum: Int64,
		accessoryManager: AccessoryManager
	) async throws {
		var packetPayload = headerData
		packetPayload.append(payload)

		var dataMessage = DataMessage()
		dataMessage.payload = packetPayload
		dataMessage.portnum = .privateApp

		var meshPacket = MeshPacket()
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.to = toUserNum > 0 ? UInt32(toUserNum) : Constants.maximumNodeNum
		meshPacket.from = UInt32(fromUserNum)
		meshPacket.channel = UInt32(channel)
		meshPacket.decoded = dataMessage
		meshPacket.wantAck = false
		meshPacket.hopLimit = 7
		meshPacket.hopStart = 7

		var toRadio = ToRadio()
		toRadio.packet = meshPacket

		// Retry each chunk up to 6 times with escalating backoff.
		// Wait for activeConnection to restore before each retry.
		var lastError: Error?
		for attempt in 1...6 {
			do {
				try await accessoryManager.send(toRadio, debugDescription: "Media chunk")
				return
			} catch {
				lastError = error
				Logger.mesh.warning("Chunk send attempt \(attempt)/6 failed: \(error.localizedDescription)")
				if attempt < 6 {
					// Wait for connection to restore (up to 2s per attempt)
					let backoff = min(500 * attempt, 2000)
					for _ in 0..<(backoff / 100) {
						if accessoryManager.activeConnection != nil { break }
						try await Task.sleep(for: .milliseconds(100))
					}
					// Extra backoff if still no connection
					if accessoryManager.activeConnection == nil {
						try await Task.sleep(for: .milliseconds(backoff))
					}
				}
			}
		}
		throw lastError ?? AccessoryError.ioFailed("Failed to send chunk after retries")
	}

	// MARK: - Receiving

	/// Called by AccessoryManager+FromRadio when a privateApp packet arrives.
	/// Reassembles chunked voice memo data.
	func handleIncomingPacket(_ packet: MeshPacket) {
		let data = packet.decoded.payload
		guard let header = MediaTransferHeader.deserialize(from: data) else {
			Logger.mesh.warning("MeshReliable: Could not parse media transfer header")
			return
		}

		let payload = data.count > MediaTransferHeader.headerSize
			? data.subdata(in: MediaTransferHeader.headerSize..<data.count)
			: Data()

		switch header.type {
		case .voiceMemoStart, .imageStart:
			let kind = header.type == .voiceMemoStart ? "voice memo" : "image"
			Logger.mesh.info("Incoming \(kind) transfer \(header.transferId.toHex()): \(header.totalChunks) chunks expected")
			var transfer = MediaTransfer(
				id: header.transferId,
				totalChunks: header.totalChunks,
				fromNode: packet.from,
				toNode: packet.to,
				startTime: Date()
			)
			transfer.isImageTransfer = (header.type == .imageStart)
			incomingTransfers[header.transferId] = transfer

		case .voiceMemoChunk, .imageChunk:
			guard var transfer = incomingTransfers[header.transferId] else {
				Logger.mesh.warning("MeshReliable: Chunk for unknown transfer \(header.transferId.toHex())")
				return
			}
			transfer.receivedChunks[header.seqNum] = payload
			incomingTransfers[header.transferId] = transfer

			if transfer.isComplete {
				completeTransfer(header.transferId, expectedChecksum: header.checksum, fromPacket: packet)
			}

		case .voiceMemoEnd, .imageEnd:
			if let transfer = incomingTransfers[header.transferId], transfer.isComplete {
				completeTransfer(header.transferId, expectedChecksum: header.checksum, fromPacket: packet)
			} else {
				Logger.mesh.info("MeshReliable: End marker received but transfer incomplete, waiting for retransmits")
			}

		case .ack, .nack:
			Logger.mesh.info("MeshReliable: Received \(String(describing: header.type)) for transfer \(header.transferId.toHex())")
		}
	}

	private func completeTransfer(_ transferId: UInt32, expectedChecksum: UInt32, fromPacket: MeshPacket) {
		guard let transfer = incomingTransfers.removeValue(forKey: transferId),
			  let assembled = transfer.assemblePayload() else {
			Logger.mesh.error("MeshReliable: Failed to assemble transfer \(transferId.toHex())")
			return
		}

		let computedChecksum = crc32(assembled)
		if computedChecksum != expectedChecksum {
			Logger.mesh.warning("MeshReliable: Checksum mismatch for \(transferId.toHex()): expected \(expectedChecksum), got \(computedChecksum). Discarding corrupted transfer.")
			return
		}

		if transfer.isImageTransfer {
			completedImages[transferId] = assembled

			// Persist received image to database
			Task { @MainActor in
				self.persistImage(assembled, fromUserNum: Int64(fromPacket.from), toUserNum: Int64(fromPacket.to), channel: Int32(fromPacket.channel), transferId: transferId)
			}

			MeshReliableTelemetry.shared.record(.imageReceived, details: [
				"transferId": "\(transferId)",
				"chunks": "\(transfer.receivedChunks.count)",
				"bytes": "\(assembled.count)"
			])
			Logger.mesh.info("MeshReliable: Image \(transferId.toHex()) assembled: \(assembled.count) bytes")
		} else {
			let messageId = Int64(transferId)
			completedVoiceMemos[messageId] = assembled
			let duration = Double(assembled.count / 2) / 8000.0

			// Persist voice memo to database for chronological ordering
			Task { @MainActor in
				self.persistVoiceMemo(assembled, duration: duration, fromUserNum: Int64(fromPacket.from), toUserNum: Int64(fromPacket.to), channel: Int32(fromPacket.channel), transferId: transferId)
				// Remove from in-memory store after persistence
				self.completedVoiceMemos.removeValue(forKey: messageId)
			}

			MeshReliableTelemetry.shared.record(.voiceMemoReceived, details: [
				"transferId": "\(transferId)",
				"chunks": "\(transfer.receivedChunks.count)",
				"bytes": "\(assembled.count)"
			])
			Logger.mesh.info("MeshReliable: Voice memo \(transferId.toHex()) assembled: \(assembled.count) bytes")
		}
	}

	// MARK: - Text Priority

	/// Call before sending a text message to pause any in-progress media uploads.
	func signalTextSending() {
		textMessagePending = true
	}

	/// Call after the text message has been sent to resume media uploads.
	func signalTextSent() {
		textMessagePending = false
	}

	// MARK: - Image Persistence

	/// Persists an image to the database so it survives across device connections.
	/// Called after both sending and receiving images.
	@MainActor
	private func persistImage(_ imageData: Data, fromUserNum: Int64, toUserNum: Int64, channel: Int32, transferId: UInt32) {
		let context = PersistenceController.shared.context

		// Check if we already persisted this image (by transferId → messageId)
		let messageId = Int64(transferId)
		let existing = FetchDescriptor<MessageEntity>(
			predicate: #Predicate { $0.messageId == messageId }
		)
		if (try? context.fetchCount(existing)) ?? 0 > 0 { return }

		// Fetch user entities
		let fetchUsers = FetchDescriptor<UserEntity>(
			predicate: #Predicate { $0.num == fromUserNum || $0.num == toUserNum }
		)
		guard let users = try? context.fetch(fetchUsers), !users.isEmpty else {
			Logger.mesh.warning("persistImage: users not found for from=\(fromUserNum) to=\(toUserNum)")
			return
		}

		let msg = MessageEntity()
		context.insert(msg)
		msg.messageId = messageId
		msg.messageTimestamp = Int32(Date().timeIntervalSince1970)
		msg.receivedACK = true
		msg.read = true
		msg.channel = channel
		msg.portNum = Int32(PortNum.privateApp.rawValue)
		msg.imageData = imageData
		msg.messagePayload = "📷"
		msg.fromUser = users.first(where: { $0.num == fromUserNum })
		if toUserNum > 0 && toUserNum != Int64(Constants.maximumNodeNum) {
			msg.toUser = users.first(where: { $0.num == toUserNum })
		}

		do {
			try context.save()
			Logger.mesh.info("persistImage: saved image message \(transferId.toHex()) (\(imageData.count) bytes)")
		} catch {
			Logger.mesh.error("persistImage: failed to save: \(error.localizedDescription)")
		}
	}

	// MARK: - Voice Memo Persistence

	/// Persists a voice memo to the database so it sorts chronologically with other messages.
	@MainActor
	private func persistVoiceMemo(_ pcmData: Data, duration: TimeInterval, fromUserNum: Int64, toUserNum: Int64, channel: Int32, transferId: UInt32) {
		let context = PersistenceController.shared.context

		let messageId = Int64(transferId)
		let existing = FetchDescriptor<MessageEntity>(
			predicate: #Predicate { $0.messageId == messageId }
		)
		if (try? context.fetchCount(existing)) ?? 0 > 0 { return }

		let fetchUsers = FetchDescriptor<UserEntity>(
			predicate: #Predicate { $0.num == fromUserNum || $0.num == toUserNum }
		)
		guard let users = try? context.fetch(fetchUsers), !users.isEmpty else {
			Logger.mesh.warning("persistVoiceMemo: users not found for from=\(fromUserNum) to=\(toUserNum)")
			return
		}

		let msg = MessageEntity()
		context.insert(msg)
		msg.messageId = messageId
		msg.messageTimestamp = Int32(Date().timeIntervalSince1970)
		msg.receivedACK = true
		msg.read = true
		msg.channel = channel
		msg.portNum = Int32(PortNum.privateApp.rawValue)
		msg.voiceMemoData = pcmData
		let minutes = Int(duration) / 60
		let seconds = Int(duration) % 60
		msg.messagePayload = String(format: "🎙 %d:%02d", minutes, seconds)
		msg.fromUser = users.first(where: { $0.num == fromUserNum })
		if toUserNum > 0 && toUserNum != Int64(Constants.maximumNodeNum) {
			msg.toUser = users.first(where: { $0.num == toUserNum })
		}

		do {
			try context.save()
			Logger.mesh.info("persistVoiceMemo: saved voice memo \(transferId.toHex()) (\(pcmData.count) bytes, \(duration)s)")
		} catch {
			Logger.mesh.error("persistVoiceMemo: failed to save: \(error.localizedDescription)")
		}
	}

	// MARK: - Utility

	/// Simple CRC32 checksum matching the firmware implementation.
	private func crc32(_ data: Data) -> UInt32 {
		var crc: UInt32 = 0xFFFFFFFF
		for byte in data {
			crc ^= UInt32(byte)
			for _ in 0..<8 {
				crc = (crc >> 1) ^ (crc & 1 != 0 ? 0xEDB88320 : 0)
			}
		}
		return crc ^ 0xFFFFFFFF
	}
}

// MARK: - Data Chunking Extension

private extension Data {
	func chunked(size: Int) -> [Data] {
		guard size > 0 else { return [self] }
		var chunks: [Data] = []
		var offset = 0
		while offset < count {
			let end = Swift.min(offset + size, count)
			chunks.append(subdata(in: offset..<end))
			offset = end
		}
		return chunks
	}
}

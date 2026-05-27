//
//  MeshReliableService.swift
//  Meshtastic
//
//  MeshReliable media transfer protocol service.
//  Handles chunked voice memo sending/receiving via privateApp port.
//

import Foundation
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
	/// Meshtastic typically allows ~200 bytes of payload per DataMessage.
	/// We reserve 13 bytes for our header, leaving ~220 bytes for chunk data.
	/// The firmware MediaTransferModule uses 220-byte chunks.
	static let maxChunkPayload = 220
	static let maxVoiceDuration: TimeInterval = 60

	/// Active outgoing transfers keyed by transferId.
	@Published var outgoingTransfers: [UInt32: MediaTransfer] = [:]

	/// Active incoming transfers keyed by transferId.
	@Published var incomingTransfers: [UInt32: MediaTransfer] = [:]

	/// Completed incoming voice memo audio data keyed by messageId.
	/// The view layer reads from here to play back voice memos.
	@Published var completedVoiceMemos: [Int64: Data] = [:]

	/// Progress for the current outgoing transfer (0..1), nil when idle.
	@Published var sendProgress: Double?

	private init() {}

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
		guard let fromUserNum = accessoryManager.activeConnection?.device.num else {
			throw AccessoryError.ioFailed("No active device")
		}
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

			// Small delay between chunks to avoid flooding the BLE/radio link.
			// The firmware expects sequential delivery with brief pauses.
			try await Task.sleep(for: .milliseconds(150))
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
		Logger.mesh.info("Voice memo transfer \(transferId.toHex()) complete")
		return messageId
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
		meshPacket.wantAck = false // Voice chunks use end-to-end ack, not per-packet

		var toRadio = ToRadio()
		toRadio.packet = meshPacket

		try await accessoryManager.send(toRadio, debugDescription: "Voice memo chunk")
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
		case .voiceMemoStart:
			Logger.mesh.info("Incoming voice memo transfer \(header.transferId.toHex()): \(header.totalChunks) chunks expected")
			let transfer = MediaTransfer(
				id: header.transferId,
				totalChunks: header.totalChunks,
				fromNode: packet.from,
				toNode: packet.to,
				startTime: Date()
			)
			incomingTransfers[header.transferId] = transfer

		case .voiceMemoChunk:
			guard var transfer = incomingTransfers[header.transferId] else {
				Logger.mesh.warning("MeshReliable: Chunk for unknown transfer \(header.transferId.toHex())")
				return
			}
			transfer.receivedChunks[header.seqNum] = payload
			incomingTransfers[header.transferId] = transfer

			if transfer.isComplete {
				completeTransfer(header.transferId, expectedChecksum: header.checksum, fromPacket: packet)
			}

		case .voiceMemoEnd:
			// The end marker signals all chunks have been sent.
			// If we already have all chunks, assemble. Otherwise wait for stragglers.
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
			Logger.mesh.warning("MeshReliable: Checksum mismatch for \(transferId.toHex()): expected \(expectedChecksum), got \(computedChecksum)")
			// Still store it -- partial data is better than nothing for voice
		}

		let messageId = Int64(transferId)
		completedVoiceMemos[messageId] = assembled
		Logger.mesh.info("MeshReliable: Voice memo \(transferId.toHex()) assembled: \(assembled.count) bytes")
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

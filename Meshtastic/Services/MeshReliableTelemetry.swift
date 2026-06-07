//
//  MeshReliableTelemetry.swift
//  Meshtastic
//
//  Structured event collection for E2E test observability.
//  Singleton collects events from AccessoryManager, GroupMessageService, MeshReliableService.
//

import Foundation
import OSLog

// MARK: - Event Types

enum TelemetryEventType: String, Codable {
	case messageSent
	case messageReceived
	case messageAcked
	case groupCreated
	case groupJoined
	case groupLeft
	case groupMessageSent
	case groupMessageReceived
	case groupAckReceived
	case voiceMemoRecordStart
	case voiceMemoRecordStop
	case voiceMemoSent
	case voiceMemoReceived
	case voiceMemoPlayback
	case imageSent
	case imageReceived
	case error
	case provisioningStarted
	case provisioningCompleted
	// Broad packet-level logging
	case packetReceived       // any decoded mesh packet
	case fromRadioReceived    // any FromRadio event (data/log/config)
	case bleEvent             // BLE connection state changes
	case uiAction             // user interaction in the app
}

struct TelemetryEvent: Codable, Sendable, Identifiable {
	let id: UUID
	let timestamp: Date
	let type: TelemetryEventType
	let details: [String: String]

	init(type: TelemetryEventType, details: [String: String] = [:]) {
		self.id = UUID()
		self.timestamp = Date()
		self.type = type
		self.details = details
	}
}

// MARK: - Singleton

@MainActor
final class MeshReliableTelemetry: ObservableObject {
	static let shared = MeshReliableTelemetry()

	@Published private(set) var events: [TelemetryEvent] = []
	private let maxEvents = 1000

	private init() {}

	nonisolated func record(_ type: TelemetryEventType, details: [String: String] = [:]) {
		let event = TelemetryEvent(type: type, details: details)
		Logger.services.debug("[Telemetry] \(type.rawValue): \(details.description)")
		Task { @MainActor in
			self.events.append(event)
			if self.events.count > self.maxEvents {
				self.events.removeFirst(self.events.count - self.maxEvents)
			}
		}
	}

	func allEvents() -> [TelemetryEvent] {
		return events
	}

	func eventsSince(_ date: Date) -> [TelemetryEvent] {
		return events.filter { $0.timestamp >= date }
	}

	func clear() {
		events.removeAll()
	}
}

//
//  MeshReliableDebugView.swift
//  Meshtastic
//
//  Live debugging dashboard for MeshReliable testing.
//  Shows telemetry events, active transfers, device status,
//  and automated test controls.
//

import SwiftUI
import SwiftData
import MeshtasticProtobufs
import OSLog

// MARK: - Debug Dashboard

struct MeshReliableDebugView: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	@ObservedObject var telemetry = MeshReliableTelemetry.shared
	@ObservedObject var mediaService = MeshReliableService.shared
	@State private var selectedSection: DebugSection = .overview
	@State private var autoScrollEnabled = true

	enum DebugSection: String, CaseIterable {
		case overview = "Overview"
		case events = "Events"
		case transfers = "Transfers"
		case testRunner = "Test Runner"
	}

	var body: some View {
		VStack(spacing: 0) {
			// Section picker
			Picker("Section", selection: $selectedSection) {
				ForEach(DebugSection.allCases, id: \.self) { section in
					Text(section.rawValue).tag(section)
				}
			}
			.pickerStyle(.segmented)
			.padding(.horizontal)
			.padding(.vertical, 8)

			switch selectedSection {
			case .overview:
				DebugOverviewSection(accessoryManager: accessoryManager, telemetry: telemetry, mediaService: mediaService)
			case .events:
				DebugEventsSection(telemetry: telemetry, autoScrollEnabled: $autoScrollEnabled)
			case .transfers:
				DebugTransfersSection(mediaService: mediaService)
			case .testRunner:
				DebugTestRunnerSection(accessoryManager: accessoryManager)
			}
		}
		.navigationTitle("MeshReliable Debug")
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Button {
					telemetry.clear()
				} label: {
					Image(systemName: "trash")
				}
			}
		}
	}
}

// MARK: - Overview Section

struct DebugOverviewSection: View {
	let accessoryManager: AccessoryManager
	@ObservedObject var telemetry: MeshReliableTelemetry
	@ObservedObject var mediaService: MeshReliableService

	var body: some View {
		List {
			// Connection Status
			Section("Connection") {
				HStack {
					Label("Status", systemImage: accessoryManager.isConnected ? "checkmark.circle.fill" : "xmark.circle")
						.foregroundColor(accessoryManager.isConnected ? .green : .red)
					Spacer()
					Text(accessoryManager.isConnected ? "Connected" : "Disconnected")
						.foregroundColor(.secondary)
				}
				if let deviceNum = accessoryManager.activeDeviceNum {
					HStack {
						Label("Device", systemImage: "flipphone")
						Spacer()
						Text("!\(String(format: "%08x", deviceNum))")
							.font(.system(.caption, design: .monospaced))
							.foregroundColor(.secondary)
					}
				}
				HStack {
					Label("MQTT Proxy", systemImage: "dot.radiowaves.up.forward")
					Spacer()
					Text(accessoryManager.mqttProxyConnected ? "Active" : "Inactive")
						.foregroundColor(accessoryManager.mqttProxyConnected ? .green : .secondary)
				}
				HStack {
					Label("Packets Sent", systemImage: "arrow.up.circle")
					Spacer()
					Text("\(accessoryManager.packetsSent)")
						.font(.system(.body, design: .monospaced))
						.foregroundColor(.secondary)
				}
				HStack {
					Label("Packets Received", systemImage: "arrow.down.circle")
					Spacer()
					Text("\(accessoryManager.packetsReceived)")
						.font(.system(.body, design: .monospaced))
						.foregroundColor(.secondary)
				}
			}

			// Event Summary
			Section("Telemetry Summary") {
				let events = telemetry.events
				let counts = Dictionary(grouping: events, by: { $0.type }).mapValues { $0.count }

				if counts.isEmpty {
					Text("No events recorded yet")
						.foregroundColor(.secondary)
				} else {
					ForEach(counts.sorted(by: { $0.key.rawValue < $1.key.rawValue }), id: \.key) { type, count in
						HStack {
							Text(type.rawValue)
								.font(.caption)
							Spacer()
							Text("\(count)")
								.font(.system(.caption, design: .monospaced))
								.foregroundColor(.secondary)
						}
					}
				}
			}

			// Active Transfers
			Section("Active Transfers") {
				if mediaService.outgoingTransfers.isEmpty && mediaService.incomingTransfers.isEmpty {
					Text("No active transfers")
						.foregroundColor(.secondary)
				}
				ForEach(Array(mediaService.outgoingTransfers.values), id: \.id) { transfer in
					TransferRow(transfer: transfer, direction: "OUT")
				}
				ForEach(Array(mediaService.incomingTransfers.values), id: \.id) { transfer in
					TransferRow(transfer: transfer, direction: "IN")
				}
			}

			// Recent Portnums
			Section("Recent Portnums") {
				if accessoryManager.lastReceivedPortnums.isEmpty {
					Text("None received yet")
						.foregroundColor(.secondary)
				} else {
					ForEach(accessoryManager.lastReceivedPortnums.suffix(10).reversed(), id: \.self) { portnum in
						Text(portnum)
							.font(.system(.caption, design: .monospaced))
					}
				}
			}
		}
	}
}

// MARK: - Transfer Row

struct TransferRow: View {
	let transfer: MediaTransfer
	let direction: String

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack {
				Text(direction)
					.font(.system(.caption2, design: .monospaced))
					.padding(.horizontal, 6)
					.padding(.vertical, 2)
					.background(direction == "OUT" ? Color.blue.opacity(0.2) : Color.green.opacity(0.2))
					.cornerRadius(4)
				Text("0x\(String(format: "%08X", transfer.id))")
					.font(.system(.caption, design: .monospaced))
				Spacer()
				Text(transfer.isImageTransfer ? "Image" : "Voice")
					.font(.caption2)
					.foregroundColor(.secondary)
			}
			ProgressView(value: transfer.progress)
			HStack {
				Text("\(transfer.receivedChunks.count)/\(transfer.totalChunks) chunks")
					.font(.caption2)
					.foregroundColor(.secondary)
				Spacer()
				Text(String(format: "%.0f%%", transfer.progress * 100))
					.font(.caption2)
					.foregroundColor(.secondary)
			}
		}
	}
}

// MARK: - Events Section

struct DebugEventsSection: View {
	@ObservedObject var telemetry: MeshReliableTelemetry
	@Binding var autoScrollEnabled: Bool
	@State private var filterType: TelemetryEventType?

	var filteredEvents: [TelemetryEvent] {
		if let filter = filterType {
			return telemetry.events.filter { $0.type == filter }
		}
		return telemetry.events
	}

	var body: some View {
		VStack(spacing: 0) {
			// Filter bar
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 6) {
					FilterChip(label: "All", isSelected: filterType == nil) {
						filterType = nil
					}
					ForEach(uniqueEventTypes, id: \.self) { type in
						FilterChip(label: shortLabel(type), isSelected: filterType == type) {
							filterType = type
						}
					}
				}
				.padding(.horizontal)
				.padding(.vertical, 6)
			}

			// Event list
			ScrollViewReader { proxy in
				List {
					ForEach(filteredEvents) { event in
						EventRow(event: event)
							.id(event.id)
					}
				}
				.listStyle(.plain)
				.onChange(of: filteredEvents.count) { _, _ in
					if autoScrollEnabled, let last = filteredEvents.last {
						withAnimation {
							proxy.scrollTo(last.id, anchor: .bottom)
						}
					}
				}
			}
		}
		.overlay(alignment: .bottomTrailing) {
			Button {
				autoScrollEnabled.toggle()
			} label: {
				Image(systemName: autoScrollEnabled ? "arrow.down.to.line.circle.fill" : "arrow.down.to.line.circle")
					.font(.title2)
					.padding()
					.background(.ultraThinMaterial, in: Circle())
			}
			.padding()
		}
	}

	private var uniqueEventTypes: [TelemetryEventType] {
		Array(Set(telemetry.events.map(\.type))).sorted { $0.rawValue < $1.rawValue }
	}

	private func shortLabel(_ type: TelemetryEventType) -> String {
		switch type {
		case .messageSent: return "MsgTx"
		case .messageReceived: return "MsgRx"
		case .messageAcked: return "Ack"
		case .voiceMemoSent: return "VoiceTx"
		case .voiceMemoReceived: return "VoiceRx"
		case .imageSent: return "ImgTx"
		case .imageReceived: return "ImgRx"
		case .packetReceived: return "Packet"
		case .bleEvent: return "BLE"
		case .error: return "Error"
		default: return String(type.rawValue.prefix(8))
		}
	}
}

// MARK: - Filter Chip

struct FilterChip: View {
	let label: String
	let isSelected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Text(label)
				.font(.caption2)
				.padding(.horizontal, 10)
				.padding(.vertical, 5)
				.background(isSelected ? Color.accentColor : Color(.systemGray5))
				.foregroundColor(isSelected ? .white : .primary)
				.cornerRadius(12)
		}
	}
}

// MARK: - Event Row

struct EventRow: View {
	let event: TelemetryEvent

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack {
				eventIcon
				Text(event.type.rawValue)
					.font(.system(.caption, design: .monospaced))
					.fontWeight(.medium)
				Spacer()
				Text(event.timestamp, style: .time)
					.font(.caption2)
					.foregroundColor(.secondary)
			}
			if !event.details.isEmpty {
				Text(event.details.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
					.font(.system(.caption2, design: .monospaced))
					.foregroundColor(.secondary)
					.lineLimit(2)
			}
		}
		.padding(.vertical, 2)
	}

	@ViewBuilder
	private var eventIcon: some View {
		switch event.type {
		case .messageSent, .groupMessageSent:
			Image(systemName: "arrow.up.circle.fill").foregroundColor(.blue).font(.caption)
		case .messageReceived, .groupMessageReceived:
			Image(systemName: "arrow.down.circle.fill").foregroundColor(.green).font(.caption)
		case .messageAcked, .groupAckReceived:
			Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
		case .voiceMemoSent:
			Image(systemName: "mic.circle.fill").foregroundColor(.blue).font(.caption)
		case .voiceMemoReceived:
			Image(systemName: "mic.circle.fill").foregroundColor(.green).font(.caption)
		case .imageSent:
			Image(systemName: "photo.circle.fill").foregroundColor(.blue).font(.caption)
		case .imageReceived:
			Image(systemName: "photo.circle.fill").foregroundColor(.green).font(.caption)
		case .error:
			Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red).font(.caption)
		case .bleEvent:
			Image(systemName: "antenna.radiowaves.left.and.right").foregroundColor(.purple).font(.caption)
		default:
			Image(systemName: "circle.fill").foregroundColor(.gray).font(.caption2)
		}
	}
}

// MARK: - Transfers Section

struct DebugTransfersSection: View {
	@ObservedObject var mediaService: MeshReliableService

	var body: some View {
		List {
			Section("Outgoing (\(mediaService.outgoingTransfers.count))") {
				if mediaService.outgoingTransfers.isEmpty {
					Text("No outgoing transfers")
						.foregroundColor(.secondary)
				}
				ForEach(Array(mediaService.outgoingTransfers.values), id: \.id) { transfer in
					TransferDetailRow(transfer: transfer)
				}
			}

			Section("Incoming (\(mediaService.incomingTransfers.count))") {
				if mediaService.incomingTransfers.isEmpty {
					Text("No incoming transfers")
						.foregroundColor(.secondary)
				}
				ForEach(Array(mediaService.incomingTransfers.values), id: \.id) { transfer in
					TransferDetailRow(transfer: transfer)
				}
			}

			Section("Completed Voice Memos (\(mediaService.completedVoiceMemos.count))") {
				ForEach(Array(mediaService.completedVoiceMemos.keys.sorted()), id: \.self) { key in
					if let data = mediaService.completedVoiceMemos[key] {
						HStack {
							Text("ID: \(key)")
								.font(.system(.caption, design: .monospaced))
							Spacer()
							Text("\(data.count) bytes")
								.font(.caption)
								.foregroundColor(.secondary)
						}
					}
				}
			}

			Section("Completed Images (\(mediaService.completedImages.count))") {
				ForEach(Array(mediaService.completedImages.keys.sorted()), id: \.self) { key in
					if let data = mediaService.completedImages[key] {
						HStack {
							Text("0x\(String(format: "%08X", key))")
								.font(.system(.caption, design: .monospaced))
							Spacer()
							Text("\(data.count) bytes")
								.font(.caption)
								.foregroundColor(.secondary)
						}
					}
				}
			}

			if let progress = mediaService.sendProgress {
				Section("Send Progress") {
					VStack {
						ProgressView(value: progress)
						Text(String(format: "%.0f%%", progress * 100))
							.font(.caption)
							.foregroundColor(.secondary)
					}
				}
			}
		}
	}
}

// MARK: - Transfer Detail Row

struct TransferDetailRow: View {
	let transfer: MediaTransfer

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack {
				Text("0x\(String(format: "%08X", transfer.id))")
					.font(.system(.caption, design: .monospaced))
					.fontWeight(.medium)
				Spacer()
				Text(transfer.isImageTransfer ? "Image" : "Voice Memo")
					.font(.caption2)
					.padding(.horizontal, 6)
					.padding(.vertical, 2)
					.background(transfer.isImageTransfer ? Color.orange.opacity(0.2) : Color.purple.opacity(0.2))
					.cornerRadius(4)
			}
			HStack {
				Text("!\(String(format: "%08x", transfer.fromNode))")
					.font(.system(.caption2, design: .monospaced))
				Image(systemName: "arrow.right")
					.font(.caption2)
				Text("!\(String(format: "%08x", transfer.toNode))")
					.font(.system(.caption2, design: .monospaced))
			}
			.foregroundColor(.secondary)
			ProgressView(value: transfer.progress)
			HStack {
				Text("\(transfer.receivedChunks.count)/\(transfer.totalChunks) chunks")
				Spacer()
				Text(transfer.startTime, style: .relative)
			}
			.font(.caption2)
			.foregroundColor(.secondary)
		}
		.padding(.vertical, 4)
	}
}

// MARK: - Test Runner Section

struct DebugTestRunnerSection: View {
	let accessoryManager: AccessoryManager
	@ObservedObject var telemetry = MeshReliableTelemetry.shared
	@State private var testLog: [TestLogEntry] = []
	@State private var isRunning = false
	@State private var testMessage = "MeshReliable test"
	@State private var selectedTestType: TestType = .text

	@Query(sort: \NodeInfoEntity.lastHeard, order: .reverse)
	private var nodes: [NodeInfoEntity]

	enum TestType: String, CaseIterable {
		case text = "Text"
		case broadcast = "Broadcast"
	}

	struct TestLogEntry: Identifiable {
		let id = UUID()
		let timestamp: Date
		let message: String
		let isError: Bool
	}

	var body: some View {
		List {
			Section("Test Controls") {
				Picker("Test Type", selection: $selectedTestType) {
					ForEach(TestType.allCases, id: \.self) { type in
						Text(type.rawValue).tag(type)
					}
				}

				TextField("Test message", text: $testMessage)
					.font(.system(.body, design: .monospaced))

				Button {
					runTest()
				} label: {
					HStack {
						if isRunning {
							ProgressView()
								.controlSize(.small)
						}
						Text(isRunning ? "Running..." : "Send Test Message")
					}
				}
				.disabled(isRunning || !accessoryManager.isConnected)

				if !accessoryManager.isConnected {
					Text("Connect to a device to run tests")
						.font(.caption)
						.foregroundColor(.orange)
				}
			}

			Section("Known Nodes (\(nodes.count))") {
				ForEach(nodes.prefix(20)) { node in
					HStack {
						VStack(alignment: .leading) {
							Text(node.user?.longName ?? "Unknown")
								.font(.caption)
							Text("!\(String(format: "%08x", node.num))")
								.font(.system(.caption2, design: .monospaced))
								.foregroundColor(.secondary)
						}
						Spacer()
						if let lastHeard = node.lastHeard, lastHeard > Date.distantPast {
							Text(lastHeard, style: .relative)
								.font(.caption2)
								.foregroundColor(.secondary)
						}
					}
				}
			}

			Section("Test Log (\(testLog.count))") {
				if testLog.isEmpty {
					Text("No tests run yet")
						.foregroundColor(.secondary)
				}
				ForEach(testLog.reversed()) { entry in
					HStack {
						Image(systemName: entry.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
							.foregroundColor(entry.isError ? .red : .green)
							.font(.caption)
						VStack(alignment: .leading) {
							Text(entry.message)
								.font(.system(.caption, design: .monospaced))
								.lineLimit(2)
							Text(entry.timestamp, style: .time)
								.font(.caption2)
								.foregroundColor(.secondary)
						}
					}
				}
			}
		}
	}

	private func runTest() {
		guard !isRunning else { return }
		isRunning = true

		Task {
			defer { isRunning = false }

			do {
				let timestamp = Int(Date().timeIntervalSince1970)
				let msg = "\(testMessage) #\(timestamp)"

				switch selectedTestType {
				case .text:
					// Send to broadcast on primary channel
					try await sendTextMessage(msg, toUserNum: 0, channel: 0)
					addLog("Sent broadcast: \(msg)")

				case .broadcast:
					// Send to all known channels
					for ch in Int32(0)..<Int32(3) {
						try await sendTextMessage(msg, toUserNum: 0, channel: ch)
						addLog("Sent ch\(ch): \(msg)")
						try await Task.sleep(for: .seconds(2))
					}
				}
			} catch {
				addLog("Error: \(error.localizedDescription)", isError: true)
			}
		}
	}

	private func sendTextMessage(_ text: String, toUserNum: Int64, channel: Int32) async throws {
		var dataMessage = DataMessage()
		dataMessage.payload = text.data(using: .utf8) ?? Data()
		dataMessage.portnum = .textMessageApp

		var meshPacket = MeshPacket()
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.to = toUserNum > 0 ? UInt32(toUserNum) : Constants.maximumNodeNum
		if let fromNum = accessoryManager.activeDeviceNum {
			meshPacket.from = UInt32(fromNum)
		}
		meshPacket.channel = UInt32(channel)
		meshPacket.decoded = dataMessage
		meshPacket.wantAck = true
		meshPacket.hopLimit = 7
		meshPacket.hopStart = 7

		var toRadio = ToRadio()
		toRadio.packet = meshPacket

		try await accessoryManager.send(toRadio, debugDescription: "Debug test message")

		MeshReliableTelemetry.shared.record(.messageSent, details: [
			"text": text,
			"channel": "\(channel)",
			"to": "\(toUserNum)",
			"source": "debugTestRunner"
		])
	}

	private func addLog(_ message: String, isError: Bool = false) {
		testLog.append(TestLogEntry(timestamp: Date(), message: message, isError: isError))
	}
}

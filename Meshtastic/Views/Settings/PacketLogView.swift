//
//  PacketLogView.swift
//  Meshtastic
//
//  Live packet/message log for debugging message delivery.
//

import SwiftUI

struct PacketLogView: View {
	@ObservedObject private var telemetry = MeshReliableTelemetry.shared
	@State private var filterType: FilterType = .all
	@State private var autoScroll = true

	enum FilterType: String, CaseIterable {
		case all = "All"
		case packets = "Packets"
		case messages = "Messages"
		case errors = "Errors"
	}

	private var filteredEvents: [TelemetryEvent] {
		switch filterType {
		case .all:
			return telemetry.events
		case .packets:
			return telemetry.events.filter {
				[.packetReceived, .fromRadioReceived].contains($0.type)
			}
		case .messages:
			return telemetry.events.filter {
				[.messageSent, .messageReceived, .groupMessageSent, .groupMessageReceived, .messageAcked, .groupAckReceived].contains($0.type)
			}
		case .errors:
			return telemetry.events.filter { $0.type == .error }
		}
	}

	private static let timeFormatter: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "HH:mm:ss.SSS"
		return f
	}()

	var body: some View {
		VStack(spacing: 0) {
			// Stats bar
			HStack {
				let received = telemetry.events.filter { $0.type == .messageReceived }.count
				let sent = telemetry.events.filter { $0.type == .messageSent }.count
				let acked = telemetry.events.filter { $0.type == .messageAcked }.count
				Text("RX:\(received)")
					.foregroundStyle(.green)
					.font(.caption.monospaced())
				Text("TX:\(sent)")
					.foregroundStyle(.blue)
					.font(.caption.monospaced())
				Text("ACK:\(acked)")
					.foregroundStyle(.orange)
					.font(.caption.monospaced())
				Spacer()
				Text("\(telemetry.events.count) events")
					.font(.caption.monospaced())
					.foregroundStyle(.secondary)
			}
			.padding(.horizontal)
			.padding(.vertical, 6)
			.background(Color(.systemGroupedBackground))

			// Filter picker
			Picker("Filter", selection: $filterType) {
				ForEach(FilterType.allCases, id: \.self) { type in
					Text(type.rawValue).tag(type)
				}
			}
			.pickerStyle(.segmented)
			.padding(.horizontal)
			.padding(.vertical, 6)

			// Event list
			ScrollViewReader { proxy in
				List {
					ForEach(filteredEvents) { event in
						eventRow(event)
							.id(event.id)
							.listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
					}
				}
				.listStyle(.plain)
				.font(.caption.monospaced())
				.onChange(of: telemetry.events.count) { _, _ in
					if autoScroll, let lastId = filteredEvents.last?.id {
						withAnimation {
							proxy.scrollTo(lastId, anchor: .bottom)
						}
					}
				}
			}
		}
		.navigationBarTitle("Packet Log", displayMode: .inline)
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Menu {
					Toggle("Auto-scroll", isOn: $autoScroll)
					Button("Clear Log", role: .destructive) {
						telemetry.clear()
					}
				} label: {
					Image(systemName: "ellipsis.circle")
				}
			}
		}
	}

	@ViewBuilder
	private func eventRow(_ event: TelemetryEvent) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack {
				Text(icon(for: event.type))
				Text(Self.timeFormatter.string(from: event.timestamp))
					.foregroundStyle(.secondary)
				Text(label(for: event.type))
					.foregroundStyle(color(for: event.type))
					.bold()
				Spacer()
				if let id = event.details["id"] {
					Text("#\(id)")
						.foregroundStyle(.secondary)
				}
			}

			// From/To line
			if let from = event.details["from"], let to = event.details["to"] {
				let fromHex = UInt32(from).map { $0.toHex() } ?? from
				let toHex = UInt32(to).map { $0.toHex() } ?? to
				Text("\(fromHex) -> \(toHex)")
					.foregroundStyle(.secondary)
			}

			// Portnum/variant info
			if let portnum = event.details["portnum"] {
				Text("port: \(portnum)")
					.foregroundStyle(.secondary)
			}
			if let variant = event.details["variant"] {
				Text("variant: \(variant)")
					.foregroundStyle(.secondary)
			}

			// Message text
			if let text = event.details["text"], !text.isEmpty {
				Text(text)
					.foregroundStyle(.primary)
					.lineLimit(2)
			}
		}
	}

	private func icon(for type: TelemetryEventType) -> String {
		switch type {
		case .messageSent: return "TX"
		case .messageReceived: return "RX"
		case .messageAcked: return "OK"
		case .groupMessageSent: return "GT"
		case .groupMessageReceived: return "GR"
		case .groupAckReceived: return "GA"
		case .voiceMemoSent, .voiceMemoReceived: return "VM"
		case .imageSent, .imageReceived: return "IM"
		case .packetReceived: return "PK"
		case .fromRadioReceived: return "FR"
		case .bleEvent: return "BT"
		case .uiAction: return "UI"
		case .error: return "!!"
		default: return "--"
		}
	}

	private func label(for type: TelemetryEventType) -> String {
		switch type {
		case .messageSent: return "SENT"
		case .messageReceived: return "RECV"
		case .messageAcked: return "ACK"
		case .groupMessageSent: return "GRP_SENT"
		case .groupMessageReceived: return "GRP_RECV"
		case .groupAckReceived: return "GRP_ACK"
		case .voiceMemoSent: return "VOICE_TX"
		case .voiceMemoReceived: return "VOICE_RX"
		case .imageSent: return "IMG_TX"
		case .imageReceived: return "IMG_RX"
		case .packetReceived: return "PACKET"
		case .fromRadioReceived: return "FROM_RADIO"
		case .bleEvent: return "BLE"
		case .uiAction: return "UI"
		case .error: return "ERROR"
		default: return type.rawValue
		}
	}

	private func color(for type: TelemetryEventType) -> Color {
		switch type {
		case .messageSent, .groupMessageSent, .voiceMemoSent, .imageSent: return .blue
		case .messageReceived, .groupMessageReceived, .voiceMemoReceived, .imageReceived: return .green
		case .messageAcked, .groupAckReceived: return .orange
		case .packetReceived, .fromRadioReceived: return .cyan
		case .bleEvent: return .purple
		case .uiAction: return .mint
		case .error: return .red
		default: return .secondary
		}
	}
}

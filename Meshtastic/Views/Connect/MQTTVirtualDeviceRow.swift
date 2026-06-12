//
//  MQTTVirtualDeviceRow.swift
//  Meshtastic
//
//  Row view for a device available via Virtual MQTT connection.
//

import SwiftUI
import SwiftData
import OSLog

struct MQTTVirtualSection: View {
	@Environment(\.modelContext) private var context
	@EnvironmentObject var accessoryManager: AccessoryManager

	var body: some View {
		let mqttDevices = fetchMQTTDevices()
		if !mqttDevices.isEmpty {
			Section(header: Text("Available via MQTT").font(.title)) {
				ForEach(mqttDevices, id: \.num) { nodeInfo in
					MQTTVirtualDeviceRow(nodeInfo: nodeInfo)
				}
			}
		}
	}

	private func fetchMQTTDevices() -> [NodeInfoEntity] {
		let descriptor = FetchDescriptor<NodeInfoEntity>(
			predicate: #Predicate<NodeInfoEntity> {
				$0.mqttConfig != nil && $0.myInfo != nil
			}
		)
		do {
			let nodes = try context.fetch(descriptor)
			return nodes.filter { $0.mqttConfig?.enabled == true }
		} catch {
			return []
		}
	}
}

struct MQTTVirtualDeviceRow: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	let nodeInfo: NodeInfoEntity

	var body: some View {
		HStack {
			Image(systemName: "cloud.fill")
				.imageScale(.large)
				.foregroundColor(.blue)
				.padding(.trailing)
			VStack(alignment: .leading) {
				Button(action: {
					Task {
						do {
							try await accessoryManager.connectToVirtualMQTT(nodeNum: nodeInfo.num)
						} catch {
							Logger.mqtt.error("[MQTT Virtual] Connect failed: \(error.localizedDescription)")
						}
					}
				}) {
					Text(nodeInfo.user?.longName ?? "Unknown Device")
						.font(.callout)
				}
				HStack(alignment: .center, spacing: 4) {
					Image(systemName: "cloud.fill")
						.font(.caption)
						.foregroundColor(.blue)
					Text("MQTT Virtual")
						.font(.caption)
						.foregroundColor(.secondary)
					if let address = nodeInfo.mqttConfig?.address, !address.isEmpty {
						Text("(\(address))")
							.font(.caption2)
							.foregroundColor(.secondary)
					}
				}
				.padding(.top, 1)
			}
			Spacer()
			if let shortName = nodeInfo.user?.shortName {
				CircleText(
					text: shortName.addingVariationSelectors,
					color: Color(UIColor(hex: UInt32(nodeInfo.num))),
					circleSize: 35
				)
			}
		}
		.padding([.bottom, .top])
	}
}

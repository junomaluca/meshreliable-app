//
//  CreateGroupSheet.swift
//  Meshtastic
//
//  Sheet for creating a new acknowledged group conversation.
//

import SwiftUI
import SwiftData
import OSLog
import CoreLocation

struct CreateGroupSheet: View {

	@Environment(\.dismiss) var dismiss
	@Environment(\.modelContext) private var context
	@EnvironmentObject var accessoryManager: AccessoryManager
	@State private var groupName: String = ""
	@State private var selectedNodes: Set<Int64> = []
	@State private var isCreating = false
	@State private var errorMessage: String?
	@State private var showError = false
	@State private var searchText: String = ""

	@Query(sort: \NodeInfoEntity.lastHeard, order: .reverse) private var nodes: [NodeInfoEntity]

	private static let distanceFormatter: MeasurementFormatter = {
		let f = MeasurementFormatter()
		f.unitOptions = .naturalScale
		f.numberFormatter.maximumFractionDigits = 1
		return f
	}()

	/// The connected device's node number (the reference point for proximity ranking).
	private var connectedNodeNum: Int64? {
		if let num = accessoryManager.activeDeviceNum, num != 0 { return num }
		let pref = Int64(UserDefaults.preferredPeripheralNum)
		return pref > 0 ? pref : nil
	}

	/// The most recent valid GPS fix for a node, as a CLLocation (nil if unknown).
	private func location(of node: NodeInfoEntity) -> CLLocation? {
		let pos = node.positions.first(where: { $0.latest && $0.latitudeI != 0 && $0.longitudeI != 0 })
			?? node.positions.last(where: { $0.latitudeI != 0 && $0.longitudeI != 0 })
		guard let coord = pos?.nodeCoordinate else { return nil }
		return CLLocation(latitude: coord.latitude, longitude: coord.longitude)
	}

	/// Proximity is measured from the connected node; fall back to the phone's own location.
	private var referenceLocation: CLLocation? {
		if let myNum = connectedNodeNum,
		   let myNode = nodes.first(where: { $0.num == myNum }),
		   let loc = location(of: myNode) {
			return loc
		}
		return LocationsHandler.shared.locationsArray.last
	}

	/// Candidate members, ranked nearest-first by geographic distance to the connected node.
	/// Nodes with no known position sort last; ties keep the lastHeard order (stable).
	/// Case-insensitive match on a node's long name, short name, hex id, or decimal number.
	private func matchesSearch(_ node: NodeInfoEntity) -> Bool {
		let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
		guard !q.isEmpty else { return true }
		let name = (node.user?.longName ?? "").lowercased()
		let short = (node.user?.shortName ?? "").lowercased()
		let hex = node.num.toHex().lowercased()
		let dec = String(node.num)
		return name.contains(q) || short.contains(q) || hex.contains(q) || dec.contains(q)
	}

	private var availableNodes: [NodeInfoEntity] {
		let myNum = connectedNodeNum
		var seen = Set<Int64>()
		let filtered = nodes.filter { node in
			guard node.user != nil else { return false }
			if let myNum, node.num == myNum { return false }
			guard seen.insert(node.num).inserted else { return false }
			return matchesSearch(node)
		}
		guard let ref = referenceLocation else { return filtered }
		return filtered.enumerated().sorted { lhs, rhs in
			let da = location(of: lhs.element).map { $0.distance(from: ref) } ?? .greatestFiniteMagnitude
			let db = location(of: rhs.element).map { $0.distance(from: ref) } ?? .greatestFiniteMagnitude
			if da != db { return da < db }
			return lhs.offset < rhs.offset
		}.map { $0.element }
	}

	/// Formatted "nearby" distance for a node row, or nil if its position is unknown.
	private func distanceText(for node: NodeInfoEntity) -> String? {
		guard let ref = referenceLocation, let loc = location(of: node) else { return nil }
		return Self.distanceFormatter.string(from: Measurement(value: loc.distance(from: ref), unit: UnitLength.meters))
	}

	var body: some View {
		NavigationStack {
			Form {
				Section("Group Name") {
					TextField("Enter group name", text: $groupName)
						.accessibilityIdentifier("groupNameField")
				}

				Section("Members (\(selectedNodes.count) selected)") {
					if availableNodes.isEmpty {
						Text("No nodes available")
							.foregroundColor(.secondary)
					} else {
						ForEach(availableNodes) { node in
							Button {
								if selectedNodes.contains(node.num) {
									selectedNodes.remove(node.num)
								} else {
									selectedNodes.insert(node.num)
								}
							} label: {
								HStack {
									VStack(alignment: .leading) {
										Text(node.user?.longName ?? node.num.toHex())
											.foregroundColor(.primary)
										HStack(spacing: 6) {
											Text(node.num.toHex())
											if let dist = distanceText(for: node) {
												Text("· \(dist)")
											}
										}
										.font(.caption)
										.foregroundColor(.secondary)
									}
									Spacer()
									if selectedNodes.contains(node.num) {
										Image(systemName: "checkmark.circle.fill")
											.foregroundColor(.accentColor)
									} else {
										Image(systemName: "circle")
											.foregroundColor(.secondary)
									}
								}
							}
						}
					}
				}
			}
			.navigationTitle("New Group")
			.navigationBarTitleDisplayMode(.inline)
			.searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search by name or number")
			.autocorrectionDisabled()
			.textInputAutocapitalization(.never)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
						.disabled(isCreating)
				}
				ToolbarItem(placement: .confirmationAction) {
					if isCreating {
						ProgressView()
					} else {
						Button("Create") {
							createGroup()
						}
						.disabled(groupName.isEmpty || selectedNodes.isEmpty)
					}
				}
			}
			.interactiveDismissDisabled(isCreating)
			.alert("Error", isPresented: $showError) {
				Button("OK") {}
			} message: {
				Text(errorMessage ?? "Failed to create group")
			}
		}
	}

	private func createGroup() {
		isCreating = true
		let members = selectedNodes.map { UInt32($0) }
		Task {
			do {
				_ = try await GroupMessageService.shared.createGroup(
					name: groupName,
					channelIndex: 0,
					members: members,
					accessoryManager: accessoryManager
				)
				await MainActor.run {
					dismiss()
				}
			} catch {
				Logger.mesh.error("Failed to create group: \(error.localizedDescription)")
				await MainActor.run {
					errorMessage = error.localizedDescription
					showError = true
					isCreating = false
				}
			}
		}
	}
}

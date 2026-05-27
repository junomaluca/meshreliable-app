//
//  CreateGroupSheet.swift
//  Meshtastic
//
//  Sheet for creating a new acknowledged group conversation.
//

import SwiftUI
import SwiftData
import OSLog

struct CreateGroupSheet: View {

	@Environment(\.dismiss) var dismiss
	@Environment(\.modelContext) private var context
	@EnvironmentObject var accessoryManager: AccessoryManager
	@State private var groupName: String = ""
	@State private var selectedNodes: Set<Int64> = []
	@State private var isCreating = false

	@Query(sort: \NodeInfoEntity.lastHeard, order: .reverse) private var nodes: [NodeInfoEntity]

	private var availableNodes: [NodeInfoEntity] {
		let myNum = Int64(UserDefaults.preferredPeripheralNum)
		return nodes.filter { $0.num != myNum && $0.user != nil }
	}

	var body: some View {
		NavigationStack {
			Form {
				Section("Group Name") {
					TextField("Enter group name", text: $groupName)
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
										Text(node.num.toHex())
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
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Create") {
						createGroup()
					}
					.disabled(groupName.isEmpty || selectedNodes.isEmpty || isCreating)
				}
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
				isCreating = false
			}
		}
	}
}

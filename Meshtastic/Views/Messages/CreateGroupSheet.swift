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
	@State private var errorMessage: String?
	@State private var showError = false

	@Query(sort: \NodeInfoEntity.lastHeard, order: .reverse) private var nodes: [NodeInfoEntity]

	private var availableNodes: [NodeInfoEntity] {
		let myNum = Int64(UserDefaults.preferredPeripheralNum)
		var seen = Set<Int64>()
		return nodes.filter { node in
			guard node.num != myNum && node.user != nil else { return false }
			return seen.insert(node.num).inserted
		}
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

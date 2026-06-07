//
//  AddMemberSheet.swift
//  Meshtastic
//
//  Sheet for adding a new member to an existing group conversation.
//

import SwiftUI
import SwiftData
import OSLog

struct AddMemberSheet: View {

	@Environment(\.dismiss) var dismiss
	@Environment(\.modelContext) private var context
	@EnvironmentObject var accessoryManager: AccessoryManager
	@ObservedObject private var groupService = GroupMessageService.shared

	let groupId: UInt32

	@State private var selectedNode: Int64?
	@State private var isAdding = false
	@State private var errorMessage: String?
	@State private var showError = false

	@Query(sort: \NodeInfoEntity.lastHeard, order: .reverse) private var nodes: [NodeInfoEntity]

	private var existingMembers: Set<UInt32> {
		Set(groupService.joinedGroups[groupId]?.members ?? [])
	}

	private var availableNodes: [NodeInfoEntity] {
		let myNum = Int64(UserDefaults.preferredPeripheralNum)
		var seen = Set<Int64>()
		return nodes.filter { node in
			guard node.num != myNum && node.user != nil && !existingMembers.contains(UInt32(node.num)) else { return false }
			return seen.insert(node.num).inserted
		}
	}

	var body: some View {
		NavigationStack {
			List {
				if availableNodes.isEmpty {
					Text("No available nodes to add")
						.foregroundColor(.secondary)
				} else {
					ForEach(availableNodes) { node in
						Button {
							selectedNode = node.num
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
								if selectedNode == node.num {
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
			.navigationTitle("Add Member")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
						.disabled(isAdding)
				}
				ToolbarItem(placement: .confirmationAction) {
					if isAdding {
						ProgressView()
					} else {
						Button("Add") {
							addMember()
						}
						.disabled(selectedNode == nil)
					}
				}
			}
			.interactiveDismissDisabled(isAdding)
			.alert("Error", isPresented: $showError) {
				Button("OK") {}
			} message: {
				Text(errorMessage ?? "Failed to add member")
			}
		}
	}

	private func addMember() {
		guard let nodeNum = selectedNode else { return }
		isAdding = true
		Task {
			do {
				try await groupService.addMember(
					nodeNum: UInt32(nodeNum),
					to: groupId,
					accessoryManager: accessoryManager
				)
				await MainActor.run {
					dismiss()
				}
			} catch {
				Logger.mesh.error("Failed to add member: \(error.localizedDescription)")
				await MainActor.run {
					errorMessage = error.localizedDescription
					showError = true
					isAdding = false
				}
			}
		}
	}
}

//
//  JoinGroupSheet.swift
//  Meshtastic
//
//  Sheet for joining an existing group by entering its group ID.
//

import SwiftUI
import OSLog

struct JoinGroupSheet: View {

	@Environment(\.dismiss) var dismiss
	@EnvironmentObject var accessoryManager: AccessoryManager
	@State private var groupKeyText: String = ""
	@State private var isJoining = false
	@State private var errorMessage: String?

	var body: some View {
		NavigationStack {
			Form {
				Section("Group Key") {
					TextField("Enter group key (hex)", text: $groupKeyText)
						.autocapitalization(.none)
						.disableAutocorrection(true)
						.font(.system(.body, design: .monospaced))
					Text("Ask the group creator for the key.")
						.font(.caption)
						.foregroundColor(.secondary)
				}

				if let errorMessage {
					Section {
						Text(errorMessage)
							.foregroundColor(.red)
							.font(.callout)
					}
				}
			}
			.navigationTitle("Join Group")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Join") {
						joinGroup()
					}
					.disabled(groupKeyText.isEmpty || isJoining)
				}
			}
		}
	}

	private func joinGroup() {
		errorMessage = nil
		let cleaned = groupKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
			.replacingOccurrences(of: "0x", with: "")
			.replacingOccurrences(of: "!", with: "")

		guard let groupId = UInt32(cleaned, radix: 16), groupId > 0 else {
			errorMessage = "Invalid group key. Enter a hex value (e.g. 1a2b3c4d)."
			return
		}

		if GroupMessageService.shared.joinedGroups[groupId] != nil {
			errorMessage = "You are already in this group."
			return
		}

		isJoining = true
		Task {
			do {
				try await GroupMessageService.shared.joinGroup(
					groupId: groupId,
					channelIndex: 0,
					accessoryManager: accessoryManager
				)
				await MainActor.run {
					dismiss()
				}
			} catch {
				Logger.mesh.error("Failed to join group: \(error.localizedDescription)")
				errorMessage = "Failed to join: \(error.localizedDescription)"
				isJoining = false
			}
		}
	}
}

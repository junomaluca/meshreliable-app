//
//  GroupConversationView.swift
//  Meshtastic
//
//  Displays messages in a group conversation with per-member ACK status.
//

import SwiftUI
import SwiftData
import OSLog

struct GroupConversationView: View {

	@EnvironmentObject var accessoryManager: AccessoryManager
	@Environment(\.modelContext) private var context
	@ObservedObject private var groupService = GroupMessageService.shared
	@Environment(\.dismiss) private var dismiss
	@FocusState private var messageFieldFocused: Bool
	@State private var typingMessage: String = ""
	@State private var totalBytes: Int = 0
	@State private var showingLeaveConfirmation = false
	@State private var showCopiedNotification = false

	let groupId: UInt32

	private var group: GroupMessageService.GroupInfo? {
		groupService.joinedGroups[groupId]
	}

	private var messages: [GroupMessageService.GroupMessageEntry] {
		groupService.groupMessages[groupId] ?? []
	}

	private var myNodeNum: UInt32 {
		UInt32(UserDefaults.preferredPeripheralNum)
	}

	var body: some View {
		VStack(spacing: 0) {
			ScrollViewReader { scrollView in
				ScrollView {
					LazyVStack(spacing: 4) {
						ForEach(messages) { message in
							GroupMessageRow(
								message: message,
								isFromMe: message.fromNode == myNodeNum,
								context: context
							)
							.id(message.messageId)
						}
						Color.clear
							.frame(height: 1)
							.id("bottomAnchor")
					}
					.padding(.horizontal, 8)
				}
				.defaultScrollAnchor(.bottom)
				.scrollDismissesKeyboard(.immediately)
				.onAppear {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
						scrollView.scrollTo("bottomAnchor", anchor: .bottom)
					}
				}
				.onChange(of: messages.count) {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
						withAnimation {
							scrollView.scrollTo("bottomAnchor", anchor: .bottom)
						}
					}
				}
			}

			// Message input
			groupMessageInput
		}
		.navigationBarTitleDisplayMode(.inline)
		.onAppear {
			groupService.markAsRead(groupId: groupId)
		}
		.onChange(of: messages.count) {
			groupService.markAsRead(groupId: groupId)
		}
		.toolbar {
			ToolbarItem(placement: .principal) {
				HStack {
					Image(systemName: "person.3.fill")
						.foregroundColor(.accentColor)
					Text(group?.name ?? "Group")
						.font(.headline)
				}
			}
			ToolbarItem(placement: .navigationBarTrailing) {
				if let group {
					Menu {
						Section("Members (\(group.members.count))") {
							ForEach(group.members, id: \.self) { nodeNum in
								Label(nodeName(for: nodeNum), systemImage: nodeNum == myNodeNum ? "person.fill" : "person")
							}
						}
						Section {
							Button {
								UIPasteboard.general.string = group.groupId.toHex()
								showCopiedNotification = true
								DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
									showCopiedNotification = false
								}
							} label: {
								Label("Copy Key: \(group.groupId.toHex())", systemImage: "doc.on.doc")
							}
						}
						Section {
							Button(role: .destructive) {
								showingLeaveConfirmation = true
							} label: {
								Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
							}
						}
					} label: {
						Image(systemName: "info.circle")
					}
				}
			}
		}
		.confirmationDialog("Leave Group?", isPresented: $showingLeaveConfirmation, titleVisibility: .visible) {
			Button("Leave", role: .destructive) {
				Task {
					do {
						try await groupService.leaveGroup(groupId: groupId, accessoryManager: accessoryManager)
					} catch {
						groupService.joinedGroups.removeValue(forKey: groupId)
						groupService.groupMessages.removeValue(forKey: groupId)
						groupService.saveState()
					}
					dismiss()
				}
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("You will no longer receive messages from this group.")
		}
		.overlay(alignment: .top) {
			if showCopiedNotification {
				Text("Key copied to clipboard")
					.font(.callout)
					.fontWeight(.medium)
					.padding(.horizontal, 16)
					.padding(.vertical, 10)
					.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
					.transition(.move(edge: .top).combined(with: .opacity))
					.animation(.easeInOut, value: showCopiedNotification)
					.padding(.top, 8)
			}
		}
	}

	// MARK: - Message Input

	private var groupMessageInput: some View {
		HStack(alignment: .bottom) {
			TextField("Message", text: $typingMessage, axis: .vertical)
				.frame(minHeight: 36)
				.padding(.horizontal, 16)
				.padding(.vertical, 8)
				.background(
					RoundedRectangle(cornerRadius: 20)
						.strokeBorder(.tertiary, lineWidth: 1)
				)
				.focused($messageFieldFocused)
				.onChange(of: typingMessage) {
					totalBytes = typingMessage.utf8.count
				}
				.onSubmit {
					sendMessage()
				}

			Button {
				sendMessage()
			} label: {
				Image(systemName: "arrow.up.circle.fill")
					.font(.title2)
					.foregroundColor(typingMessage.isEmpty ? .secondary : .accentColor)
			}
			.disabled(typingMessage.isEmpty || totalBytes > 200)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
	}

	// MARK: - Send

	private func sendMessage() {
		guard !typingMessage.isEmpty, let group else { return }
		let text = typingMessage
		typingMessage = ""

		Task {
			do {
				try await groupService.sendGroupText(
					text: text,
					groupId: groupId,
					channelIndex: Int32(group.channelIndex),
					members: group.members,
					accessoryManager: accessoryManager
				)
			} catch {
				Logger.mesh.error("Failed to send group message: \(error.localizedDescription)")
			}
		}
	}

	// MARK: - Helpers

	private func nodeName(for nodeNum: UInt32) -> String {
		if let node = getNodeInfo(id: Int64(nodeNum), context: context) {
			return node.user?.longName ?? nodeNum.toHex()
		}
		return nodeNum.toHex()
	}
}

// MARK: - Group Message Row

struct GroupMessageRow: View {
	let message: GroupMessageService.GroupMessageEntry
	let isFromMe: Bool
	let context: ModelContext

	var body: some View {
		VStack(alignment: isFromMe ? .trailing : .leading, spacing: 2) {
			if message.type == .groupJoin || message.type == .groupLeave {
				systemMessageView
			} else {
				messageView
			}
		}
		.frame(maxWidth: .infinity, alignment: isFromMe ? .trailing : .leading)
		.padding(.vertical, 2)
	}

	private var systemMessageView: some View {
		HStack {
			Spacer()
			Text(message.text)
				.font(.caption)
				.foregroundColor(.secondary)
				.italic()
				.padding(.vertical, 4)
			Spacer()
		}
	}

	private var messageView: some View {
		VStack(alignment: isFromMe ? .trailing : .leading, spacing: 2) {
			if !isFromMe {
				Text(senderName)
					.font(.caption2)
					.foregroundColor(.secondary)
			}

			HStack(alignment: .bottom, spacing: 4) {
				if isFromMe { Spacer(minLength: 60) }

				VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
					Text(message.text)
						.padding(.horizontal, 12)
						.padding(.vertical, 8)
						.background(isFromMe ? Color.accentColor : Color(.systemGray5))
						.foregroundColor(isFromMe ? .white : .primary)
						.clipShape(RoundedRectangle(cornerRadius: 16))

					// ACK status for outgoing messages
					if isFromMe, let ackStatus = message.ackStatus {
						ackStatusView(ackStatus)
					}
				}

				if !isFromMe { Spacer(minLength: 60) }
			}

			Text(message.timestamp, style: .time)
				.font(.caption2)
				.foregroundColor(.secondary)
		}
	}

	@ViewBuilder
	private func ackStatusView(_ status: GroupAckStatus) -> some View {
		HStack(spacing: 4) {
			if status.allAcked {
				Image(systemName: "checkmark.circle.fill")
					.foregroundColor(.green)
					.font(.caption2)
				Text("All received")
					.font(.caption2)
					.foregroundColor(.green)
			} else {
				Image(systemName: "checkmark.circle")
					.foregroundColor(.secondary)
					.font(.caption2)
				Text("\(status.ackedBy.count)/\(status.members.count)")
					.font(.caption2)
					.foregroundColor(.secondary)
			}
		}
	}

	private var senderName: String {
		if let node = getNodeInfo(id: Int64(message.fromNode), context: context) {
			return node.user?.shortName ?? message.fromNode.toHex()
		}
		return message.fromNode.toHex()
	}
}

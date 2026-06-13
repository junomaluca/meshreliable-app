//
//  GroupConversationView.swift
//  Meshtastic
//
//  Displays messages in a group conversation with per-member ACK status.
//

import SwiftUI
import SwiftData
import PhotosUI
import OSLog

struct GroupConversationView: View {

	@EnvironmentObject var accessoryManager: AccessoryManager
	@Environment(\.modelContext) private var context
	@ObservedObject private var groupService = GroupMessageService.shared
	@ObservedObject private var meshReliable = MeshReliableService.shared
	@Environment(\.dismiss) private var dismiss
	@FocusState private var messageFieldFocused: Bool
	@State private var typingMessage: String = ""
	@State private var totalBytes: Int = 0
	@State private var showingLeaveConfirmation = false
	@State private var showCopiedNotification = false
	@State private var sendPositionWithMessage = false
	@State private var showToolbar = false
	@State private var showAddMember = false
	@State private var sendErrorMessage: String?
	@State private var showVoiceMemoRecorder = false
	@State private var showImagePicker = false
	@State private var selectedPhotoItem: PhotosPickerItem?

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

	private var groupDestination: MessageDestination? {
		guard let group else { return nil }
		return .group(groupId: groupId, channelIndex: Int32(group.channelIndex))
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
						// Pending outgoing images for this group
						if let group {
							ForEach(meshReliable.pendingImages.filter { $0.channel == Int32(group.channelIndex) && $0.toUserNum == 0 }) { pending in
								if let uiImage = UIImage(data: pending.imageData) {
									InlineImageBubble(
										image: uiImage,
										isFromMe: true,
										caption: nil,
										progress: pending.isSending ? pending.progress : nil,
										error: pending.error,
										onRetry: {
											meshReliable.retryPendingImage(id: pending.id, accessoryManager: accessoryManager)
										}
									)
								}
							}
							// Pending outgoing voice memos for this group
							ForEach(meshReliable.pendingVoiceMemos.filter { $0.channel == Int32(group.channelIndex) && $0.toUserNum == 0 }) { pending in
								InlineVoiceMemoBubble(
									duration: pending.duration,
									isFromMe: true,
									audioData: pending.pcmData,
									progress: pending.isSending ? pending.progress : nil,
									error: pending.error,
									onRetry: {
										meshReliable.retryPendingVoiceMemo(id: pending.id, accessoryManager: accessoryManager)
									}
								)
							}
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
								showAddMember = true
							} label: {
								Label("Add Member", systemImage: "person.badge.plus")
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
		.sheet(isPresented: $showAddMember) {
			AddMemberSheet(groupId: groupId)
		}
		.confirmationDialog("Leave Group?", isPresented: $showingLeaveConfirmation, titleVisibility: .visible) {
			Button("Leave", role: .destructive) {
				Task {
					do {
						try await groupService.leaveGroup(groupId: groupId, accessoryManager: accessoryManager)
					} catch {
						groupService.joinedGroups.removeValue(forKey: groupId)
						groupService.groupMessages.removeValue(forKey: groupId)
						groupService.groupRosters.removeValue(forKey: groupId)
						groupService.unreadCounts.removeValue(forKey: groupId)
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
			if let errorMsg = sendErrorMessage {
				HStack {
					Image(systemName: "exclamationmark.triangle.fill")
						.foregroundColor(.white)
					Text(errorMsg)
						.font(.callout)
						.foregroundColor(.white)
					Spacer()
					Button {
						sendErrorMessage = nil
					} label: {
						Image(systemName: "xmark.circle.fill")
							.foregroundColor(.white.opacity(0.8))
					}
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 10)
				.background(Color.red, in: RoundedRectangle(cornerRadius: 10))
				.padding(.horizontal, 8)
				.padding(.top, 8)
				.transition(.move(edge: .top).combined(with: .opacity))
				.animation(.easeInOut, value: sendErrorMessage)
			}
		}
	}

	// MARK: - Message Input

	private var groupMessageInput: some View {
		VStack(spacing: 0) {
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

				if !typingMessage.isEmpty {
					Button {
						sendMessage()
					} label: {
						Image(systemName: "arrow.up.circle.fill")
							.font(.title2)
							.foregroundColor(.accentColor)
					}
					.disabled(totalBytes > 200 || !accessoryManager.isConnected)
				}
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 8)

			if showToolbar {
				Divider()
				groupComposeToolbar
					.padding(.horizontal, 15)
					.padding(.vertical, 8)
					.background(.bar)
			}
		}
		.onChange(of: messageFieldFocused) { _, focused in
			if focused {
				showToolbar = true
			} else {
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
					if !messageFieldFocused {
						showToolbar = false
					}
				}
			}
		}
	}

	private var groupComposeToolbar: some View {
		HStack {
			Spacer()
			AlertButton(action: {
				// Match the DM alert bell exactly (visible text + BEL char), not a bare \u{7}
				// which sent a blank-looking message.
				typingMessage += "\u{1F514} Alert Bell Character! \u{7}"
				sendMessage()
			}, compact: true)
			Spacer()
			RequestPositionButton(action: {
				let userLongName = accessoryManager.activeConnection?.device.longName ?? "Unknown"
				sendPositionWithMessage = true
				typingMessage = "\u{1F4CD} " + userLongName + " has shared their position with the group."
				sendMessage()
			}, compact: true)
			Spacer()
			VoiceMemoButton(action: { showVoiceMemoRecorder = true }, compact: true)
			Spacer()
			ImageButton(action: { showImagePicker = true }, compact: true)
			Spacer()
			TextMessageSize(maxbytes: 200, totalBytes: totalBytes, compact: true)
		}
		.sheet(isPresented: $showVoiceMemoRecorder) {
			if let dest = groupDestination {
				VoiceMemoRecorder(destination: dest)
			}
		}
		.photosPicker(isPresented: $showImagePicker, selection: $selectedPhotoItem, matching: .images)
		.onChange(of: selectedPhotoItem) { _, newItem in
			handlePhotoSelection(newItem)
		}
	}

	// MARK: - Send

	private func sendMessage() {
		guard !typingMessage.isEmpty, let group else { return }
		let text = typingMessage
		typingMessage = ""

		Task {
			// Signal media uploads to pause while text is sent
			meshReliable.signalTextSending()
			defer { meshReliable.signalTextSent() }

			do {
				try await groupService.sendGroupText(
					text: text,
					groupId: groupId,
					channelIndex: Int32(group.channelIndex),
					members: group.members,
					accessoryManager: accessoryManager
				)
				sendErrorMessage = nil
			} catch {
				Logger.mesh.error("Failed to send group message: \(error.localizedDescription)")
				typingMessage = text
				sendErrorMessage = "Failed to send: \(error.localizedDescription)"
			}
		}
	}

	// MARK: - Photo Selection

	private func handlePhotoSelection(_ item: PhotosPickerItem?) {
		guard let item, let group else { return }
		Task {
			if let data = try? await item.loadTransferable(type: Data.self),
			   let image = UIImage(data: data) {
				meshReliable.sendImageInline(
					image: image,
					toUserNum: 0, // broadcast
					channel: Int32(group.channelIndex),
					accessoryManager: accessoryManager
				)
			}
			selectedPhotoItem = nil
		}
	}

	// MARK: - Helpers

	private func nodeName(for nodeNum: UInt32) -> String {
		if let node = getNodeInfo(id: Int64(nodeNum), context: context) {
			let name = node.user?.longName ?? nodeNum.toHex()
			if let region = node.loRaConfig?.regionCode, region != 0 {
				let band = BandGroup.from(regionCode: region)
				return "\(name) (\(band.label))"
			}
			return name
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
		HStack(spacing: 3) {
			if status.allAcked {
				// Delivered to every member — same symbol a DM shows when ACKed.
				Image(systemName: "checkmark.circle.fill")
					.font(.system(size: 12))
					.foregroundColor(.green)
			} else if !status.ackedBy.isEmpty {
				// Delivered to some members — DM ACK symbol + how many.
				Image(systemName: "checkmark.circle.fill")
					.font(.system(size: 12))
					.foregroundColor(.green)
				Text("\(status.ackedBy.count)/\(status.members.count)")
					.font(.caption2)
					.foregroundColor(.secondary)
			} else {
				// Sent, waiting for delivery — same as a DM awaiting its ACK.
				Image(systemName: "antenna.radiowaves.left.and.right")
					.font(.system(size: 11))
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

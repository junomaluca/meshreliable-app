//
//  UserMessageRow.swift
//  MeshtasticApple
//
//  Copyright(c) Garth Vander Houwen 10/1/2025
//

import SwiftData
import MeshtasticProtobufs
import SwiftUI

struct UserMessageRow: View {

	@EnvironmentObject var appState: AppState
	@Environment(\.modelContext) private var context
	@Bindable var message: MessageEntity
	let allMessages: [MessageEntity]
	let previousMessage: MessageEntity?
	let preferredPeripheralNum: Int
	let user: UserEntity // The direct message user
	@Binding var replyMessageId: Int64
	@FocusState.Binding var messageFieldFocused: Bool
	@Binding var messageToHighlight: Int64
	let scrollView: ScrollViewProxy
	let onInteractionComplete: () -> Void
	let onTapback: (MessageEntity) -> Void

	private var isCurrentUser: Bool {
		Int64(preferredPeripheralNum) == message.fromUser?.num
	}

	init(
		message: MessageEntity,
		allMessages: [MessageEntity],
		previousMessage: MessageEntity?,
		preferredPeripheralNum: Int,
		user: UserEntity,
		replyMessageId: Binding<Int64>,
		messageFieldFocused: FocusState<Bool>.Binding,
		messageToHighlight: Binding<Int64>,
		scrollView: ScrollViewProxy,
		onInteractionComplete: @escaping () -> Void,
		onTapback: @escaping (MessageEntity) -> Void
	) {
		// Initialize ObservedObject with the concrete instance
		self.message = message
		self.allMessages = allMessages
		self.previousMessage = previousMessage
		self.preferredPeripheralNum = preferredPeripheralNum
		self.user = user
		self._replyMessageId = replyMessageId
		self._messageFieldFocused = messageFieldFocused
		self._messageToHighlight = messageToHighlight
		self.scrollView = scrollView
		self.onInteractionComplete = onInteractionComplete
		self.onTapback = onTapback
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {

			// Timestamp Header
			if message.displayTimestamp(aboveMessage: previousMessage) {
				Text(message.timestamp.formatted(date: .abbreviated, time: .shortened))
					.font(.caption)
					.foregroundColor(.gray)
					.frame(maxWidth: .infinity, alignment: .center)
					.padding(.vertical, 5)
			}

			// Reply Message Block
			if message.replyID > 0 {
				let messageReply = allMessages.first(where: { $0.messageId == message.replyID })

				HStack {
					Spacer(minLength: isCurrentUser ? 50 : 0)

					Button {
						if let messageNum = messageReply?.messageId {
							withAnimation(.easeInOut(duration: 0.5)) {
								messageToHighlight = messageNum
							}
							scrollView.scrollTo(messageNum, anchor: .center)
							Task {
								DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
									withAnimation(.easeInOut(duration: 0.5)) {
										messageToHighlight = -1
									}
								}
							}
						}
					} label: {
						HStack {
							Image(systemName: "arrowshape.turn.up.left.fill")
								.symbolRenderingMode(.hierarchical).imageScale(.large)
								.foregroundColor(.accentColor).padding(.leading)
							Text(messageReply?.displayedPayload ?? "EMPTY MESSAGE").foregroundColor(.accentColor).font(.caption2)
						}
						.padding(10)
						.overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.blue, lineWidth: 0.5))
					}
					if !isCurrentUser { Spacer(minLength: 50) }
				}
			}

			HStack(alignment: .bottom) {
				if isCurrentUser { Spacer(minLength: 50) }

				// Node Detail Tap
				if !isCurrentUser {
					NavigationLink(value: Int64(message.fromUser?.num ?? 0)) {
						CircleText(text: message.fromUser?.shortName ?? "?", color: Color(UIColor(hex: UInt32(message.fromUser?.num ?? 0))), circleSize: 50)
					}
					.buttonStyle(.plain)
					.padding(.all, 5).offset(y: -7)
				}

				VStack(alignment: isCurrentUser ? .trailing : .leading) {

					// Sender Name Header
					if !isCurrentUser && message.fromUser != nil {
						Text("\(message.fromUser?.longName ?? "Unknown".localized ) (\(message.fromUser?.userId ?? "?"))")
							.font(.caption).foregroundColor(.gray).offset(y: 8)
					}

					// Message Bubble
					if let imageData = message.imageData, let uiImage = UIImage(data: imageData) {
						InlineImageBubble(image: uiImage, isFromMe: isCurrentUser, caption: nil)
					} else if let voiceMemoData = message.voiceMemoData {
						InlineVoiceMemoBubble(
							duration: Double(voiceMemoData.count / 2) / 8000.0,
							isFromMe: isCurrentUser,
							audioData: voiceMemoData
						)
					} else {
						HStack {
							MessageText(
								message: message,
								tapBackDestination: .user(user), // Destination is the user
								isCurrentUser: isCurrentUser
							) {
								self.replyMessageId = message.messageId
								self.messageFieldFocused = true						} onTapback: {
								onTapback(message)						}

							if isCurrentUser && message.canRetry || (isCurrentUser && message.receivedACK && !message.realACK) {
								RetryButton(message: message, destination: .user(user))
							}
						}
					}

					// Tapback Responses - Pass the closure to trigger the parent redraw
					TapbackResponses(message: message, onRead: onInteractionComplete)

					// Delivery Status Indicators (WhatsApp-style)
					// Skip for image/voice messages — they have their own status
					if isCurrentUser && message.imageData == nil && message.voiceMemoData == nil {
						dmDeliveryStatus
					}
				}
				.padding(.bottom)

				if !isCurrentUser { Spacer(minLength: 50) }
			}
			.padding([.leading, .trailing])
			.frame(maxWidth: .infinity)

		}
		.id(message.messageId)
	}

	// MARK: - DM Delivery Status

	@ViewBuilder
	private var dmDeliveryStatus: some View {
		let ackErrorVal = RoutingError(rawValue: Int(message.ackError))

		if message.receivedACK {
			if message.realACK {
				// Delivered to recipient: green checkmark
				HStack(spacing: 3) {
					Image(systemName: "checkmark.circle.fill")
						.font(.system(size: 12))
						.foregroundColor(.green)
					if let errorDisplay = ackErrorVal?.display, ackErrorVal?.rawValue != 0 {
						Text(errorDisplay)
							.font(.caption2)
							.foregroundStyle(ackErrorVal?.color ?? .secondary)
					}
				}
			} else {
				// Traveling through network via relay: curved route arrow
				HStack(spacing: 3) {
					Image(systemName: "arrow.triangle.swap")
						.font(.system(size: 11))
						.foregroundColor(.orange)
				}
			}
		} else if message.ackError == 0 {
			// Sent, waiting for ACK: antenna transmitting
			HStack(spacing: 3) {
				Image(systemName: "antenna.radiowaves.left.and.right")
					.font(.system(size: 11))
					.foregroundColor(.secondary)
			}
		} else {
			// Failed: red exclamation
			HStack(spacing: 3) {
				Image(systemName: "exclamationmark.circle.fill")
					.font(.system(size: 11))
					.foregroundColor(.red)
				Text(ackErrorVal?.display ?? "Failed")
					.font(.caption2)
					.foregroundColor(.red)
			}
		}
	}
}

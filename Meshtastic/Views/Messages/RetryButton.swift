import SwiftUI
import OSLog

struct RetryButton: View {
	@Environment(\.modelContext) private var context
	@EnvironmentObject var accessoryManager: AccessoryManager

	let message: MessageEntity
	let destination: MessageDestination
	@State var isShowingConfirmation = false

	var body: some View {
		Button {
			isShowingConfirmation = true
		} label: {
			Image(systemName: "exclamationmark.circle")
				.foregroundColor(.gray)
				.frame(height: 30)
				.padding(.top, 5)
		}
		.accessibilityLabel("Message not delivered. Tap to retry.")
		.confirmationDialog(
			"This message was likely not delivered.",
			isPresented: $isShowingConfirmation,
			titleVisibility: .visible
		) {
			Button("Try Again") {
				guard accessoryManager.isConnected else {
					return
				}
				let messageID = message.messageId
				let payload = message.messagePayload ?? ""
				let userNum = message.toUser?.num ?? 0
				let channel = message.channel
				let isEmoji = message.isEmoji
				let replyID = message.replyID
				Task {
					do {
						try await accessoryManager.sendMessage(message: payload, toUserNum: userNum, channel: channel,
															   isEmoji: isEmoji, replyID: replyID)
						// Only delete the old message after successful resend
						await MainActor.run {
							context.delete(message)
							do {
								try context.save()
							} catch {
								Logger.data.error("Failed to delete old message \(messageID, privacy: .public): \(error.localizedDescription, privacy: .public)")
							}
						}
					} catch {
						Logger.services.warning("Failed to resend message \(messageID, privacy: .public): \(error.localizedDescription, privacy: .public)")
					}
				}
			}
			Button("Cancel", role: .cancel) {}
		}
	}
}

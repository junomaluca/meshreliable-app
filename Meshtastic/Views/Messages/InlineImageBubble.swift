//
//  InlineImageBubble.swift
//  Meshtastic
//
//  Displays an image inline in a conversation bubble with optional
//  sending progress overlay, error state, and retry button.
//

import SwiftUI

struct InlineImageBubble: View {
	let image: UIImage
	let isFromMe: Bool
	var caption: String?
	var progress: Double?
	var error: String?
	var onRetry: (() -> Void)?

	var body: some View {
		VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
			HStack {
				if isFromMe { Spacer(minLength: 60) }

				ZStack {
					Image(uiImage: image)
						.resizable()
						.aspectRatio(contentMode: .fit)
						.frame(maxWidth: 200, maxHeight: 200)
						.clipShape(RoundedRectangle(cornerRadius: 12))

					// Sending progress overlay
					if let progress, progress < 1.0 {
						RoundedRectangle(cornerRadius: 12)
							.fill(.black.opacity(0.4))
							.frame(maxWidth: 200, maxHeight: 200)
						VStack(spacing: 6) {
							ProgressView(value: progress)
								.progressViewStyle(.circular)
								.tint(.white)
							Text("\(Int(progress * 100))%")
								.font(.caption)
								.fontWeight(.medium)
								.foregroundColor(.white)
						}
					}

					// Error overlay
					if let error {
						RoundedRectangle(cornerRadius: 12)
							.fill(.black.opacity(0.5))
							.frame(maxWidth: 200, maxHeight: 200)
						VStack(spacing: 8) {
							Image(systemName: "exclamationmark.circle.fill")
								.font(.title2)
								.foregroundColor(.red)
							Text("Failed")
								.font(.caption)
								.foregroundColor(.white)
							if let onRetry {
								Button {
									onRetry()
								} label: {
									Label("Retry", systemImage: "arrow.clockwise")
										.font(.caption)
										.padding(.horizontal, 12)
										.padding(.vertical, 6)
										.background(.white.opacity(0.2), in: Capsule())
										.foregroundColor(.white)
								}
								.accessibilityLabel("Retry sending image")
							}
						}
					}
				}

				if !isFromMe { Spacer(minLength: 60) }
			}

			if let caption {
				Text(caption)
					.font(.caption2)
					.foregroundColor(.secondary)
			}

			// Delivery status (consistent with text message icons)
			if isFromMe {
				if error != nil {
					HStack(spacing: 3) {
						Image(systemName: "exclamationmark.circle.fill")
							.font(.system(size: 11))
							.foregroundColor(.red)
					}
				} else if let progress, progress >= 1.0 {
					Image(systemName: "checkmark.circle.fill")
						.font(.system(size: 12))
						.foregroundColor(.green)
				} else if progress == nil {
					Image(systemName: "checkmark.circle.fill")
						.font(.system(size: 12))
						.foregroundColor(.green)
				} else {
					Image(systemName: "antenna.radiowaves.left.and.right")
						.font(.system(size: 11))
						.foregroundColor(.secondary)
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: isFromMe ? .trailing : .leading)
		.padding(.horizontal)
		.padding(.vertical, 4)
	}
}

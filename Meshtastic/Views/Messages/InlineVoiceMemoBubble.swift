//
//  InlineVoiceMemoBubble.swift
//  Meshtastic
//
//  Displays a voice memo inline in a conversation bubble with
//  sending progress overlay, error state, retry button, and tap-to-play.
//

import SwiftUI

struct InlineVoiceMemoBubble: View {
	let duration: TimeInterval
	let isFromMe: Bool
	var audioData: Data?
	var progress: Double?
	var error: String?
	var onRetry: (() -> Void)?

	@StateObject private var player = VoiceMemoPlayerModel()

	private var canPlay: Bool {
		audioData != nil && error == nil && (progress == nil || progress! >= 1.0)
	}

	var body: some View {
		VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
			HStack {
				if isFromMe { Spacer(minLength: 60) }

				HStack(spacing: 10) {
					// Play/Pause or Mic icon
					if canPlay {
						Button {
							if let data = audioData {
								player.togglePlayback(pcmData: data)
							}
						} label: {
							Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
								.font(.title2)
								.foregroundColor(isFromMe ? .white : .accentColor)
						}
						.buttonStyle(.plain)
					} else {
						Image(systemName: "mic.fill")
							.font(.title3)
							.foregroundColor(isFromMe ? .white : .accentColor)
					}

					// Waveform — real if audio loaded, placeholder otherwise
					if !player.waveformBars.isEmpty {
						MiniWaveformView(
							bars: player.waveformBars,
							progress: player.playbackProgress,
							foregroundColor: isFromMe ? .white.opacity(0.5) : .secondary.opacity(0.5),
							progressColor: isFromMe ? .white : .accentColor
						)
						.frame(width: 100, height: 24)
					} else {
						HStack(spacing: 2) {
							ForEach(0..<16, id: \.self) { i in
								RoundedRectangle(cornerRadius: 1)
									.fill(isFromMe ? Color.white.opacity(0.6) : Color.accentColor.opacity(0.5))
									.frame(width: 3, height: CGFloat.random(in: 6...20))
							}
						}
					}

					// Duration text
					Text(formattedDuration(player.isPlaying ? player.duration * player.playbackProgress : duration))
						.font(.caption)
						.fontWeight(.medium)
						.foregroundColor(isFromMe ? .white : .primary)
				}
				.padding(.horizontal, 14)
				.padding(.vertical, 10)
				.background(
					RoundedRectangle(cornerRadius: 16)
						.fill(isFromMe ? Color.accentColor : Color(.systemGray5))
				)
				.contentShape(RoundedRectangle(cornerRadius: 16))
				.onTapGesture {
					if canPlay, let data = audioData {
						player.togglePlayback(pcmData: data)
					}
				}
				.overlay {
					// Sending progress overlay
					if let progress, progress < 1.0 {
						ZStack {
							RoundedRectangle(cornerRadius: 16)
								.fill(.black.opacity(0.4))
							VStack(spacing: 4) {
								ProgressView(value: progress)
									.progressViewStyle(.circular)
									.tint(.white)
								Text("\(Int(progress * 100))%")
									.font(.caption2)
									.fontWeight(.medium)
									.foregroundColor(.white)
							}
						}
					}

					// Error overlay
					if let error {
						ZStack {
							RoundedRectangle(cornerRadius: 16)
								.fill(.black.opacity(0.5))
							VStack(spacing: 6) {
								Image(systemName: "exclamationmark.circle.fill")
									.font(.body)
									.foregroundColor(.red)
								Text("Failed")
									.font(.caption2)
									.foregroundColor(.white)
								if let onRetry {
									Button {
										onRetry()
									} label: {
										Label("Retry", systemImage: "arrow.clockwise")
											.font(.caption2)
											.padding(.horizontal, 10)
											.padding(.vertical, 4)
											.background(.white.opacity(0.2), in: Capsule())
											.foregroundColor(.white)
									}
									.accessibilityLabel("Retry sending voice memo")
								}
							}
						}
					}
				}

				if !isFromMe { Spacer(minLength: 60) }
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
		.onAppear {
			if let data = audioData {
				player.load(pcmData: data)
			}
		}
		.onDisappear {
			player.stop()
		}
	}

	private func formattedDuration(_ duration: TimeInterval) -> String {
		let minutes = Int(duration) / 60
		let seconds = Int(duration) % 60
		return String(format: "%d:%02d", minutes, seconds)
	}
}

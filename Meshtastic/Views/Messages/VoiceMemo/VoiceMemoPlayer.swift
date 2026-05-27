//
//  VoiceMemoPlayer.swift
//  Meshtastic
//
//  Inline voice memo player for received audio messages.
//  Decodes raw PCM (8kHz mono 16-bit) received from firmware
//  and plays back via AVAudioEngine.
//

import SwiftUI
import AVFoundation
import OSLog

// MARK: - Playback Model

@MainActor
final class VoiceMemoPlayerModel: ObservableObject {

	@Published var isPlaying = false
	@Published var playbackProgress: Double = 0
	@Published var duration: TimeInterval = 0

	private var audioEngine: AVAudioEngine?
	private var playerNode: AVAudioPlayerNode?
	private var progressTimer: Timer?
	private var totalFrames: AVAudioFramePosition = 0
	private var sampleRate: Double = 8000

	/// Precomputed waveform bars from the PCM data.
	@Published var waveformBars: [Float] = []

	func load(pcmData: Data) {
		// PCM format: 8kHz mono Int16
		let sampleCount = pcmData.count / MemoryLayout<Int16>.size
		guard sampleCount > 0 else { return }

		sampleRate = VoiceMemoRecorderModel.sampleRate
		duration = Double(sampleCount) / sampleRate
		totalFrames = AVAudioFramePosition(sampleCount)

		// Build waveform preview
		waveformBars = buildWaveform(from: pcmData, barCount: 40)
	}

	func play(pcmData: Data) {
		stop()

		let sampleCount = pcmData.count / MemoryLayout<Int16>.size
		guard sampleCount > 0 else { return }

		let session = AVAudioSession.sharedInstance()
		do {
			try session.setCategory(.playback, mode: .default)
			try session.setActive(true)
		} catch {
			Logger.mesh.error("Audio session error: \(error.localizedDescription)")
			return
		}

		// Convert Int16 PCM to Float32 for AVAudioPlayerNode
		guard let format = AVAudioFormat(
			commonFormat: .pcmFormatFloat32,
			sampleRate: sampleRate,
			channels: 1,
			interleaved: false
		) else { return }

		guard let buffer = AVAudioPCMBuffer(
			pcmFormat: format,
			frameCapacity: AVAudioFrameCount(sampleCount)
		) else { return }

		buffer.frameLength = AVAudioFrameCount(sampleCount)
		let floatData = buffer.floatChannelData!.pointee

		pcmData.withUnsafeBytes { rawBuffer in
			let int16Ptr = rawBuffer.bindMemory(to: Int16.self)
			for i in 0..<sampleCount {
				floatData[i] = Float(int16Ptr[i]) / Float(Int16.max)
			}
		}

		let engine = AVAudioEngine()
		let player = AVAudioPlayerNode()
		engine.attach(player)
		engine.connect(player, to: engine.mainMixerNode, format: format)

		do {
			try engine.start()
		} catch {
			Logger.mesh.error("Audio engine start error: \(error.localizedDescription)")
			return
		}

		audioEngine = engine
		playerNode = player

		player.scheduleBuffer(buffer) { [weak self] in
			Task { @MainActor in
				self?.stop()
			}
		}
		player.play()
		isPlaying = true
		playbackProgress = 0

		// Progress timer
		progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
			Task { @MainActor in
				guard let self, let player = self.playerNode, player.isPlaying else { return }
				if let lastRenderTime = player.lastRenderTime,
				   let playerTime = player.playerTime(forNodeTime: lastRenderTime) {
					self.playbackProgress = min(1.0, Double(playerTime.sampleTime) / Double(self.totalFrames))
				}
			}
		}
	}

	func stop() {
		progressTimer?.invalidate()
		progressTimer = nil
		playerNode?.stop()
		audioEngine?.stop()
		audioEngine = nil
		playerNode = nil
		isPlaying = false
		playbackProgress = 0
	}

	func togglePlayback(pcmData: Data) {
		if isPlaying {
			stop()
		} else {
			play(pcmData: pcmData)
		}
	}

	private func buildWaveform(from pcmData: Data, barCount: Int) -> [Float] {
		let sampleCount = pcmData.count / MemoryLayout<Int16>.size
		guard sampleCount > 0 else { return Array(repeating: 0.1, count: barCount) }

		let samplesPerBar = max(1, sampleCount / barCount)
		var bars: [Float] = []

		pcmData.withUnsafeBytes { rawBuffer in
			let int16Ptr = rawBuffer.bindMemory(to: Int16.self)
			for barIndex in 0..<barCount {
				let start = barIndex * samplesPerBar
				let end = min(start + samplesPerBar, sampleCount)
				var maxAbs: Float = 0
				for i in start..<end {
					let absVal = abs(Float(int16Ptr[i]) / Float(Int16.max))
					if absVal > maxAbs { maxAbs = absVal }
				}
				bars.append(max(0.08, min(1.0, maxAbs * 2.5)))
			}
		}

		return bars
	}

	deinit {
		// Cannot call stop() directly in deinit for @MainActor class;
		// engine/player will be released automatically.
	}
}

// MARK: - VoiceMemoPlayer View

/// Inline player displayed within a message bubble for received voice memos.
struct VoiceMemoPlayer: View {

	let pcmData: Data
	let isCurrentUser: Bool

	@StateObject private var player = VoiceMemoPlayerModel()

	var body: some View {
		HStack(spacing: 10) {
			// Play/Pause button
			Button {
				player.togglePlayback(pcmData: pcmData)
			} label: {
				Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
					.font(.system(size: 32))
					.foregroundStyle(isCurrentUser ? .white : .accentColor)
			}
			.buttonStyle(.plain)

			// Mini waveform with progress overlay
			VStack(alignment: .leading, spacing: 4) {
				MiniWaveformView(
					bars: player.waveformBars,
					progress: player.playbackProgress,
					foregroundColor: isCurrentUser ? .white.opacity(0.5) : .secondary.opacity(0.5),
					progressColor: isCurrentUser ? .white : .accentColor
				)
				.frame(height: 28)

				// Duration
				Text(formattedDuration(player.isPlaying ? player.duration * player.playbackProgress : player.duration))
					.font(.caption2)
					.foregroundStyle(isCurrentUser ? .white.opacity(0.7) : .secondary)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.onAppear {
			player.load(pcmData: pcmData)
		}
		.onDisappear {
			player.stop()
		}
	}

	private func formattedDuration(_ seconds: TimeInterval) -> String {
		let mins = Int(seconds) / 60
		let secs = Int(seconds) % 60
		return String(format: "%d:%02d", mins, secs)
	}
}

// MARK: - Mini Waveform with Progress

struct MiniWaveformView: View {
	let bars: [Float]
	let progress: Double
	let foregroundColor: Color
	let progressColor: Color

	var body: some View {
		GeometryReader { geometry in
			let barWidth: CGFloat = max(2, (geometry.size.width - CGFloat(bars.count) * 1.5) / CGFloat(max(bars.count, 1)))
			HStack(alignment: .center, spacing: 1.5) {
				ForEach(0..<bars.count, id: \.self) { index in
					let barProgress = Double(index) / Double(max(bars.count - 1, 1))
					RoundedRectangle(cornerRadius: 1)
						.fill(barProgress <= progress ? progressColor : foregroundColor)
						.frame(
							width: barWidth,
							height: max(2, CGFloat(bars[index]) * geometry.size.height)
						)
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		}
	}
}

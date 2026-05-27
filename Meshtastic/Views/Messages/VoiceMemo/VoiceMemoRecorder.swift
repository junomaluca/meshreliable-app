//
//  VoiceMemoRecorder.swift
//  Meshtastic
//
//  Hold-to-record voice memo sheet with waveform visualization.
//  Captures PCM at 8kHz mono 16-bit, sends raw audio to firmware
//  which handles Codec2 encoding before mesh relay.
//

import SwiftUI
import AVFoundation
import OSLog

// MARK: - Audio Engine Setup (Sendable container for cross-actor transfer)

private struct AudioEngineParts: @unchecked Sendable {
	let engine: AVAudioEngine
	let inputFormat: AVAudioFormat
	let targetFormat: AVAudioFormat
	let converter: AVAudioConverter
}

// MARK: - Audio Recorder Engine

@MainActor
final class VoiceMemoRecorderModel: ObservableObject {

	@Published var isRecording = false
	@Published var recordingDuration: TimeInterval = 0
	@Published var waveformSamples: [Float] = []
	@Published var pcmData = Data()
	@Published var permissionDenied = false

	private var audioEngine: AVAudioEngine?
	private var durationTimer: Timer?

	/// 8kHz mono 16-bit signed integer -- matches firmware Codec2 input.
	static let sampleRate: Double = 8000
	static let maxDuration: TimeInterval = MeshReliableService.maxVoiceDuration

	func requestPermission() async -> Bool {
		if #available(iOS 17.0, *) {
			return await AVAudioApplication.requestRecordPermission()
		} else {
			return await withCheckedContinuation { continuation in
				AVAudioSession.sharedInstance().requestRecordPermission { granted in
					continuation.resume(returning: granted)
				}
			}
		}
	}

	func startRecording() async {
		let granted = await requestPermission()
		guard granted else {
			permissionDenied = true
			return
		}

		pcmData = Data()
		waveformSamples = []
		recordingDuration = 0

		// Audio session config and engine init MUST run off the main thread.
		// AVAudioEngine.inputNode and outputFormat(forBus:) trigger synchronous
		// IPC to coreaudiod that deadlocks when called on the main actor.
		let prepared: AudioEngineParts? = await Task.detached(priority: .userInitiated) {
			let session = AVAudioSession.sharedInstance()
			do {
				try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
				try session.setPreferredSampleRate(8000)
				try session.setActive(true)
			} catch {
				Logger.mesh.error("Failed to configure audio session: \(error.localizedDescription)")
				return nil
			}

			let engine = AVAudioEngine()
			let inputNode = engine.inputNode
			let inputFormat = inputNode.outputFormat(forBus: 0)

			guard let targetFormat = AVAudioFormat(
				commonFormat: .pcmFormatInt16,
				sampleRate: 8000,
				channels: 1,
				interleaved: true
			) else {
				Logger.mesh.error("Failed to create target audio format")
				return nil
			}

			guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
				Logger.mesh.error("Failed to create audio converter from \(inputFormat) to \(targetFormat)")
				return nil
			}

			return AudioEngineParts(engine: engine, inputFormat: inputFormat, targetFormat: targetFormat, converter: converter)
		}.value

		guard let prepared else { return }

		let engine = prepared.engine
		let inputFormat = prepared.inputFormat
		let targetFormat = prepared.targetFormat
		let converter = prepared.converter

		engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
			guard let self else { return }

			// Convert to 8kHz mono Int16
			let ratio = 8000.0 / inputFormat.sampleRate
			let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
			guard outputFrameCount > 0,
				  let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
				return
			}

			var error: NSError?
			var inputConsumed = false
			converter.convert(to: outputBuffer, error: &error) { _, outStatus in
				if inputConsumed {
					outStatus.pointee = .noDataNow
					return nil
				}
				inputConsumed = true
				outStatus.pointee = .haveData
				return buffer
			}

			if let error {
				Logger.mesh.warning("Audio conversion error: \(error.localizedDescription)")
				return
			}

			guard outputBuffer.frameLength > 0 else { return }

			// Extract Int16 samples and append to PCM data
			let int16Pointer = outputBuffer.int16ChannelData!.pointee
			let frameCount = Int(outputBuffer.frameLength)
			let byteCount = frameCount * MemoryLayout<Int16>.size
			let chunk = Data(bytes: int16Pointer, count: byteCount)

			// Compute RMS for waveform visualization
			var sum: Float = 0
			for i in 0..<frameCount {
				let sample = Float(int16Pointer[i]) / Float(Int16.max)
				sum += sample * sample
			}
			let rms = sqrt(sum / Float(max(frameCount, 1)))

			Task { @MainActor in
				self.pcmData.append(chunk)
				self.waveformSamples.append(rms)

				// Enforce max duration
				if self.recordingDuration >= Self.maxDuration {
					self.stopRecording()
				}
			}
		}

		do {
			try engine.start()
			audioEngine = engine
			isRecording = true

			durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
				Task { @MainActor in
					guard let self, self.isRecording else { return }
					self.recordingDuration += 0.1
				}
			}
		} catch {
			Logger.mesh.error("Failed to start audio engine: \(error.localizedDescription)")
		}
	}

	func stopRecording() {
		durationTimer?.invalidate()
		durationTimer = nil
		audioEngine?.inputNode.removeTap(onBus: 0)
		audioEngine?.stop()
		audioEngine = nil
		isRecording = false
	}

	func cancel() {
		stopRecording()
		pcmData = Data()
		waveformSamples = []
		recordingDuration = 0
	}
}

// MARK: - VoiceMemoRecorder View

struct VoiceMemoRecorder: View {

	@EnvironmentObject var accessoryManager: AccessoryManager
	@StateObject private var recorder = VoiceMemoRecorderModel()
	@ObservedObject private var meshReliable = MeshReliableService.shared
	@Environment(\.dismiss) private var dismiss

	let destination: MessageDestination

	@State private var isSending = false
	@State private var sendError: String?

	var body: some View {
		NavigationStack {
			VStack(spacing: 24) {

				Spacer()

				// Duration
				Text(formattedDuration(recorder.recordingDuration))
					.font(.system(size: 48, weight: .light, design: .monospaced))
					.foregroundStyle(recorder.isRecording ? .primary : .secondary)
					.contentTransition(.numericText())
					.animation(.linear(duration: 0.1), value: recorder.recordingDuration)

				// Waveform
				WaveformView(samples: recorder.waveformSamples, isRecording: recorder.isRecording)
					.frame(height: 80)
					.padding(.horizontal)

				// Max duration hint
				if recorder.recordingDuration > 50 {
					Text("\(Int(VoiceMemoRecorderModel.maxDuration - recorder.recordingDuration))s remaining")
						.font(.caption)
						.foregroundStyle(.orange)
				}

				Spacer()

				// Record button
				VStack(spacing: 12) {
					if !recorder.isRecording && recorder.pcmData.isEmpty {
						// Not yet started
						Button {
							Task { await recorder.startRecording() }
						} label: {
							RecordButtonLabel(isRecording: false)
						}
						Text("Tap to start recording")
							.font(.caption)
							.foregroundStyle(.secondary)
					} else if recorder.isRecording {
						// Currently recording
						Button {
							recorder.stopRecording()
						} label: {
							RecordButtonLabel(isRecording: true)
						}
						Text("Tap to stop")
							.font(.caption)
							.foregroundStyle(.secondary)
					} else {
						// Recording complete, show send/cancel
						sendControls
					}
				}

				// Send progress
				if let progress = meshReliable.sendProgress {
					VStack(spacing: 4) {
						ProgressView(value: progress)
							.progressViewStyle(.linear)
						Text("Sending... \(Int(progress * 100))%")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					.padding(.horizontal, 40)
				}

				if let error = sendError {
					Text(error)
						.font(.caption)
						.foregroundStyle(.red)
						.padding(.horizontal)
				}

				Spacer()
					.frame(height: 20)
			}
			.navigationTitle("Voice Memo")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") {
						recorder.cancel()
						dismiss()
					}
				}
			}
			.alert("Microphone Access Required", isPresented: $recorder.permissionDenied) {
				Button("Open Settings") {
					if let url = URL(string: UIApplication.openSettingsURLString) {
						UIApplication.shared.open(url)
					}
				}
				Button("Cancel", role: .cancel) { dismiss() }
			} message: {
				Text("Please enable microphone access in Settings to record voice memos.")
			}
		}
	}

	private var sendControls: some View {
		HStack(spacing: 40) {
			// Discard
			Button {
				recorder.cancel()
			} label: {
				VStack {
					Image(systemName: "trash.circle.fill")
						.font(.system(size: 44))
						.foregroundStyle(.red)
					Text("Discard")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			.disabled(isSending)

			// Re-record
			Button {
				recorder.cancel()
				Task { await recorder.startRecording() }
			} label: {
				VStack {
					Image(systemName: "arrow.counterclockwise.circle.fill")
						.font(.system(size: 44))
						.foregroundStyle(.orange)
					Text("Re-record")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			.disabled(isSending)

			// Send
			Button {
				Task { await sendVoiceMemo() }
			} label: {
				VStack {
					Image(systemName: "arrow.up.circle.fill")
						.font(.system(size: 44))
						.foregroundStyle(Color.accentColor)
					Text("Send")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			.disabled(isSending || recorder.pcmData.isEmpty)
		}
	}

	private func sendVoiceMemo() async {
		isSending = true
		sendError = nil
		do {
			try await meshReliable.sendVoiceMemo(
				pcmData: recorder.pcmData,
				toUserNum: destination.userNum,
				channel: destination.channelNum,
				accessoryManager: accessoryManager
			)
			dismiss()
		} catch {
			sendError = "Failed to send: \(error.localizedDescription)"
			Logger.mesh.error("Voice memo send failed: \(error.localizedDescription)")
		}
		isSending = false
	}

	private func formattedDuration(_ duration: TimeInterval) -> String {
		let minutes = Int(duration) / 60
		let seconds = Int(duration) % 60
		let tenths = Int((duration - Double(Int(duration))) * 10)
		return String(format: "%d:%02d.%d", minutes, seconds, tenths)
	}
}

// MARK: - Record Button Label

private struct RecordButtonLabel: View {
	let isRecording: Bool

	var body: some View {
		ZStack {
			Circle()
				.fill(isRecording ? Color.red.opacity(0.2) : Color.red.opacity(0.1))
				.frame(width: 88, height: 88)

			RoundedRectangle(cornerRadius: isRecording ? 8 : 32)
				.fill(Color.red)
				.frame(width: isRecording ? 32 : 64, height: isRecording ? 32 : 64)
				.animation(.easeInOut(duration: 0.2), value: isRecording)
		}
	}
}

// MARK: - Waveform Visualization

struct WaveformView: View {
	let samples: [Float]
	let isRecording: Bool

	/// Number of bars to display.
	private let barCount = 60

	var body: some View {
		GeometryReader { geometry in
			let displaySamples = downsampledBars()
			HStack(alignment: .center, spacing: 2) {
				ForEach(0..<displaySamples.count, id: \.self) { index in
					RoundedRectangle(cornerRadius: 1.5)
						.fill(isRecording ? Color.accentColor : Color.secondary)
						.frame(
							width: max(2, (geometry.size.width - CGFloat(barCount) * 2) / CGFloat(barCount)),
							height: max(3, CGFloat(displaySamples[index]) * geometry.size.height)
						)
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		}
	}

	private func downsampledBars() -> [Float] {
		guard !samples.isEmpty else {
			return Array(repeating: 0.05, count: barCount)
		}

		if samples.count <= barCount {
			var padded = samples
			while padded.count < barCount {
				padded.insert(0.05, at: 0)
			}
			return padded.map { max(0.05, min(1.0, $0 * 3)) }
		}

		// Downsample: take the max of each bucket
		let bucketSize = Float(samples.count) / Float(barCount)
		var result: [Float] = []
		for i in 0..<barCount {
			let start = Int(Float(i) * bucketSize)
			let end = min(Int(Float(i + 1) * bucketSize), samples.count)
			let maxVal = samples[start..<end].max() ?? 0
			result.append(max(0.05, min(1.0, maxVal * 3)))
		}
		return result
	}
}

//
//  ImagePickerSheet.swift
//  Meshtastic
//
//  Image picker with compression for mesh transmission.
//  Supports photo library and camera capture.
//

import SwiftUI
import PhotosUI
import OSLog

struct ImagePickerSheet: View {

	@EnvironmentObject var accessoryManager: AccessoryManager
	@ObservedObject private var meshReliable = MeshReliableService.shared
	@Environment(\.dismiss) private var dismiss

	let destination: MessageDestination

	@State private var selectedItem: PhotosPickerItem?
	@State private var selectedImage: UIImage?
	@State private var compressedData: Data?
	@State private var compressedSize: String = ""
	@State private var isSending = false
	@State private var sendError: String?
	@State private var showCamera = false
	@State private var compressionQuality: Double = 0.3
	private let targetResolution: Int = 128

	var body: some View {
		NavigationStack {
			VStack(spacing: 16) {
				if let selectedImage {
					// Preview
					Image(uiImage: selectedImage)
						.resizable()
						.aspectRatio(contentMode: .fit)
						.frame(maxHeight: 200)
						.clipShape(RoundedRectangle(cornerRadius: 12))
						.padding(.horizontal)

					if let compressedData {
						Text("Compressed: \(compressedSize)")
							.font(.caption)
							.foregroundStyle(.secondary)

						let chunkCount = Int(ceil(Double(compressedData.count) / Double(MeshReliableService.maxChunkPayload)))
						Text("\(chunkCount) chunks via LoRa")
							.font(.caption2)
							.foregroundStyle(.secondary)
					}

					// Send controls
					HStack(spacing: 32) {
						Button {
							self.selectedImage = nil
							self.compressedData = nil
							self.selectedItem = nil
						} label: {
							VStack {
								Image(systemName: "trash.circle.fill")
									.font(.system(size: 40))
									.foregroundStyle(.red)
								Text("Discard")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
						.disabled(isSending)

						Button {
							Task { await sendImage() }
						} label: {
							VStack {
								Image(systemName: "arrow.up.circle.fill")
									.font(.system(size: 40))
									.foregroundStyle(Color.accentColor)
								Text("Send")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
						.disabled(isSending || compressedData == nil)
					}

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
				} else {
					Spacer()

					// Source selection
					VStack(spacing: 20) {
						PhotosPicker(selection: $selectedItem, matching: .images) {
							VStack {
								Image(systemName: "photo.on.rectangle.angled")
									.font(.system(size: 48))
									.foregroundStyle(Color.accentColor)
								Text("Choose from Library")
									.font(.headline)
							}
						}
						.onChange(of: selectedItem) { _, newItem in
							guard let newItem else { return }
							Task {
								if let data = try? await newItem.loadTransferable(type: Data.self),
								   let image = UIImage(data: data) {
									selectedImage = image
									recompress()
								}
							}
						}

						Button {
							showCamera = true
						} label: {
							VStack {
								Image(systemName: "camera.fill")
									.font(.system(size: 48))
									.foregroundStyle(Color.accentColor)
								Text("Take Photo")
									.font(.headline)
							}
						}
					}

					Spacer()
				}
			}
			.navigationTitle("Send Image")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
						.disabled(isSending)
				}
			}
			.interactiveDismissDisabled(isSending)
			.fullScreenCover(isPresented: $showCamera) {
				CameraView(image: $selectedImage)
					.ignoresSafeArea()
					.onDisappear {
						if selectedImage != nil {
							recompress()
						}
					}
			}
		}
	}

	private func recompress() {
		guard let image = selectedImage else { return }
		compressedData = MeshImageCompressor.compress(
			image: image,
			maxDimension: targetResolution,
			quality: compressionQuality
		)
		if let data = compressedData {
			compressedSize = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
		}
	}

	private func sendImage() async {
		guard let data = compressedData else { return }
		guard accessoryManager.isConnected else {
			sendError = "Not connected to a radio. Please reconnect and try again."
			return
		}
		isSending = true
		sendError = nil

		// Retry up to 2 times on transient connection errors
		var lastError: Error?
		for attempt in 1...2 {
			do {
				try await meshReliable.sendImage(
					jpegData: data,
					toUserNum: destination.userNum,
					channel: destination.channelNum,
					accessoryManager: accessoryManager
				)
				dismiss()
				return
			} catch {
				lastError = error
				Logger.mesh.error("Image send attempt \(attempt) failed: \(error.localizedDescription)")
				if attempt < 2 {
					try? await Task.sleep(for: .milliseconds(500))
				}
			}
		}
		sendError = "Failed to send: \(lastError?.localizedDescription ?? "Unknown error")"
		isSending = false
	}
}

// MARK: - Image Compressor

struct MeshImageCompressor {
	/// Compresses a UIImage for mesh transmission.
	/// Downscales to maxDimension, keeps color, applies aggressive JPEG compression.
	static func compress(image: UIImage, maxDimension: Int, quality: Double = 0.3) -> Data? {
		let targetSize = CGSize(width: maxDimension, height: maxDimension)

		// Downscale maintaining aspect ratio
		let widthRatio = targetSize.width / image.size.width
		let heightRatio = targetSize.height / image.size.height
		let ratio = min(widthRatio, heightRatio)
		let newSize = CGSize(
			width: floor(image.size.width * ratio),
			height: floor(image.size.height * ratio)
		)

		// Render to RGB color context
		let colorSpace = CGColorSpaceCreateDeviceRGB()
		guard let cgContext = CGContext(
			data: nil,
			width: Int(newSize.width),
			height: Int(newSize.height),
			bitsPerComponent: 8,
			bytesPerRow: Int(newSize.width) * 4,
			space: colorSpace,
			bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
		) else { return nil }

		cgContext.interpolationQuality = .medium
		guard let cgImage = image.cgImage else { return nil }
		cgContext.draw(
			cgImage,
			in: CGRect(origin: .zero, size: newSize)
		)

		guard let colorImage = cgContext.makeImage() else { return nil }
		let uiImage = UIImage(cgImage: colorImage)

		return uiImage.jpegData(compressionQuality: quality)
	}
}

// MARK: - Camera View (UIKit bridge)

struct CameraView: UIViewControllerRepresentable {
	@Binding var image: UIImage?
	@Environment(\.dismiss) private var dismiss

	func makeUIViewController(context: Context) -> UIImagePickerController {
		let picker = UIImagePickerController()
		picker.sourceType = .camera
		picker.delegate = context.coordinator
		return picker
	}

	func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
		let parent: CameraView

		init(_ parent: CameraView) { self.parent = parent }

		func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
			if let uiImage = info[.originalImage] as? UIImage {
				parent.image = uiImage
			}
			parent.dismiss()
		}

		func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
			parent.dismiss()
		}
	}
}

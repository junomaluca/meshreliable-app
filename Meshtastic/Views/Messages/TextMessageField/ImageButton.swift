//
//  ImageButton.swift
//  Meshtastic
//
//  Toolbar button for sending images via chunked media transfer.
//

import SwiftUI

struct ImageButton: View {
	let action: () -> Void
	var compact: Bool = false

	var body: some View {
		Button(action: action) {
			if !compact {
				Text("Image")
			}
			Image(systemName: "photo.fill")
				.accessibilityLabel("Send Image")
				.symbolRenderingMode(.hierarchical)
				.imageScale(compact ? .medium : .large)
				.foregroundColor(compact ? .primary : .accentColor)
		}
		.frame(minWidth: compact ? 36 : nil, minHeight: compact ? 36 : nil)
	}
}

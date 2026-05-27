//
//  VoiceMemoButton.swift
//  Meshtastic
//
//  Toolbar button for recording voice memos.
//

import SwiftUI

struct VoiceMemoButton: View {
	let action: () -> Void
	var compact: Bool = false

	var body: some View {
		Button(action: action) {
			if !compact {
				Text("Voice")
			}
			Image(systemName: "mic.fill")
				.accessibilityLabel("Record Voice Memo")
				.symbolRenderingMode(.hierarchical)
				.imageScale(compact ? .medium : .large)
				.foregroundColor(compact ? .primary : .accentColor)
		}
		.frame(minWidth: compact ? 36 : nil, minHeight: compact ? 36 : nil)
	}
}

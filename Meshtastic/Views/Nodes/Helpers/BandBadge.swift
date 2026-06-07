//
//  BandBadge.swift
//  Meshtastic
//
//  Band compatibility badge for the node list.
//  Green = same band as connected device
//  Yellow = different band but bridge path available (via MQTT or dual-band relay)
//  Red = incompatible band, no bridge
//  Blue = dual-band device
//

import SwiftUI

struct BandBadge: View {
	let node: NodeInfoEntity
	let connectedNode: NodeInfoEntity?

	private var myRegion: Int32 {
		connectedNode?.loRaConfig?.regionCode ?? 0
	}

	private var nodeRegion: Int32 {
		node.loRaConfig?.regionCode ?? 0
	}

	private var myBandGroup: BandGroup {
		BandGroup.from(regionCode: myRegion)
	}

	private var nodeBandGroup: BandGroup {
		BandGroup.from(regionCode: nodeRegion)
	}

	private var hasBridgePath: Bool {
		// MQTT-connected nodes can bridge between bands
		node.viaMqtt
	}

	var body: some View {
		let (label, color, icon) = badgeInfo
		HStack(spacing: 3) {
			Image(systemName: icon)
				.font(.system(size: 10))
				.foregroundColor(color)
			Text(label)
				.font(.caption2)
				.foregroundColor(color)
		}
		.padding(.horizontal, 6)
		.padding(.vertical, 2)
		.background(color.opacity(0.15), in: Capsule())
	}

	private var badgeInfo: (String, Color, String) {
		// If we don't know region for either node, show unknown
		guard myRegion != 0, nodeRegion != 0 else {
			return ("Unknown", .secondary, "questionmark.circle")
		}

		// Same band group = green
		if myBandGroup == nodeBandGroup {
			return (nodeBandGroup.label, .green, "antenna.radiowaves.left.and.right")
		}

		// 2.4 GHz node = blue (can talk to anyone with 2.4 GHz capability)
		if nodeBandGroup == .lora24 {
			return ("2.4 GHz", .blue, "dot.radiowaves.forward")
		}

		// Different band but bridge available = yellow
		if hasBridgePath {
			return ("\(nodeBandGroup.label) via bridge", .yellow, "arrow.triangle.branch")
		}

		// Incompatible, no bridge = red
		return (nodeBandGroup.label, .red, "xmark.circle")
	}
}

// MARK: - Band Grouping

enum BandGroup: Equatable {
	case subGhz900    // US 902-928, ANZ 915-928, BR 902-928, etc.
	case subGhz868    // EU 868, UA 868, NZ 865, etc.
	case subGhz433    // EU 433, UA 433, ANZ 433, etc.
	case lora24       // 2.4 GHz
	case vhf144       // 144 MHz ham
	case unknown

	var label: String {
		switch self {
		case .subGhz900: return "900 MHz"
		case .subGhz868: return "868 MHz"
		case .subGhz433: return "433 MHz"
		case .lora24: return "2.4 GHz"
		case .vhf144: return "144 MHz"
		case .unknown: return "Unknown"
		}
	}

	static func from(regionCode: Int32) -> BandGroup {
		guard let region = RegionCodes(rawValue: Int(regionCode)) else { return .unknown }
		switch region {
		case .us, .anz, .kr, .tw, .cn, .jp, .ru, .th, .my919, .sg923, .ph915, .br902, .eu917:
			return .subGhz900
		case .eu868, .ua868, .nz865, .ph868, .kz863, .np865, .eu866, .eu874, .euN868, .in:
			return .subGhz868
		case .eu433, .ua433, .my433, .ph433, .anz433, .kz433:
			return .subGhz433
		case .lora24:
			return .lora24
		case .itu12M, .itu232M:
			return .vhf144
		case .unset:
			return .unknown
		}
	}
}

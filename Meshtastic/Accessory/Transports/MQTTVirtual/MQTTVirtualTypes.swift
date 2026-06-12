//
//  MQTTVirtualTypes.swift
//  Meshtastic
//
//  Value-type snapshots for passing SwiftData info into the MQTTVirtual actor safely.
//

import Foundation

struct VirtualChannel: Sendable {
	let index: Int32
	let name: String
	let psk: Data
	let role: Int32
	let uplinkEnabled: Bool
	let downlinkEnabled: Bool
}

struct MQTTSnapshot: Sendable {
	let address: String
	let port: UInt16
	let username: String?
	let password: String?
	let root: String
	let tlsEnabled: Bool
}

struct UserSnapshot: Sendable {
	let longName: String
	let shortName: String
	let nodeNum: Int64
	let publicKey: Data?
}

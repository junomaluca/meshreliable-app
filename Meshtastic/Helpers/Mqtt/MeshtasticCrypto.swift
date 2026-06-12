//
//  MeshtasticCrypto.swift
//  Meshtastic
//
//  Meshtastic AES-CTR encryption/decryption for Virtual MQTT mode.
//

import Foundation
import CommonCrypto

enum MeshtasticCrypto {

	static let defaultPSK: [UInt8] = [
		0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59,
		0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69, 0x01
	]

	/// Expand a PSK from its stored form to the full key bytes.
	/// - byte 0x00 = no encryption (returns empty)
	/// - byte 0x01 = default PSK
	/// - byte N (2-255, single byte) = default PSK with last byte += N-1
	/// - 16 or 32 bytes = used as-is (AES-128 or AES-256)
	static func expandPSK(_ psk: Data) -> Data {
		if psk.isEmpty || psk == Data([0x00]) {
			return Data()
		}
		if psk.count == 1 {
			var key = defaultPSK
			if psk[0] != 1 {
				key[key.count - 1] &+= psk[0] - 1
			}
			return Data(key)
		}
		return psk
	}

	/// Build the 16-byte CTR nonce: [packetId LE 4B][0x00000000][fromNode LE 4B][0x00000000]
	private static func buildNonce(packetId: UInt32, fromNode: UInt32) -> Data {
		var nonce = Data(count: 16)
		nonce[0] = UInt8(packetId & 0xFF)
		nonce[1] = UInt8((packetId >> 8) & 0xFF)
		nonce[2] = UInt8((packetId >> 16) & 0xFF)
		nonce[3] = UInt8((packetId >> 24) & 0xFF)
		// bytes 4-7 are zero
		nonce[8] = UInt8(fromNode & 0xFF)
		nonce[9] = UInt8((fromNode >> 8) & 0xFF)
		nonce[10] = UInt8((fromNode >> 16) & 0xFF)
		nonce[11] = UInt8((fromNode >> 24) & 0xFF)
		// bytes 12-15 are zero
		return nonce
	}

	/// AES-CTR encrypt or decrypt (symmetric operation).
	private static func aesCTR(input: Data, key: Data, nonce: Data) -> Data? {
		guard key.count == 16 || key.count == 32 else { return nil }
		guard nonce.count == 16 else { return nil }

		var cryptorRef: CCCryptorRef?
		var status = key.withUnsafeBytes { keyBytes in
			nonce.withUnsafeBytes { ivBytes in
				CCCryptorCreateWithMode(
					CCOperation(kCCEncrypt), // CTR encrypt == decrypt
					CCMode(kCCModeCTR),
					CCAlgorithm(kCCAlgorithmAES),
					CCPadding(ccNoPadding),
					ivBytes.baseAddress,
					keyBytes.baseAddress,
					key.count,
					nil, 0, 0,
					CCModeOptions(kCCModeOptionCTR_BE),
					&cryptorRef
				)
			}
		}
		guard status == kCCSuccess, let cryptor = cryptorRef else { return nil }
		defer { CCCryptorRelease(cryptor) }

		var output = Data(count: input.count)
		let outputCount = output.count
		var dataOutMoved: size_t = 0

		status = input.withUnsafeBytes { inputBytes in
			output.withUnsafeMutableBytes { outputBytes in
				CCCryptorUpdate(
					cryptor,
					inputBytes.baseAddress,
					input.count,
					outputBytes.baseAddress,
					outputCount,
					&dataOutMoved
				)
			}
		}
		guard status == kCCSuccess else { return nil }
		output.count = dataOutMoved
		return output
	}

	/// Decrypt an encrypted MeshPacket payload.
	static func decrypt(encrypted: Data, psk: Data, packetId: UInt32, fromNode: UInt32) -> Data? {
		let key = expandPSK(psk)
		guard !key.isEmpty else { return encrypted } // no encryption
		let nonce = buildNonce(packetId: packetId, fromNode: fromNode)
		return aesCTR(input: encrypted, key: key, nonce: nonce)
	}

	/// Encrypt a plaintext payload for a MeshPacket.
	static func encrypt(plaintext: Data, psk: Data, packetId: UInt32, fromNode: UInt32) -> Data? {
		let key = expandPSK(psk)
		guard !key.isEmpty else { return plaintext } // no encryption
		let nonce = buildNonce(packetId: packetId, fromNode: fromNode)
		return aesCTR(input: plaintext, key: key, nonce: nonce)
	}

	/// Compute the channel hash (used in MeshPacket.channel field).
	/// XOR of channel name bytes XOR key bytes, matching firmware's `generateHash`.
	static func channelHash(name: String, psk: Data) -> UInt8 {
		let key = expandPSK(psk)
		var hash: UInt8 = 0
		let nameBytes = Array(name.utf8)
		for byte in nameBytes {
			hash ^= byte
		}
		for byte in key {
			hash ^= byte
		}
		return hash
	}
}

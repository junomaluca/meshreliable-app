//
//  BLEConnection.swift
//  Meshtastic
//
//  Created by Jake Bordens on 7/10/25.
//

import Foundation
@preconcurrency import CoreBluetooth
import OSLog
import MeshtasticProtobufs
import SwiftProtobuf

let meshtasticServiceCBUUID = CBUUID(string: "0x6BA1B218-15A8-461F-9FA8-5DCAE273EAFD")
let TORADIO_UUID = CBUUID(string: "0xF75C76D2-129E-4DAD-A1DD-7866124401E7")
let FROMRADIO_UUID = CBUUID(string: "0x2C55E69E-4993-11ED-B878-0242AC120002")
let FROMNUM_UUID = CBUUID(string: "0xED9DA18C-A800-4F66-A670-AA7547E34453")
let LOGRADIO_UUID = CBUUID(string: "0x5a3d6e49-06e6-4423-9944-e9de8cdf9547")

extension CBCharacteristic {
	
	var meshtasticCharacteristicName: String {
		switch self.uuid {
		case TORADIO_UUID:
			return "TORADIO"
		case FROMRADIO_UUID:
			return "FROMRADIO"
		case FROMNUM_UUID:
			return "FROMNUM"
		case LOGRADIO_UUID:
			return "LOGRADIO"
		default:
			return "UNKNOWN (\(self.uuid.uuidString))"
		}
	}
}

actor BLEConnection: Connection {
	let type = TransportType.ble
	
	var delegate: BLEConnectionDelegate
	var peripheral: CBPeripheral
	var central: CBCentralManager
	private var needsDrain: Bool = false
	private var isDraining: Bool = false

	// Debug counters for diagnosing BLE data flow
	nonisolated(unsafe) static var debugFromnumNotifications: Int = 0
	nonisolated(unsafe) static var debugDrainCalls: Int = 0
	nonisolated(unsafe) static var debugReadCalls: Int = 0
	nonisolated(unsafe) static var debugReadDataBytes: Int = 0
	nonisolated(unsafe) static var debugFromRadioDecoded: Int = 0
	nonisolated(unsafe) static var debugFromRadioDecodeFail: Int = 0
	nonisolated(unsafe) static var debugLastError: String = ""
	nonisolated(unsafe) static var debugSubscribeAttempts: Int = 0
	nonisolated(unsafe) static var debugSubscribeSuccess: Int = 0
	nonisolated(unsafe) static var debugSubscribeFail: Int = 0
	nonisolated(unsafe) static var debugCharDiscovered: String = ""
	
	fileprivate var TORADIO_characteristic: CBCharacteristic?
	fileprivate var FROMRADIO_characteristic: CBCharacteristic?
	fileprivate var FROMNUM_characteristic: CBCharacteristic?
	fileprivate var LOGRADIO_characteristic: CBCharacteristic?
	
	private var connectionStreamContinuation: AsyncStream<ConnectionEvent>.Continuation?
	
	private var connectContinuation: CheckedContinuation<Void, Error>?
	private var rediscoverContinuation: CheckedContinuation<Void, Error>?
	private var writeContinuations: [CheckedContinuation<Void, Error>]
	private var readContinuations: [CheckedContinuation<Data, Error>]
	
	private var rssiTask: Task<Void, Never>?
	private var pollTask: Task<Void, Never>?
	/// Tracks whether notification subscriptions need re-subscribing after BLE pairing completes
	private var notificationsNeedResubscribe = false
	
	var isConnected: Bool { peripheral.state == .connected }
	var transport: BLETransport?
	
	init(peripheral: CBPeripheral, central: CBCentralManager, transport: BLETransport) {
		self.peripheral = peripheral
		self.central = central
		self.transport = transport
		self.delegate = BLEConnectionDelegate(peripheral: peripheral)
		self.writeContinuations = []
		self.readContinuations = []
		self.delegate.setConnection(self)
	}
	
	func disconnect(withError error: Error? = nil, shouldReconnect: Bool) async throws {
		if peripheral.state == .connected {
			if let characteristic = FROMRADIO_characteristic {
				peripheral.setNotifyValue(false, for: characteristic)
			}
			if let characteristic = FROMNUM_characteristic {
				peripheral.setNotifyValue(false, for: characteristic)
			}
			if let characteristic = LOGRADIO_characteristic {
				peripheral.setNotifyValue(false, for: characteristic)
			}
		}
		
		await transport?.connectionDidDisconnect(fromPeripheral: peripheral)
		
		central.cancelPeripheralConnection(peripheral)
		peripheral.delegate = nil
				
		while !writeContinuations.isEmpty {
			let writeContinuation = writeContinuations.removeFirst()
			writeContinuation.resume(throwing: AccessoryError.disconnected("Unknown error"))
		}

		while !readContinuations.isEmpty {
			let readContinuation = readContinuations.removeFirst()
			readContinuation.resume(throwing: AccessoryError.disconnected("Unknown error"))
		}

		if let error {
			// Inform the AccessoryManager of the error and intent to reconnect
			if shouldReconnect {
				if let cbError = error as? CBError {
					connectionStreamContinuation?.yield(.error(AccessoryError.coreBluetoothError(cbError)))
				} else if let attError = error as? CBATTError {
					connectionStreamContinuation?.yield(.error(AccessoryError.coreBluetoothATTError(attError)))
				} else {
					connectionStreamContinuation?.yield(.error(error))
				}
			} else {
				if let cbError = error as? CBError {
					connectionStreamContinuation?.yield(.errorWithoutReconnect(AccessoryError.coreBluetoothError(cbError)))
				} else if let attError = error as? CBATTError {
					connectionStreamContinuation?.yield(.errorWithoutReconnect(AccessoryError.coreBluetoothATTError(attError)))
				} else {
					connectionStreamContinuation?.yield(.errorWithoutReconnect(error))
				}
			}
		} else {
			connectionStreamContinuation?.yield(.disconnected(shouldReconnect: shouldReconnect))
		}

		connectionStreamContinuation?.finish()
		connectionStreamContinuation = nil
		
		rssiTask?.cancel()
		rssiTask = nil
		pollTask?.cancel()
		pollTask = nil
	}

	func startDrainPendingPackets() throws {
		guard isConnected else {
			throw AccessoryError.ioFailed("Not connected")
		}
		needsDrain = true
		if !isDraining {
			Task {
				isDraining = true
				defer { isDraining = false }
				while needsDrain {
					needsDrain = false
					do {
						try await drainPendingPackets()
					} catch {
						// Handle or log error as needed; for now, just continue to allow retry on next notification
					}
				}
			}
		}
	}
	
	func drainPendingPackets() async throws {
		BLEConnection.debugDrainCalls += 1
		guard isConnected else {
			BLEConnection.debugLastError = "drain: not connected"
			throw AccessoryError.ioFailed("Not connected")
		}
		repeat {
			let data: Data
			do {
				BLEConnection.debugReadCalls += 1
				data = try await read()
			} catch {
				BLEConnection.debugLastError = "read error: \(error.localizedDescription)"
				do {
					try await self.disconnect(withError: error, shouldReconnect: true)
				} catch let disconnectError {
					Logger.transport.error("🛜 [BLE] Failed to disconnect after read error: \(disconnectError.localizedDescription)")
				}
				throw error
			}

			BLEConnection.debugReadDataBytes += data.count
			if data.count == 0 {
				break
			}

			do {
				let decodedInfo = try FromRadio(serializedBytes: data)
				BLEConnection.debugFromRadioDecoded += 1
				connectionStreamContinuation?.yield(.data(decodedInfo))
			} catch {
				BLEConnection.debugFromRadioDecodeFail += 1
				BLEConnection.debugLastError = "decode fail (\(data.count)b): \(error.localizedDescription)"
				if isInvalidUTF8DecodeError(error) {
					Logger.transport.error("⚠️ [BLE] Failed to decode FromRadio packet due to invalid UTF-8 (\(data.count) bytes), skipping: \(error)")
				} else {
					let decodeError = error
					do {
						try await self.disconnect(withError: decodeError, shouldReconnect: true)
					} catch let disconnectError {
						Logger.transport.error("⚠️ [BLE] Failed to disconnect after FromRadio decode failure: \(disconnectError)")
					}
					throw decodeError
				}
			}
		} while true
	}

	private func isInvalidUTF8DecodeError(_ error: Error) -> Bool {
		(error as? BinaryDecodingError) == .invalidUTF8
	}
	
	func didReceiveLogMessage(_ logMessage: String) {
		self.connectionStreamContinuation?.yield(.logMessage(logMessage))
	}
	
	func didUpdateRssi(_ rssi: Int) {
		self.connectionStreamContinuation?.yield(.rssiUpdate(rssi))
	}
	
	func getPacketStream() -> AsyncStream<ConnectionEvent> {
		AsyncStream<ConnectionEvent> { continuation in
			// Finish any previous stream so its consumer's `for await` loop terminates cleanly
			// instead of hanging indefinitely on the abandoned continuation.
			self.connectionStreamContinuation?.finish()
			self.connectionStreamContinuation = nil
			
			continuation.onTermination = { [weak self] termination in
				guard let self else { return }
				guard case .cancelled = termination else { return }
				Task {
					try await self.disconnect(withError: AccessoryError.eventStreamCancelled, shouldReconnect: true)
				}
			}
			self.connectionStreamContinuation = continuation
		}
	}
	
	func discoverServices() async throws {
		try await withCheckedThrowingContinuation { cont in
			self.connectContinuation = cont
			peripheral.discoverServices([meshtasticServiceCBUUID])
		}
	}
	
	func connect() async throws -> AsyncStream<ConnectionEvent> {
		do {
			// Make sure we're connected
			guard self.peripheral.state == .connected else {
				throw AccessoryError.ioFailed("BLE peripheral not connected")
			}
			
			return try await withTaskCancellationHandler {
				try await discoverServices()
				startRSSITask()
				return self.getPacketStream()
			} onCancel: {
				Task {
					await self.continueConnectionProcess(throwing: CancellationError())
					await self.notifyTransportOfDisconnect()
				}
			}
		} catch {
			// Before we throw, let the transport know we didn't successfully connect
			await self.notifyTransportOfDisconnect()
			throw error
		}
	}
	
	private func continueConnectionProcess(throwing error: Error? = nil) {
		if let error {
			self.connectContinuation?.resume(throwing: error)
		} else {
			self.connectContinuation?.resume()
		}
		self.connectContinuation = nil
	}
	
	private func notifyTransportOfDisconnect() async {
		await transport?.connectionDidDisconnect(fromPeripheral: peripheral)
	}
	
	func startRSSITask() {
		if let task = self.rssiTask {
			task.cancel()
		}
		self.rssiTask = Task { [weak self] in
			guard let self else { return }
			do {
				while !Task.isCancelled {
					try await Task.sleep(for: .seconds(10))
					await self.requestRSSIRead()
				}
			} catch {
				
			}
		}
	}
	
	private func requestRSSIRead() {
		peripheral.readRSSI()
	}
	
	func didDiscoverServices(error: Error? ) {
		if let error = error {
			self.continueConnectionProcess(throwing: error)
			return
		}
		
		guard let services = peripheral.services else {
			self.continueConnectionProcess(throwing: AccessoryError.discoveryFailed("No services found"))
			return
		}
		
		var foundMeshtasticService = false
		for service in services where service.uuid == meshtasticServiceCBUUID {
			foundMeshtasticService = true
			peripheral.discoverCharacteristics([TORADIO_UUID, FROMRADIO_UUID, FROMNUM_UUID, LOGRADIO_UUID], for: service)
			Logger.transport.info("🛜  [BLE] Service for Meshtastic discovered by \(self.peripheral.name ?? "Unknown", privacy: .public)")
		}
		
		if !foundMeshtasticService {
			self.continueConnectionProcess(throwing: AccessoryError.discoveryFailed("Meshtastic service not found"))
		}
	}
	
	func didDiscoverCharacteristicsFor(service: CBService, error: Error?) {
		if let error = error {
			self.continueConnectionProcess(throwing: error)
			return
		}
		guard let characteristics = service.characteristics else {
			self.continueConnectionProcess(throwing: AccessoryError.discoveryFailed("No characteristics"))
			return
		}
		
		for characteristic in characteristics {
			switch characteristic.uuid {
			case TORADIO_UUID:
				Logger.transport.info("🛜 [BLE] did discover TORADIO characteristic for Meshtastic by \(self.peripheral.name ?? "Unknown", privacy: .public)")
				TORADIO_characteristic = characteristic

			case FROMRADIO_UUID:
				Logger.transport.info("🛜 [BLE] did discover FROMRADIO characteristic for Meshtastic by \(self.peripheral.name ?? "Unknown", privacy: .public)")
				FROMRADIO_characteristic = characteristic

			case FROMNUM_UUID:
				Logger.transport.info("🛜 [BLE] did discover FROMNUM (Notify) characteristic for Meshtastic by \(self.peripheral.name ?? "Unknown", privacy: .public)")
				FROMNUM_characteristic = characteristic

			case LOGRADIO_UUID:
				Logger.transport.info("🛜 [BLE] did discover LOGRADIO (Notify) characteristic for Meshtastic by \(self.peripheral.name ?? "Unknown", privacy: .public)")
				LOGRADIO_characteristic = characteristic

			default:
				Logger.transport.info("🛜 [BLE] did discover unsupported \(characteristic.uuid) characteristic for Meshtastic by \(self.peripheral.name ?? "Unknown", privacy: .public)")
			}
		}

		// Defer notification subscriptions — do NOT subscribe here.
		// On devices with PIN-based BLE security (AUTHEN + ENC characteristics),
		// calling setNotifyValue before pairing triggers NimBLE's security system
		// which disconnects the link. Instead, mark that subscriptions are needed
		// and subscribe after the first successful write (which triggers/completes pairing).
		notificationsNeedResubscribe = true
		
		// Handle rediscovery continuation (from send() retry path)
		if let cont = rediscoverContinuation {
			rediscoverContinuation = nil
			if TORADIO_characteristic != nil {
				cont.resume()
			} else {
				cont.resume(throwing: AccessoryError.discoveryFailed("TORADIO characteristic not found on rediscovery"))
			}
			return
		}

		let chars = [
				TORADIO_characteristic != nil ? "TO" : "",
				FROMRADIO_characteristic != nil ? "FR" : "",
				FROMNUM_characteristic != nil ? "FN" : "",
				LOGRADIO_characteristic != nil ? "LR" : ""
			].filter { !$0.isEmpty }.joined(separator: "+")
			BLEConnection.debugCharDiscovered = chars

			if TORADIO_characteristic != nil && FROMRADIO_characteristic != nil && FROMNUM_characteristic != nil {
			Logger.transport.info("🛜 [BLE] characteristics ready")
			self.continueConnectionProcess()

			// Read initial RSSI on ready
			peripheral.readRSSI()
		} else {
			Logger.transport.info("🛜 [BLE] Missing required characteristics")
			self.continueConnectionProcess(throwing: AccessoryError.discoveryFailed("Missing required characteristics"))
		}
	}
	
	func didUpdateValueFor(characteristic: CBCharacteristic, error: Error?) {
		if let error = error {
			if characteristic.uuid == FROMRADIO_UUID {
				Logger.transport.debug("🛜 [BLE] Error updating value for \(characteristic.meshtasticCharacteristicName, privacy: .public): \(error)")
				if !readContinuations.isEmpty {
					let readContinuation = self.readContinuations.removeFirst()
					readContinuation.resume(throwing: error)
				}
			}
			Task { try await self.handlePeripheralError(error: error) }
			return
		}
		Logger.transport.debug("🛜 [BLE] Did update value for \(characteristic.meshtasticCharacteristicName, privacy: .public)=\(characteristic.value ?? Data(), privacy: .public)")

		guard let value = characteristic.value else { return }
		
		switch characteristic.uuid {
		case FROMRADIO_UUID:
			if !readContinuations.isEmpty {
				let readContinuation = self.readContinuations.removeFirst()
				readContinuation.resume(returning: value)
			}
		case FROMNUM_UUID:
			BLEConnection.debugFromnumNotifications += 1
			do {
				try startDrainPendingPackets()
			} catch {
				BLEConnection.debugLastError = "drain start: \(error.localizedDescription)"
				Logger.transport.error("🛜 [BLE] Failed to drain pending packets on FROMNUM notification: \(error.localizedDescription)")
			}
			
		case LOGRADIO_UUID:
			if let value = characteristic.value,
			   let logRecord = try? LogRecord(serializedBytes: value) {
				self.didReceiveLogMessage(logRecord.stringRepresentation)
			}
			
		default:
			break
		}
	}
	
	func didWriteValueFor(characteristic: CBCharacteristic, error: Error?) {
		guard characteristic.uuid == TORADIO_UUID else {
			Logger.transport.error("🛜 [BLE] didWriteValueFor a characteristic other than TORADIO_UUID.  Should not happen!")
			return
		}
		guard !writeContinuations.isEmpty else {
			Logger.transport.error("🛜 [BLE] didWriteValueFor with no waiting continuations.  Should not happen!")
			return
		}
		
		let writeContinuation = writeContinuations.removeFirst()
		
		if let error = error {
			Logger.transport.error("🛜 [BLE] Did write for \(characteristic.meshtasticCharacteristicName, privacy: .public) with error \(error, privacy: .public)")
			writeContinuation.resume(throwing: error)
			Task { try await self.handlePeripheralError(error: error) }
		} else {
			#if DEBUG
			// Too much logging to report every write.
			Logger.transport.error("🛜 [BLE] Did write for \(characteristic.meshtasticCharacteristicName, privacy: .public)")
			#endif
			writeContinuation.resume()
		}
	}
	
	func didReadRSSI(RSSI: NSNumber, error: Error?) {
		if let error = error {
			Logger.transport.error("🛜 [BLE] Error reading RSSI: \(error.localizedDescription)")
			return
		}
		connectionStreamContinuation?.yield(.rssiUpdate(RSSI.intValue))
	}
	
	func send(_ data: ToRadio) async throws {
		guard isConnected else {
			Logger.transport.error("🛜 [BLE] send() failed: peripheral state is \(String(describing: self.peripheral.state.rawValue)), not connected")
			throw AccessoryError.ioFailed("Not connected to radio (BLE disconnected)")
		}

		// If characteristic is nil but we are connected, attempt to rediscover
		if TORADIO_characteristic == nil {
			Logger.transport.warning("🛜 [BLE] TORADIO characteristic is nil despite being connected — attempting rediscovery")
			try await rediscoverCharacteristics()
		}

		guard let characteristic = TORADIO_characteristic else {
			Logger.transport.error("🛜 [BLE] send() failed: TORADIO characteristic not found after rediscovery attempt")
			throw AccessoryError.ioFailed("BLE characteristic not found — try reconnecting")
		}
		let binaryData: Data
		do {
			binaryData = try data.serializedData()
		} catch {
			Logger.transport.error("🛜 [BLE] Failed to serialize ToRadio data: \(error.localizedDescription)")
			throw AccessoryError.ioFailed("Failed to serialize data: \(error.localizedDescription)")
		}
		guard characteristic.properties.contains(.write) ||
				characteristic.properties.contains(.writeWithoutResponse) else {
			throw AccessoryError.ioFailed("Characteristic does not support write")
		}

		// Use .writeWithoutResponse for compatibility — some firmware/NimBLE builds
		// crash or fail encryption when receiving write-with-response during config
		// exchange. Reliability is handled at the protocol level (NACK retransmission).
		let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse

		// Retry loop for encryption errors — iOS may still be completing BLE pairing.
		// PIN entry can take 10-20 seconds (user sees dialog, types 6 digits, taps OK),
		// so we allow up to 15 retries × 2s = 28 seconds for pairing to complete.
		let maxWriteRetries = 15
		for attempt in 0..<maxWriteRetries {
			do {
				try await withCheckedThrowingContinuation { newWriteContinuation in
					if writeType == .withoutResponse {
						peripheral.writeValue(binaryData, for: characteristic, type: writeType)
						newWriteContinuation.resume()
					} else {
						writeContinuations.append(newWriteContinuation)
						peripheral.writeValue(binaryData, for: characteristic, type: writeType)
					}
				}
				// Write succeeded — if notifications need re-subscribing (failed before pairing), do it now.
				// Add a brief delay to let BLE encryption fully stabilize before resubscribing.
				if notificationsNeedResubscribe {
					try? await Task.sleep(for: .milliseconds(500))
					resubscribeNotifications()
				}
				return
			} catch let attError as CBATTError where attError.code == .insufficientEncryption || attError.code == .insufficientAuthentication {
				if attempt < maxWriteRetries - 1 {
					Logger.transport.warning("🛜 [BLE] Write failed with encryption error (attempt \(attempt + 1)/\(maxWriteRetries)), waiting for pairing...")
					try await Task.sleep(for: .seconds(2))
				} else {
					Logger.transport.error("🛜 [BLE] Write failed after \(maxWriteRetries) attempts — pairing may have failed")
					throw AccessoryError.coreBluetoothATTError(attError)
				}
			}
		}
	}

	/// Attempt to rediscover BLE characteristics if they were lost
	private func rediscoverCharacteristics() async throws {
		guard isConnected else { return }
		guard let service = peripheral.services?.first(where: { $0.uuid == meshtasticServiceCBUUID }) else {
			Logger.transport.error("🛜 [BLE] rediscoverCharacteristics: meshtastic service not found on peripheral")
			throw AccessoryError.ioFailed("Meshtastic BLE service not found")
		}
		// Check if characteristics are already on the service object
		if let chars = service.characteristics {
			for char in chars {
				switch char.uuid {
				case TORADIO_UUID: TORADIO_characteristic = char
				case FROMRADIO_UUID: FROMRADIO_characteristic = char
				case FROMNUM_UUID: FROMNUM_characteristic = char
				case LOGRADIO_UUID: LOGRADIO_characteristic = char
				default: break
				}
			}
			if TORADIO_characteristic != nil {
				Logger.transport.info("🛜 [BLE] rediscoverCharacteristics: recovered TORADIO from cached service")
				return
			}
		}
		// If still not found, trigger a fresh discovery
		Logger.transport.info("🛜 [BLE] rediscoverCharacteristics: triggering fresh characteristic discovery")
		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
			self.rediscoverContinuation = cont
			peripheral.discoverCharacteristics([TORADIO_UUID, FROMRADIO_UUID, FROMNUM_UUID, LOGRADIO_UUID], for: service)
		}
	}
	
	func read() async throws -> Data {
		guard let FROMRADIO_characteristic else {
			throw AccessoryError.ioFailed("No FROMRADIO_characteristic ")
		}
		let data: Data = try await withCheckedThrowingContinuation { newReadContinuation in
			readContinuations.append(newReadContinuation)
			peripheral.readValue(for: FROMRADIO_characteristic)
		}
		if data.isEmpty {
			Logger.transport.debug("🛜 [BLE] Received empty data, ending drain operation.")
		}
		return data
	}
	
	func handlePeripheralError(error: Error) async throws {
		/// Explicit retries for a few specific errors where we want to re-connect, all other errors should not reconnect automatically
		var shouldReconnect = false
		switch error {
		case let attError as CBATTError:
			 switch attError.code {
			 case .insufficientEncryption, .insufficientAuthentication:
				 // These errors occur when iOS hasn't completed BLE pairing/encryption yet.
				 // Don't disconnect — the pairing dialog may still be active. The write retry
				 // mechanism in send() will handle retrying after pairing completes.
				 Logger.transport.warning("🛜 [BLEConnection] ATT error \(attError.code.rawValue) (encryption/auth) — waiting for pairing to complete, not disconnecting")
				 return
			 default:
				 // All other CBATTErrors should not try and reconnect
				 Logger.transport.error("🛜 [BLEConnection] Disconnected with CBATTError code: \(attError.code.rawValue) - \(attError.localizedDescription)")
			 }
		case let cbError as CBError:
			switch cbError.code {
			case .connectionTimeout: // 6
				// Happens when the node goes out of range or the shutdown or reset buttons are presses
				// Should disconnect, show error, and retry when re-advertised
				Logger.transport.error("🛜 [BLEConnection] Disconnected with CBError code: \(cbError.code.rawValue) - \(cbError.localizedDescription)")
				shouldReconnect = true
			case .peripheralDisconnected: // 7
				// Happens when the node reboots or shuts down intentionally via the firmware or app
				// Should disconnect, show error, and retry when re-advertised
				Logger.transport.error("🛜 [BLEConnection] Disconnected with CBError code: \(cbError.code.rawValue) - \(cbError.localizedDescription)")
				shouldReconnect = true
			default:
				Logger.transport.error("🛜 [BLEConnection] Disconnected with CBError code: \(cbError.code.rawValue) - \(cbError.localizedDescription)")
			}
		case let otherError:
			Logger.transport.error("🛜 [BLEConnection] Disconnected with non CBError or CBATTError: \(otherError.localizedDescription)")
		}
		
		// Inform the active connection that there was an error and it should disconnect
		try await self.disconnect(withError: error, shouldReconnect: shouldReconnect)
	}
	
	func didUpdateNotificationStateFor(characteristic: CBCharacteristic, error: Error?) {
		BLEConnection.debugSubscribeAttempts += 1
		if let error {
			BLEConnection.debugSubscribeFail += 1
			BLEConnection.debugLastError = "subscribe \(characteristic.meshtasticCharacteristicName): \(error.localizedDescription)"
			if let attError = error as? CBATTError,
			   attError.code == .insufficientEncryption || attError.code == .insufficientAuthentication {
				Logger.transport.warning("🛜 [BLE] Notification subscription failed for \(characteristic.meshtasticCharacteristicName, privacy: .public) — encryption/auth error, will re-subscribe after pairing")
				notificationsNeedResubscribe = true
			} else {
				Logger.transport.error("🛜 [BLE] Notification subscription failed for \(characteristic.meshtasticCharacteristicName, privacy: .public): \(error.localizedDescription)")
			}
		} else {
			BLEConnection.debugSubscribeSuccess += 1
			Logger.transport.info("🛜 [BLE] Notification subscription succeeded for \(characteristic.meshtasticCharacteristicName, privacy: .public)")
		}
	}

	/// Re-subscribes to FROMRADIO, FROMNUM, and LOGRADIO notifications after BLE pairing completes.
	/// Schedules a follow-up retry in case the first attempt fails (encryption may still be stabilizing).
	private func resubscribeNotifications() {
		guard isConnected else { return }
		Logger.transport.info("🛜 [BLE] Re-subscribing to notifications after pairing completed")
		subscribeToNotifications()
		notificationsNeedResubscribe = false

		// Start polling as a fallback in case FROMNUM notifications don't arrive
		startPolling()

		// Schedule a second attempt after 2 seconds — if the first setNotifyValue calls
		// fail because BLE encryption wasn't fully established yet, this retry catches it.
		// If they already succeeded, the second call is harmless (CoreBluetooth ignores
		// duplicate subscriptions).
		Task {
			try? await Task.sleep(for: .seconds(2))
			guard self.isConnected else { return }
			Logger.transport.info("🛜 [BLE] Re-subscribing to notifications (follow-up retry)")
			self.subscribeToNotifications()
		}
	}

	/// Starts a background polling loop that periodically triggers a FromRadio drain.
	/// This is a fallback for when FROMNUM notifications aren't arriving from the firmware.
	/// Without this, the phone never knows to read new data from the device.
	private func startPolling() {
		pollTask?.cancel()
		pollTask = Task {
			// Initial delay to let notification-based drain work first
			try? await Task.sleep(for: .seconds(3))
			while !Task.isCancelled && self.isConnected {
				do {
					try self.startDrainPendingPackets()
				} catch {
					// Ignore drain errors during polling
				}
				try? await Task.sleep(for: .milliseconds(500))
			}
		}
	}

	/// Subscribes to FROMRADIO, FROMNUM, and LOGRADIO notifications.
	private func subscribeToNotifications() {
		// Note: FROMRADIO is READ-only, no notifications needed (and attempting fails with "not supported")
		if let char = FROMNUM_characteristic {
			peripheral.setNotifyValue(true, for: char)
		}
		if let char = LOGRADIO_characteristic {
			peripheral.setNotifyValue(true, for: char)
		}
	}

	func appDidEnterBackground() {
		if let task = self.rssiTask {
			Logger.transport.info("🛜 [BLE] App is entering the background, suspending RSSI reports.")
			task.cancel()
			self.rssiTask = nil
		}
	}
	
	func appDidBecomeActive() {
		if self.rssiTask == nil {
			Logger.transport.info("🛜 [BLE] App is active, restarting RSSI reports.")
			self.startRSSITask()
		}
	}
}

class BLEConnectionDelegate: NSObject, CBPeripheralDelegate {
	private weak var connection: BLEConnection?
	let peripheral: CBPeripheral
		
	init(peripheral: CBPeripheral) {
		self.peripheral = peripheral
		super.init()
		peripheral.delegate = self
	}
	
	func setConnection(_ connection: BLEConnection) {
		self.connection = connection
	}
	
	// MARK: CBPeripheralDelegate
	func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
		Task { await connection?.didDiscoverServices(error: error) }
	}
	
	func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
		Task { await connection?.didDiscoverCharacteristicsFor(service: service, error: error) }
	}
	
	func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
		Task { await connection?.didUpdateValueFor(characteristic: characteristic, error: error) }
	}
	
	func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
		Task { await connection?.didWriteValueFor(characteristic: characteristic, error: error) }
	}
	
	func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
		Task { await connection?.didReadRSSI(RSSI: RSSI, error: error) }
	}

	func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
		Task { await connection?.didUpdateNotificationStateFor(characteristic: characteristic, error: error) }
	}
}

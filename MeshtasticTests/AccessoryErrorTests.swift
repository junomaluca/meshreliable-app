// AccessoryErrorTests.swift
// MeshtasticTests

import Testing
import Foundation
import CoreBluetooth
@testable import Meshtastic

// MARK: - AccessoryError Tests

@Suite("AccessoryError")
struct AccessoryErrorTests {

	@Test func discoveryFailed_hasCorrectDescription() {
		let error = AccessoryError.discoveryFailed("No devices found")
		#expect(error.errorDescription?.contains("Discovery failed") == true)
		#expect(error.errorDescription?.contains("No devices found") == true)
	}

	@Test func connectionFailed_hasCorrectDescription() {
		let error = AccessoryError.connectionFailed("Timeout")
		#expect(error.errorDescription?.contains("Connection failed") == true)
		#expect(error.errorDescription?.contains("Timeout") == true)
	}

	@Test func versionMismatch_hasCorrectDescription() {
		let error = AccessoryError.versionMismatch("2.4.0 < 2.5.18")
		#expect(error.errorDescription?.contains("Version mismatch") == true)
		#expect(error.errorDescription?.contains("2.4.0") == true)
	}

	@Test func ioFailed_hasCorrectDescription() {
		let error = AccessoryError.ioFailed("Write failed")
		#expect(error.errorDescription?.contains("Communication failure") == true)
		#expect(error.errorDescription?.contains("Write failed") == true)
	}

	@Test func appError_hasCorrectDescription() {
		let error = AccessoryError.appError("Config save failed")
		#expect(error.errorDescription?.contains("Application error") == true)
		#expect(error.errorDescription?.contains("Config save failed") == true)
	}

	@Test func timeout_hasCorrectDescription() {
		let error = AccessoryError.timeout
		#expect(error.errorDescription == "Connection Timeout")
	}

	@Test func disconnected_hasCorrectDescription() {
		let error = AccessoryError.disconnected("User initiated")
		#expect(error.errorDescription?.contains("Disconnected") == true)
		#expect(error.errorDescription?.contains("User initiated") == true)
	}

	@Test func tooManyRetries_hasCorrectDescription() {
		let error = AccessoryError.tooManyRetries
		#expect(error.errorDescription == "Too Many Retries")
	}

	@Test func eventStreamCancelled_hasCorrectDescription() {
		let error = AccessoryError.eventStreamCancelled
		#expect(error.errorDescription == "Event stream cancelled")
	}

	@Test func allCases_haveNonNilDescriptions() {
		let errors: [AccessoryError] = [
			.discoveryFailed("test"),
			.connectionFailed("test"),
			.versionMismatch("test"),
			.ioFailed("test"),
			.appError("test"),
			.timeout,
			.disconnected("test"),
			.tooManyRetries,
			.eventStreamCancelled,
		]
		for error in errors {
			#expect(error.errorDescription != nil, "Error \(error) should have a description")
			#expect(!error.errorDescription!.isEmpty, "Error \(error) should have a non-empty description")
		}
	}

	@Test func conformsToLocalizedError() {
		let error: any LocalizedError = AccessoryError.timeout
		#expect(error.errorDescription != nil)
	}
}

// MARK: - AccessoryManagerState Tests

@Suite("AccessoryManagerState")
struct AccessoryManagerStateTests {

	@Test func uninitialized_description() {
		let state = AccessoryManagerState.uninitialized
		#expect(state.description == "Uninitialized")
	}

	@Test func idle_description() {
		let state = AccessoryManagerState.idle
		#expect(state.description == "Idle")
	}

	@Test func discovering_description() {
		let state = AccessoryManagerState.discovering
		#expect(state.description == "Discovering")
	}

	@Test func connecting_description() {
		let state = AccessoryManagerState.connecting
		#expect(state.description == "Connecting")
	}

	@Test func retrying_description() {
		let state = AccessoryManagerState.retrying(attempt: 2, maxAttempts: 5)
		#expect(state.description == "Retrying Connection (2 of 5)")
	}

	@Test func communicating_description() {
		let state = AccessoryManagerState.communicating
		#expect(state.description == "Communicating")
	}

	@Test func subscribed_description() {
		let state = AccessoryManagerState.subscribed
		#expect(state.description == "Subscribed")
	}

	@Test func retrievingDatabase_description() {
		let state = AccessoryManagerState.retrievingDatabase(nodeCount: 42)
		#expect(state.description == "Retrieving nodes 42")
	}

	@Test func equality_sameStates() {
		#expect(AccessoryManagerState.idle == AccessoryManagerState.idle)
		#expect(AccessoryManagerState.connecting == AccessoryManagerState.connecting)
		#expect(AccessoryManagerState.retrying(attempt: 1, maxAttempts: 3) == AccessoryManagerState.retrying(attempt: 1, maxAttempts: 3))
	}

	@Test func equality_differentStates() {
		#expect(AccessoryManagerState.idle != AccessoryManagerState.connecting)
		#expect(AccessoryManagerState.retrying(attempt: 1, maxAttempts: 3) != AccessoryManagerState.retrying(attempt: 2, maxAttempts: 3))
		#expect(AccessoryManagerState.retrievingDatabase(nodeCount: 5) != AccessoryManagerState.retrievingDatabase(nodeCount: 10))
	}

	@Test func retrying_withDifferentAttempts_notEqual() {
		let state1 = AccessoryManagerState.retrying(attempt: 1, maxAttempts: 5)
		let state2 = AccessoryManagerState.retrying(attempt: 2, maxAttempts: 5)
		#expect(state1 != state2)
	}

	@Test func retrying_withDifferentMax_notEqual() {
		let state1 = AccessoryManagerState.retrying(attempt: 1, maxAttempts: 3)
		let state2 = AccessoryManagerState.retrying(attempt: 1, maxAttempts: 5)
		#expect(state1 != state2)
	}
}

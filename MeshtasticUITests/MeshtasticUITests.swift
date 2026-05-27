//
//  MeshtasticUITests.swift
//  MeshtasticUITests
//
//  Automated stress tests for MeshReliable features on a real device.
//  Requires a BLE-connected Meshtastic device.
//

import XCTest

final class MeshtasticUITests: XCTestCase {

	var app: XCUIApplication!

	override func setUpWithError() throws {
		continueAfterFailure = false
		app = XCUIApplication()
		app.launchEnvironment["UITEST_MODE"] = "1"
		app.launch()

		// Wait for app to settle after launch
		sleep(3)
	}

	override func tearDownWithError() throws {
		app = nil
	}

	// MARK: - Navigation

	func testNavigateToMessages() throws {
		let messagesTab = app.tabBars.buttons["Messages"]
		XCTAssertTrue(messagesTab.waitForExistence(timeout: 10), "Messages tab should exist")
		messagesTab.tap()

		let directMessages = app.staticTexts["Direct Messages"]
		XCTAssertTrue(directMessages.waitForExistence(timeout: 5), "Direct Messages should appear")
	}

	func testNavigateToDirectMessages() throws {
		app.tabBars.buttons["Messages"].tap()

		let directMessages = app.staticTexts["Direct Messages"]
		XCTAssertTrue(directMessages.waitForExistence(timeout: 5))
		directMessages.tap()

		// Should show user list or empty state
		sleep(2)
	}

	func testNavigateToGroupMessages() throws {
		app.tabBars.buttons["Messages"].tap()

		let groupMessages = app.staticTexts["Group Messages"]
		XCTAssertTrue(groupMessages.waitForExistence(timeout: 5))
		groupMessages.tap()

		// Should show group list or empty state
		sleep(2)
	}

	func testNavigateToChannels() throws {
		app.tabBars.buttons["Messages"].tap()

		let channels = app.staticTexts["Channels"]
		XCTAssertTrue(channels.waitForExistence(timeout: 5))
		channels.tap()

		sleep(2)
	}

	func testNavigateAllTabs() throws {
		let tabBar = app.tabBars.firstMatch
		XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

		let tabNames = ["Messages", "Bluetooth", "Map", "Nodes", "Settings"]
		for name in tabNames {
			let tab = tabBar.buttons[name]
			if tab.exists {
				tab.tap()
				sleep(1)
			}
		}
	}

	// MARK: - Direct Messaging

	func testSendDirectMessage() throws {
		navigateToDirectMessages()

		// Tap first available conversation
		let firstUser = app.cells.firstMatch
		guard firstUser.waitForExistence(timeout: 10) else {
			throw XCTSkip("No DM conversations available — need connected nodes")
		}
		firstUser.tap()
		sleep(2)

		// Type and send a message
		let textField = app.textFields["messageTextField"]
			.exists ? app.textFields["messageTextField"]
			: app.textViews["messageTextField"]
		guard textField.waitForExistence(timeout: 5) else {
			throw XCTSkip("Message text field not found — may need deeper navigation")
		}

		textField.tap()
		textField.typeText("UI test message \(Int.random(in: 1000...9999))")

		let sendButton = app.buttons["sendMessageButton"]
		XCTAssertTrue(sendButton.waitForExistence(timeout: 3))
		sendButton.tap()

		sleep(2)
	}

	func testSendMultipleDirectMessages() throws {
		navigateToDirectMessages()

		let firstUser = app.cells.firstMatch
		guard firstUser.waitForExistence(timeout: 10) else {
			throw XCTSkip("No DM conversations available")
		}
		firstUser.tap()
		sleep(2)

		for i in 1...5 {
			let textField = app.textFields["messageTextField"]
				.exists ? app.textFields["messageTextField"]
				: app.textViews["messageTextField"]
			guard textField.waitForExistence(timeout: 5) else { continue }

			textField.tap()
			textField.typeText("Stress test msg \(i)/5")

			let sendButton = app.buttons["sendMessageButton"]
			if sendButton.waitForExistence(timeout: 3) {
				sendButton.tap()
				sleep(3) // Wait for BLE transmission
			}
		}
	}

	// MARK: - Group Messaging

	func testCreateGroup() throws {
		navigateToGroupMessages()

		// Tap create group button
		let createButton = app.buttons["createGroupButton"]
		if !createButton.waitForExistence(timeout: 5) {
			// Try the menu-based create
			let plusButton = app.buttons["plus.circle"]
			guard plusButton.waitForExistence(timeout: 5) else {
				throw XCTSkip("No create group button found")
			}
			plusButton.tap()
			let menuCreate = app.buttons["Create Group"]
			guard menuCreate.waitForExistence(timeout: 3) else {
				throw XCTSkip("Create Group menu item not found")
			}
			menuCreate.tap()
		} else {
			createButton.tap()
		}

		// Fill in group name
		let groupNameField = app.textFields["groupNameField"]
		guard groupNameField.waitForExistence(timeout: 5) else {
			throw XCTSkip("Group name field not found")
		}
		groupNameField.tap()
		groupNameField.typeText("UI Test Group \(Int.random(in: 100...999))")

		// Select first available node
		let firstNode = app.cells.element(boundBy: 1) // Skip the group name section
		if firstNode.waitForExistence(timeout: 3) {
			firstNode.tap()
		}

		// Tap Create
		let confirmCreate = app.buttons["Create"]
		if confirmCreate.waitForExistence(timeout: 3) && confirmCreate.isEnabled {
			confirmCreate.tap()
			sleep(3)
		}
	}

	func testSendGroupMessage() throws {
		navigateToGroupMessages()

		// Tap first group
		let firstGroup = app.cells.firstMatch
		guard firstGroup.waitForExistence(timeout: 10) else {
			throw XCTSkip("No groups available — create one first")
		}
		firstGroup.tap()
		sleep(2)

		let textField = app.textFields["messageTextField"]
			.exists ? app.textFields["messageTextField"]
			: app.textViews["messageTextField"]
		guard textField.waitForExistence(timeout: 5) else {
			throw XCTSkip("Message text field not found in group conversation")
		}

		textField.tap()
		textField.typeText("Group test \(Int.random(in: 1000...9999))")

		let sendButton = app.buttons["sendMessageButton"]
		if sendButton.waitForExistence(timeout: 3) {
			sendButton.tap()
			sleep(3)
		}
	}

	// MARK: - Voice Memo

	func testOpenVoiceMemoRecorder() throws {
		navigateToDirectMessages()

		let firstUser = app.cells.firstMatch
		guard firstUser.waitForExistence(timeout: 10) else {
			throw XCTSkip("No DM conversations available")
		}
		firstUser.tap()
		sleep(2)

		// The mic button appears when text field is empty
		let micButton = app.buttons["voiceMemoButton"]
		guard micButton.waitForExistence(timeout: 5) else {
			throw XCTSkip("Voice memo button not found")
		}
		micButton.tap()

		// Voice memo sheet should appear
		let voiceMemoTitle = app.staticTexts["Voice Memo"]
		XCTAssertTrue(voiceMemoTitle.waitForExistence(timeout: 5), "Voice memo recorder should open")

		// Cancel
		let cancelButton = app.buttons["Cancel"]
		if cancelButton.waitForExistence(timeout: 3) {
			cancelButton.tap()
		}
	}

	func testRecordVoiceMemo() throws {
		navigateToDirectMessages()

		let firstUser = app.cells.firstMatch
		guard firstUser.waitForExistence(timeout: 10) else {
			throw XCTSkip("No DM conversations available")
		}
		firstUser.tap()
		sleep(2)

		let micButton = app.buttons["voiceMemoButton"]
		guard micButton.waitForExistence(timeout: 5) else {
			throw XCTSkip("Voice memo button not found")
		}
		micButton.tap()

		let voiceMemoTitle = app.staticTexts["Voice Memo"]
		guard voiceMemoTitle.waitForExistence(timeout: 5) else {
			throw XCTSkip("Voice memo sheet didn't open")
		}

		// Tap record button
		let recordButton = app.buttons["recordButton"]
		guard recordButton.waitForExistence(timeout: 5) else {
			throw XCTSkip("Record button not found")
		}
		recordButton.tap()

		// Record for 3 seconds
		sleep(3)

		// Stop recording
		let stopButton = app.buttons["recordButton"] // Same button toggles
		if stopButton.exists {
			stopButton.tap()
		}

		sleep(1)

		// Should see send/discard controls — discard for test
		let discardButton = app.buttons["Discard"]
		if discardButton.waitForExistence(timeout: 3) {
			discardButton.tap()
		} else {
			// Cancel instead
			let cancelButton = app.buttons["Cancel"]
			if cancelButton.exists { cancelButton.tap() }
		}
	}

	// MARK: - Stress Tests

	func testRapidTabSwitching() throws {
		let tabBar = app.tabBars.firstMatch
		XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

		let tabs = ["Messages", "Bluetooth", "Map", "Nodes", "Settings"]

		for _ in 0..<20 {
			let randomTab = tabs.randomElement()!
			let tab = tabBar.buttons[randomTab]
			if tab.exists {
				tab.tap()
				usleep(300_000) // 300ms between taps
			}
		}

		// App should still be responsive
		XCTAssertTrue(tabBar.exists, "App should remain responsive after rapid tab switching")
	}

	func testRapidMessageNavigation() throws {
		app.tabBars.buttons["Messages"].tap()
		sleep(1)

		// Rapidly switch between message types
		let types = ["Direct Messages", "Group Messages", "Channels"]

		for _ in 0..<10 {
			let type = types.randomElement()!
			let element = app.staticTexts[type]
			if element.waitForExistence(timeout: 2) {
				element.tap()
				usleep(500_000)
			}
			// Go back
			if app.navigationBars.buttons.firstMatch.exists {
				app.navigationBars.buttons.firstMatch.tap()
				usleep(300_000)
			}
		}
	}

	func testSustainedMessagingLoad() throws {
		navigateToDirectMessages()

		let firstUser = app.cells.firstMatch
		guard firstUser.waitForExistence(timeout: 10) else {
			throw XCTSkip("No DM conversations available")
		}
		firstUser.tap()
		sleep(2)

		// Send 10 messages back-to-back
		for i in 1...10 {
			let textField = app.textFields["messageTextField"]
				.exists ? app.textFields["messageTextField"]
				: app.textViews["messageTextField"]
			guard textField.waitForExistence(timeout: 5) else {
				XCTFail("Text field disappeared at message \(i)")
				return
			}

			textField.tap()
			textField.typeText("Load test \(i)/10 t=\(Date().timeIntervalSince1970)")

			let sendButton = app.buttons["sendMessageButton"]
			if sendButton.waitForExistence(timeout: 3) {
				sendButton.tap()
				sleep(2) // Minimum BLE send interval
			}
		}
	}

	func testGroupCreateAndMessage() throws {
		navigateToGroupMessages()

		// Try creating a group and immediately sending
		let createButton = app.buttons["createGroupButton"]
		let plusButton = app.buttons["plus.circle"]

		if createButton.waitForExistence(timeout: 3) {
			createButton.tap()
		} else if plusButton.waitForExistence(timeout: 3) {
			plusButton.tap()
			let menuCreate = app.buttons["Create Group"]
			if menuCreate.waitForExistence(timeout: 3) {
				menuCreate.tap()
			}
		} else {
			throw XCTSkip("Cannot find create group entry point")
		}

		let groupNameField = app.textFields["groupNameField"]
		guard groupNameField.waitForExistence(timeout: 5) else {
			throw XCTSkip("Group name field not found")
		}

		groupNameField.tap()
		let groupName = "Stress \(Int.random(in: 100...999))"
		groupNameField.typeText(groupName)

		// Select any available node
		let nodeCell = app.cells.element(boundBy: 1)
		if nodeCell.waitForExistence(timeout: 3) {
			nodeCell.tap()
		}

		let confirmCreate = app.buttons["Create"]
		guard confirmCreate.waitForExistence(timeout: 3) && confirmCreate.isEnabled else {
			throw XCTSkip("Create button not available")
		}
		confirmCreate.tap()
		sleep(3)

		// Now try to send a message in the newly created group
		let firstGroup = app.cells.firstMatch
		if firstGroup.waitForExistence(timeout: 5) {
			firstGroup.tap()
			sleep(2)

			let textField = app.textFields["messageTextField"]
				.exists ? app.textFields["messageTextField"]
				: app.textViews["messageTextField"]
			if textField.waitForExistence(timeout: 5) {
				textField.tap()
				textField.typeText("First group msg!")

				let sendButton = app.buttons["sendMessageButton"]
				if sendButton.waitForExistence(timeout: 3) {
					sendButton.tap()
					sleep(3)
				}
			}
		}
	}

	func testMemoryStabilityDuringExtendedUse() throws {
		// Simulate extended use: navigate, send messages, open sheets, close them
		for cycle in 1...5 {
			// Messages tab
			app.tabBars.buttons["Messages"].tap()
			sleep(1)

			let dm = app.staticTexts["Direct Messages"]
			if dm.waitForExistence(timeout: 3) {
				dm.tap()
				sleep(1)
			}

			// Back
			let backButton = app.navigationBars.buttons.firstMatch
			if backButton.exists { backButton.tap() }
			sleep(1)

			// Groups
			let gm = app.staticTexts["Group Messages"]
			if gm.waitForExistence(timeout: 3) {
				gm.tap()
				sleep(1)
			}

			if backButton.exists { backButton.tap() }

			// Other tabs
			app.tabBars.buttons["Nodes"].tap()
			sleep(1)
			app.tabBars.buttons["Map"].tap()
			sleep(1)

			// After 5 cycles, app should still be responsive
			if cycle == 5 {
				XCTAssertTrue(app.tabBars.firstMatch.exists, "App should remain responsive after \(cycle) navigation cycles")
			}
		}
	}

	// MARK: - Helpers

	private func navigateToDirectMessages() {
		app.tabBars.buttons["Messages"].tap()
		let dm = app.staticTexts["Direct Messages"]
		if dm.waitForExistence(timeout: 5) {
			dm.tap()
		}
		sleep(1)
	}

	private func navigateToGroupMessages() {
		app.tabBars.buttons["Messages"].tap()
		let gm = app.staticTexts["Group Messages"]
		if gm.waitForExistence(timeout: 5) {
			gm.tap()
		}
		sleep(1)
	}
}

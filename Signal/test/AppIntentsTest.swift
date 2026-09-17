//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

@available(iOS 16.0, *)
final class AppIntentsTest: XCTestCase {
    func testOnlyQuickSendRunsWithoutForegroundingSignal() {
        XCTAssertFalse(SendSignalMessageIntent.openAppWhenRun)
        XCTAssertTrue(OpenSignalConversationIntent.openAppWhenRun)
        XCTAssertTrue(NewSignalMessageIntent.openAppWhenRun)
        XCTAssertTrue(OpenSignalCameraIntent.openAppWhenRun)
        XCTAssertTrue(OpenSignalSettingsIntent.openAppWhenRun)
    }
}

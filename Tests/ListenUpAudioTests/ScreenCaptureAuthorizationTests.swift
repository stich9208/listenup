import Foundation
import ScreenCaptureKit
import XCTest
@testable import ListenUpAudio

final class ScreenCaptureAuthorizationTests: XCTestCase {
    func testUserDeclinedIsAuthorizationDenied() {
        let error = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue
        )

        XCTAssertTrue(ScreenCaptureAuthorization.isDenied(error))
    }

    func testOtherScreenCaptureFailureIsNotAuthorizationDenied() {
        let error = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.failedToStart.rawValue
        )

        XCTAssertFalse(ScreenCaptureAuthorization.isDenied(error))
    }

    func testUnrelatedPermissionTextIsNotAuthorizationDenied() {
        let error = NSError(
            domain: "ListenUpTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "permission denied"]
        )

        XCTAssertFalse(ScreenCaptureAuthorization.isDenied(error))
    }
}

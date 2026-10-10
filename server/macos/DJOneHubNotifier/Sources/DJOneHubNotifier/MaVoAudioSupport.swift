// SPDX-License-Identifier: MIT
// Compatibility declarations required by the unmodified MaVo 0.1.2 audio service.

import Foundation

enum ModemActionResult: Equatable {
    case success(String? = nil)
    case failure(String)
}

struct UACMediaSnapshot: Equatable {
    var inputFrames: UInt64 = 0
    var outputFrames: UInt64 = 0
    var inputTotalSamples: UInt64 = 0
    var inputSignalSamples: UInt64 = 0
    var inputPeakPCM16: UInt32 = 0
    var inputSignalThresholdPCM16: UInt32 = 0
}

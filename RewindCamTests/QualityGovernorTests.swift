import Foundation
import Testing
@testable import RewindCam

@Suite("Quality governor")
struct QualityGovernorTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let user: QualityPreset
        let thermal: ThermalLevel
        let expected: QualityPreset
        var testDescription: String { "\(user) @ \(thermal) → \(expected)" }
    }

    static let cases: [Case] = [
        Case(user: QualityPreset(resolution: .hd1080, frameRate: .fps30), thermal: ThermalLevel.serious, expected: QualityPreset(resolution: .hd720, frameRate: .fps30)),
        Case(user: QualityPreset(resolution: .hd1080, frameRate: .fps60), thermal: ThermalLevel.serious, expected: QualityPreset(resolution: .hd720, frameRate: .fps30)),
        Case(user: QualityPreset(resolution: .uhd4K, frameRate: .fps60), thermal: ThermalLevel.serious, expected: QualityPreset(resolution: .hd1080, frameRate: .fps30)),
        Case(user: QualityPreset(resolution: .hd720, frameRate: .fps60), thermal: ThermalLevel.serious, expected: QualityPreset(resolution: .hd720, frameRate: .fps30)),
        Case(user: QualityPreset(resolution: .uhd4K, frameRate: .fps60), thermal: ThermalLevel.critical, expected: QualityPreset.lowest),
        Case(user: QualityPreset(resolution: .uhd4K, frameRate: .fps60), thermal: ThermalLevel.fair, expected: QualityPreset(resolution: .uhd4K, frameRate: .fps60)),
        Case(user: QualityPreset(resolution: .hd1080, frameRate: .fps30), thermal: ThermalLevel.nominal, expected: QualityPreset(resolution: .hd1080, frameRate: .fps30)),
    ]

    @Test(arguments: cases)
    func effectivePreset(_ c: Case) {
        #expect(QualityGovernor.effectivePreset(user: c.user, thermal: c.thermal) == c.expected)
    }

    @Test func stepDownNeverRaisesBitrate() {
        for res in VideoResolution.allCases {
            for fps in FrameRate.allCases {
                let user = QualityPreset(resolution: res, frameRate: fps)
                for level in ThermalLevel.allCases {
                    let eff = QualityGovernor.effectivePreset(user: user, thermal: level)
                    #expect(eff.videoBitrate <= user.videoBitrate)
                }
            }
        }
    }
}

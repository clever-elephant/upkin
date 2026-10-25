import Foundation

public enum GrokBallEmotion: String, CaseIterable, Sendable {
    case idle = "02"
    case thinking = "30"
    case working = "32"
    case waiting = "35"
    case completed = "33"
    case error = "34"
    case unknown = "11"

}

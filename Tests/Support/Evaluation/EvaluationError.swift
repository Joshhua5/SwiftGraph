import Foundation
import SwiftGraph

#if canImport(CryptoKit)
import CryptoKit
#endif

enum EvaluationError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): message
        }
    }
}

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct PaneDragPayload: Codable, Hashable, Transferable {
    enum PaneSide: String, Codable {
        case local
        case remote
    }

    var side: PaneSide
    var fileNames: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType.json)
    }
}

enum FilePaneSide {
    case local
    case remote

    var dragSide: PaneDragPayload.PaneSide {
        switch self {
        case .local: .local
        case .remote: .remote
        }
    }

    func acceptsDrop(from source: PaneDragPayload.PaneSide) -> Bool {
        switch (self, source) {
        case (.remote, .local), (.local, .remote):
            return true
        default:
            return false
        }
    }
}

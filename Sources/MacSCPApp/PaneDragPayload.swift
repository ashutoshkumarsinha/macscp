// PaneDragPayload.swift
//
// WHAT THIS FILE DOES
// -------------------
// Drag-and-drop payload for file panes and drop-target validation helpers.
// PaneDragPayload crosses panes via SwiftUI Transferable; FilePaneSide wraps PaneTransferRules.
//
import CoreTransferable
import Foundation
import MacSCPCore
import UniformTypeIdentifiers

struct PaneDragPayload: Codable, Hashable, Transferable {
    var side: PaneSide
    var fileNames: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType.json)
    }
}

enum FilePaneSide {
    case local
    case remote

    var dragSide: PaneSide {
        switch self {
        case .local: .local
        case .remote: .remote
        }
    }

    func acceptsDrop(from source: PaneSide) -> Bool {
        PaneTransferRules.acceptsDrop(from: source, to: dragSide)
    }
}

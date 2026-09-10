import Foundation

/// Local mirror storage for a Mac snapshot. Segments and a note belong to their
/// call, so removing a call always removes them first; a call that later
/// reappears then re-inserts its segments without colliding with orphaned rows.
public protocol MirrorWriting {
    func localCallIDs() throws -> [UUID]
    func removeSegments(callID: UUID) throws
    func removeNote(callID: UUID) throws
    func removeCall(id: UUID) throws
    func upsertCall(_ call: SyncDTO.MirroredCall) throws
    func insertSegments(_ segments: [SyncDTO.MirroredSegment], callID: UUID) throws
    func insertNote(_ note: SyncDTO.MirroredNote, callID: UUID) throws
    func commit() throws
}

/// The one place that decides how a fetched mirror becomes local state, so the
/// iOS SwiftData store and its tests cannot drift apart.
public enum MirrorReconciler {
    public static func apply(_ mirror: SyncDTO.Mirror, to writer: some MirrorWriting) throws {
        let remoteIDs = Set(mirror.calls.map(\.id))
        for id in try writer.localCallIDs() where !remoteIDs.contains(id) {
            try writer.removeSegments(callID: id)
            try writer.removeNote(callID: id)
            try writer.removeCall(id: id)
        }
        for call in mirror.calls {
            try writer.upsertCall(call)
            try writer.removeSegments(callID: call.id)
            try writer.insertSegments(call.segments, callID: call.id)
            try writer.removeNote(callID: call.id)
            if let note = call.note { try writer.insertNote(note, callID: call.id) }
        }
        try writer.commit()
    }
}

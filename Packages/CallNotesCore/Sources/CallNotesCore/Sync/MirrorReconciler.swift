import Foundation

/// Local mirror storage for a Mac snapshot. Segments and a note belong to their
/// call, so removing a call always removes them first; a call that later
/// reappears then re-inserts its segments without colliding with orphaned rows.
///
/// A call that is still present is updated in place: the reconciler asks for the
/// stored segment identifiers, removes only the ones the snapshot dropped, and
/// upserts the rest. Deleting and re-inserting the same unique identifiers in a
/// single unsaved transaction has no defined ordering in SwiftData.
public protocol MirrorWriting {
    func localCallIDs() throws -> [UUID]
    func localSegmentIDs(callID: UUID) throws -> [String]
    func removeSegment(id: String) throws
    func removeSegments(callID: UUID) throws
    func removeNote(callID: UUID) throws
    func removeCall(id: UUID) throws
    func upsertCall(_ call: SyncDTO.MirroredCall) throws
    func upsertSegment(_ segment: SyncDTO.MirroredSegment, callID: UUID) throws
    func upsertNote(_ note: SyncDTO.MirroredNote, callID: UUID) throws
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
            let remoteSegmentIDs = Set(call.segments.map(\.id))
            for id in try writer.localSegmentIDs(callID: call.id) where !remoteSegmentIDs.contains(id) {
                try writer.removeSegment(id: id)
            }
            for segment in call.segments {
                try writer.upsertSegment(segment, callID: call.id)
            }
            if let note = call.note {
                try writer.upsertNote(note, callID: call.id)
            } else {
                try writer.removeNote(callID: call.id)
            }
        }
        try writer.commit()
    }
}

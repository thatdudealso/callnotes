import Foundation
import Testing

@testable import CallNotesCore

@Suite struct ImportProgressTests {
    private func job(_ name: String, stage: ImportStage) -> ImportJob {
        ImportJob(
            fileName: name,
            sourceURL: URL(fileURLWithPath: "/inbox/\(name)"),
            stage: stage
        )
    }

    @Test func succeededNoticeDisappearsAfterItsRetention() {
        let start = Date(timeIntervalSince1970: 1_000)
        var progress = ImportProgress()
        progress.upsert(job("done.m4a", stage: .completed), now: start)

        #expect(progress.jobs.map(\.fileName) == ["done.m4a"])
        #expect(progress.jobs.first?.finishedAt == start)

        progress.prune(now: start.addingTimeInterval(ImportProgress.completedNoticeSeconds - 0.5))
        #expect(progress.jobs.count == 1)

        progress.prune(now: start.addingTimeInterval(ImportProgress.completedNoticeSeconds))
        #expect(progress.jobs.isEmpty)
    }

    @Test func failedNoticeStaysUntilItIsDismissed() {
        let start = Date(timeIntervalSince1970: 2_000)
        var progress = ImportProgress()
        var failed = job("broken.m4a", stage: .failed)
        failed.error = "Could not decode"
        progress.upsert(failed, now: start)

        progress.prune(now: start.addingTimeInterval(ImportProgress.completedNoticeSeconds * 10))
        #expect(progress.jobs.map(\.fileName) == ["broken.m4a"])

        progress.dismiss(failed.id)
        #expect(progress.jobs.isEmpty)
    }

    @Test func duplicateNoticeExpiresButActiveWorkIsKept() {
        let start = Date(timeIntervalSince1970: 3_000)
        var progress = ImportProgress()
        progress.upsert(job("again.m4a", stage: .duplicate), now: start)
        progress.upsert(job("running.m4a", stage: .transcribing), now: start)

        progress.prune(now: start.addingTimeInterval(ImportProgress.completedNoticeSeconds))

        #expect(progress.jobs.map(\.fileName) == ["running.m4a"])
        #expect(progress.isImporting)
        #expect(progress.jobs.first?.finishedAt == nil)
    }

    @Test func advancingAJobKeepsItsOriginalFinishTime() {
        let start = Date(timeIntervalSince1970: 4_000)
        var progress = ImportProgress()
        var running = job("slow.m4a", stage: .transcribing)
        progress.upsert(running, now: start)

        running.stage = .completed
        progress.upsert(running, now: start.addingTimeInterval(1))
        #expect(progress.jobs.first?.finishedAt == start.addingTimeInterval(1))

        progress.upsert(running, now: start.addingTimeInterval(2))
        #expect(progress.jobs.count == 1)
        #expect(progress.jobs.first?.finishedAt == start.addingTimeInterval(1))
    }

    @Test func anActiveJobIsNeverPruned() {
        let start = Date(timeIntervalSince1970: 5_000)
        var progress = ImportProgress()
        progress.upsert(job("working.m4a", stage: .notes), now: start)

        progress.prune(now: start.addingTimeInterval(600))

        #expect(progress.jobs.count == 1)
    }
}

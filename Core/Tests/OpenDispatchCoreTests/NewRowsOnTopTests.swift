import Testing
@testable import OpenDispatchCore

@Suite struct NewRowsOnTopTests {
    private func arrange(_ layout: inout NewRowsOnTop, page: [Int64], previous: [Int64], newest: Int64? = nil) -> (rows: [Int64], arrived: Set<Int64>) {
        layout.arrange(page: page, previous: previous, newestID: newest ?? page.max(), id: { $0 })
    }

    private func loaded(_ newest: Int64) -> NewRowsOnTop {
        var layout = NewRowsOnTop()
        layout.reset(newestID: newest)
        return layout
    }

    @Test func newRowsRankedMidListGoOnTopAndOldRowsStayInOrder() {
        var layout = loaded(5)
        // The ranking put 6 and 7 in the middle and moved the old rows around.
        let r = arrange(&layout, page: [2, 6, 1, 7, 5, 3, 4], previous: [1, 2, 3, 4, 5])
        #expect(r.rows == [6, 7, 1, 2, 3, 4, 5])
        #expect(r.arrived == [6, 7])
    }

    @Test func rowsOnTopStayOnTopAsMoreArriveDuringARefresh() {
        var layout = loaded(5)
        layout.refreshStarted()
        let first = arrange(&layout, page: [6, 1, 2, 3], previous: [1, 2, 3])
        #expect(first.rows == [6, 1, 2, 3])
        // Ranked among themselves, as the page has them; the old rows don't move.
        let second = arrange(&layout, page: [3, 7, 1, 6, 2], previous: first.rows)
        #expect(second.rows == [7, 6, 1, 2, 3])
        #expect(second.arrived == [7])
    }

    @Test func aReloadWithNothingNewChangesNothing() {
        var layout = loaded(5)
        let first = arrange(&layout, page: [6, 2, 1], previous: [1, 2])
        #expect(first.rows == [6, 1, 2])
        let again = arrange(&layout, page: [2, 1, 6], previous: first.rows)
        #expect(again.rows == [6, 1, 2])
        #expect(again.arrived.isEmpty)
    }

    @Test func theNextRefreshsNewRowsMergeTheLastBatchIntoTheRanking() {
        var layout = loaded(5)
        let batch = arrange(&layout, page: [6, 2, 1], previous: [1, 2])
        #expect(batch.rows == [6, 1, 2])

        layout.refreshStarted()
        // A refresh with nothing new leaves the list as it is.
        let quiet = arrange(&layout, page: [2, 6, 1], previous: batch.rows)
        #expect(quiet.rows == [6, 1, 2])

        let next = arrange(&layout, page: [2, 7, 6, 1], previous: quiet.rows)
        #expect(next.rows == [7, 2, 6, 1])
        #expect(next.arrived == [7])
    }

    @Test func rowsThatOnlyCameIntoThePageAreNotNew() {
        var layout = loaded(9)
        // A deeper reload reaches rows stored long ago, some with ids above the deepest listed row's.
        let r = arrange(&layout, page: [2, 3, 1, 8, 7], previous: [2, 3], newest: 9)
        #expect(r.arrived.isEmpty)
        #expect(r.rows == [2, 3, 1, 8, 7])
    }

    @Test func aRowStoredBetweenTheTwoReadsIsNewOnce() {
        var layout = loaded(5)
        #expect(arrange(&layout, page: [7, 1], previous: [1], newest: 6).arrived == [7])
        #expect(arrange(&layout, page: [7, 1], previous: [7, 1], newest: 7).arrived.isEmpty)
    }

    @Test func aRowThatComesBackFollowsItsNeighbourInTheRanking() {
        var layout = loaded(5)
        let r = arrange(&layout, page: [1, 4, 2, 3], previous: [1, 2, 3], newest: 5)
        #expect(r.rows == [1, 4, 2, 3])
        // First in the ranking: first among the old rows, under the new ones.
        var other = loaded(5)
        let top = arrange(&other, page: [6, 4, 1, 2], previous: [2, 1], newest: 6)
        #expect(top.rows == [6, 4, 2, 1])
    }

    @Test func rowsThatLeftThePageAreDropped() {
        var layout = loaded(5)
        let first = arrange(&layout, page: [6, 7, 1, 2], previous: [1, 2])
        let second = arrange(&layout, page: [7, 2], previous: first.rows, newest: 7)
        #expect(second.rows == [7, 2])
        #expect(layout.newIDs == [7])
    }

    @Test func aResetForgetsTheBatch() {
        var layout = loaded(5)
        _ = arrange(&layout, page: [6, 1], previous: [1])
        layout.reset(newestID: 6)
        #expect(layout.newIDs.isEmpty)
        let r = arrange(&layout, page: [1, 6], previous: [1, 6], newest: 6)
        #expect(r.rows == [1, 6])
        #expect(r.arrived.isEmpty)
    }
}

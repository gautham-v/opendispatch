/// Where a reload puts a list's rows, so a refresh's new posts are easy to find: new rows on top, ranked among themselves,
/// and the rows that were already listed in the order they had. A new row is one stored since the list last loaded, so rows
/// that only came into the page (a deeper reload, a read row unhidden) aren't new. The rows on top join the ranked list when
/// the next refresh brings new rows.
public struct NewRowsOnTop: Sendable {
    public private(set) var newIDs: Set<Int64> = []
    private var newestKnownID: Int64?
    private var startsNewBatch = false

    public init() {}

    /// The next new rows start a new batch, with everything before them ranked again.
    public mutating func refreshStarted() {
        startsNewBatch = true
    }

    /// The list loaded as ranked: nothing is new, and `newestID` is the newest item stored so far.
    public mutating func reset(newestID: Int64?) {
        newIDs = []
        newestKnownID = newestID
        startsNewBatch = false
    }

    /// Orders `page` (one reload of the list, ranked) given the row ids `previous` the list showed. `newestID` is the newest
    /// item stored, read before the page. `arrived` is the rows new since the last call.
    public mutating func arrange<Row>(page: [Row], previous: [Int64], newestID: Int64?, id: (Row) -> Int64) -> (rows: [Row], arrived: Set<Int64>) {
        let known = newestKnownID
        if let newestID { newestKnownID = max(newestID, known ?? newestID) }
        let arrived = known.map { known in Set(page.map(id).filter { $0 > known }) } ?? []

        var kept = previous
        if !arrived.isEmpty, startsNewBatch {
            startsNewBatch = false
            newIDs = []
            kept = []
        }
        newIDs.formUnion(arrived)
        newIDs.formIntersection(page.map(id))

        let onTop = page.filter { newIDs.contains(id($0)) }
        let rest = page.filter { !newIDs.contains(id($0)) }
        let rowsByID = Dictionary(rest.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        var old = kept.compactMap { rowsByID[$0] }
        let keptIDs = Set(old.map(id))
        // A row that wasn't listed (it came back, or the page reached deeper) goes after the row it follows in the ranking.
        var before: Int64?
        for row in rest {
            let rowID = id(row)
            if !keptIDs.contains(rowID) {
                let at = before.flatMap { before in old.firstIndex { id($0) == before } }.map { $0 + 1 } ?? 0
                old.insert(row, at: at)
            }
            before = rowID
        }
        return (onTop + old, arrived)
    }
}

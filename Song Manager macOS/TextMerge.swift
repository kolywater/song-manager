import Foundation

enum TextMerge {

    /// 3-way line-based merge. Returns merged text with inline conflict markers where needed.
    static func merge(base: String, local: String, remote: String) -> String {
        if local == remote { return local }
        if local == base   { return remote }
        if remote == base  { return local }

        let baseLines = base.components(separatedBy: "\n")
        let localAct  = sideActions(baseCount: baseLines.count,
                                    ops: diff(from: baseLines, to: local.components(separatedBy: "\n")))
        let remoteAct = sideActions(baseCount: baseLines.count,
                                    ops: diff(from: baseLines, to: remote.components(separatedBy: "\n")))

        var result: [String] = []

        for i in 0..<baseLines.count {
            mergeBlock(localAct.before[i], remoteAct.before[i], into: &result)

            switch (localAct.kept[i], remoteAct.kept[i]) {
            case (true, true):
                result.append(baseLines[i])
            case (false, false):
                break
            default:
                result.append("<<<< LOCAL")
                if localAct.kept[i]  { result.append(baseLines[i]) }
                result.append("====")
                if remoteAct.kept[i] { result.append(baseLines[i]) }
                result.append(">>>> REMOTE")
            }
        }

        mergeBlock(localAct.trailing, remoteAct.trailing, into: &result)
        return result.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func mergeBlock(_ local: [String], _ remote: [String], into result: inout [String]) {
        if local == remote       { result.append(contentsOf: local) }
        else if local.isEmpty    { result.append(contentsOf: remote) }
        else if remote.isEmpty   { result.append(contentsOf: local) }
        else {
            result.append("<<<< LOCAL")
            result.append(contentsOf: local)
            result.append("====")
            result.append(contentsOf: remote)
            result.append(">>>> REMOTE")
        }
    }

    private struct SideActions {
        var before: [[String]]  // lines inserted before base line i
        var kept: [Bool]
        var trailing: [String]
    }

    private static func sideActions(baseCount: Int, ops: [Op]) -> SideActions {
        var before  = Array(repeating: [String](), count: baseCount)
        var kept    = Array(repeating: true, count: baseCount)
        var pending = [String]()
        var i = 0

        for op in ops {
            switch op {
            case .insert(let s): pending.append(s)
            case .equal:         before[i] = pending; pending = []; i += 1
            case .delete:        before[i] = pending; pending = []; kept[i] = false; i += 1
            }
        }
        return SideActions(before: before, kept: kept, trailing: pending)
    }

    // MARK: - LCS Diff

    private enum Op { case equal(String), insert(String), delete(String) }

    private static func diff(from old: [String], to new: [String]) -> [Op] {
        let m = old.count, n = new.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                dp[i][j] = old[i] == new[j]
                    ? 1 + dp[i+1][j+1]
                    : max(dp[i+1][j], dp[i][j+1])
            }
        }
        var ops = [Op]()
        var i = 0, j = 0
        while i < m || j < n {
            if i < m && j < n && old[i] == new[j] {
                ops.append(.equal(old[i]));  i += 1; j += 1
            } else if j < n && (i >= m || dp[i][j+1] >= dp[i+1][j]) {
                ops.append(.insert(new[j])); j += 1
            } else {
                ops.append(.delete(old[i])); i += 1
            }
        }
        return ops
    }
}

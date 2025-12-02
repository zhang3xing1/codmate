import Foundation
import SwiftUI

@MainActor
final class GitGraphViewModel: ObservableObject {
    @Published private(set) var commits: [GitService.GraphCommit] = []
    @Published var filteredCommits: [GitService.GraphCommit] = []
    @Published var selectedCommit: GitService.GraphCommit? = nil
    @Published var searchQuery: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String? = nil
    // Graph lane layout
    struct LaneInfo: Sendable, Hashable {
        var laneIndex: Int                // index of the commit's own lane
        var parentLaneIndices: [Int]      // lane indices of parents in next row
        var activeLaneCount: Int          // lanes count to consider for verticals this row
        var continuingLanes: Set<Int>     // lanes that should show a vertical line in this row
        var joinLaneIndices: [Int]        // additional lanes carrying the same commit id (branch joins)
    }
    @Published private(set) var laneInfoById: [String: LaneInfo] = [:]
    @Published private(set) var maxLaneCount: Int = 1

    // Pagination & Incremental Layout State
    @Published var hasMoreCommits: Bool = true
    @Published var isLoadingMore: Bool = false
    private var skip: Int = 0
    private let pageSize: Int = 25  // Reduced from 50 for faster initial render
    private var currentLanesState: [String?] = []

    // Pre-computed row data for performance
    struct CommitRowData: Identifiable, Equatable {
        let id: String
        let commit: GitService.GraphCommit
        let index: Int
        let laneInfo: LaneInfo?
        let isFirst: Bool
        let isLast: Bool
        let isWorkingTree: Bool
        let isStriped: Bool

        static func == (lhs: CommitRowData, rhs: CommitRowData) -> Bool {
            lhs.id == rhs.id &&
            lhs.index == rhs.index &&
            lhs.laneInfo == rhs.laneInfo &&
            lhs.isFirst == rhs.isFirst &&
            lhs.isLast == rhs.isLast &&
            lhs.isStriped == rhs.isStriped
        }
    }
    @Published private(set) var rowData: [CommitRowData] = []

    private let service = GitService()
    private var repo: GitService.Repo? = nil
    private var laneLayoutTask: Task<Void, Never>? = nil
    private var laneLayoutGeneration: Int = 0
    private var refreshTask: Task<Void, Never>? = nil
    private var detailTask: Task<Void, Never>? = nil
    private var historyActionTask: Task<Void, Never>? = nil

    // Branch scope controls
    @Published var showAllBranches: Bool = true
    @Published var showRemoteBranches: Bool = true
    // limit is replaced by pagination logic
    @Published var branches: [String] = []
    @Published var selectedBranch: String? = nil   // nil = current HEAD when showAllBranches == false
    @Published private(set) var workingChangesCount: Int = 0
    @Published var branchSearchQuery: String = ""
    @Published var isLoadingBranches: Bool = false
    @Published private(set) var fullBranchList: [String] = []  // Cache full list
    private var branchesTask: Task<Void, Never>? = nil

    // Detail panel state (files + per-file patch)
    @Published private(set) var detailFiles: [GitService.FileChange] = []
    @Published var selectedDetailFile: String? = nil
    @Published private(set) var detailFilePatch: String = ""
    @Published private(set) var isLoadingDetail: Bool = false
    @Published private(set) var detailMessage: String = ""
    enum HistoryAction: String {
        case fetch, pull, push

        var displayName: String {
            switch self {
            case .fetch: return "Fetch"
            case .pull: return "Pull"
            case .push: return "Push"
            }
        }
    }
    @Published private(set) var historyActionInProgress: HistoryAction? = nil

    deinit {
        laneLayoutTask?.cancel()
        refreshTask?.cancel()
        detailTask?.cancel()
        historyActionTask?.cancel()
        branchesTask?.cancel()
    }

    func attach(to root: URL?) {
        guard let root else { commits = []; filteredCommits = []; return }
        if SecurityScopedBookmarks.shared.isSandboxed {
            _ = SecurityScopedBookmarks.shared.startAccessDynamic(for: root)
        }
        self.repo = GitService.Repo(root: root)
        // Don't load branches immediately - will load on-demand when picker is opened
        reload()
    }

    func triggerRefresh() {
        reload()
    }

    func reload() {
        guard let _ = self.repo else { return }
        refreshTask?.cancel()
        laneLayoutTask?.cancel()
        
        // Reset state
        skip = 0
        hasMoreCommits = true
        currentLanesState = []
        commits = []
        filteredCommits = []
        laneInfoById = [:]
        maxLaneCount = 1
        rowData = []
        laneLayoutGeneration &+= 1
        
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await loadPage(isInitial: true)
        }
    }
    
    func loadMore() {
        guard !isLoading, !isLoadingMore, hasMoreCommits, let _ = self.repo else { return }
        isLoadingMore = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await loadPage(isInitial: false)
        }
    }

    private func loadPage(isInitial: Bool) async {
        guard let repo = self.repo else { return }
        
        await MainActor.run {
            if isInitial { isLoading = true }
        }
        
        let newCommits = await service.logGraphCommits(
            in: repo,
            limit: self.pageSize,
            skip: self.skip,
            includeAllBranches: self.showAllBranches,
            includeRemoteBranches: self.showRemoteBranches,
            singleRef: (self.showAllBranches ? nil : (self.selectedBranch?.isEmpty == false ? self.selectedBranch : nil))
        )
        
        // Working tree virtual entry (only on initial load)
        var finalList = newCommits
        if isInitial {
            let status = await service.status(in: repo)
            self.workingChangesCount = status.count
            if self.workingChangesCount > 0 {
                let headId = newCommits.first?.id
                let virtual = GitService.GraphCommit(
                    id: "::working-tree::",
                    shortId: "*",
                    author: "*",
                    date: "0 seconds ago",
                    subject: "Uncommitted Changes (\(status.count))",
                    parents: headId != nil ? [headId!] : [],
                    decorations: []
                )
                finalList = [virtual] + newCommits
            }
        }
        
        await MainActor.run {
            if isInitial {
                self.commits = finalList
                self.isLoading = false
                if self.selectedCommit == nil { self.selectedCommit = finalList.first }
            } else {
                // Append new commits
                self.commits.append(contentsOf: newCommits)
                self.isLoadingMore = false
            }
            
            if newCommits.count < self.pageSize {
                self.hasMoreCommits = false
            }
            self.skip += newCommits.count
            
            // Update filtered list so rows appear immediately
            self.applyFilter()
            
            // Trigger incremental layout
            self.computeIncrementalLayout(newCommits: isInitial ? finalList : newCommits, isInitial: isInitial)
        }
    }

    func applyFilter() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            filteredCommits = commits
            buildRowData()
            return
        }
        // Note: Filtering currently operates only on loaded commits. 
        // Ideally we would search the whole history, but for graph view,
        // we prioritized the loaded graph structure.
        let basic = commits.filter { c in
            if c.subject.lowercased().contains(q) { return true }
            if c.author.lowercased().contains(q) { return true }
            if c.shortId.lowercased().contains(q) { return true }
            if c.decorations.joined(separator: ",").lowercased().contains(q) { return true }
            return false
        }
        filteredCommits = basic
        buildRowData()
        // Optional: Trigger background grep if needed, but omitted here to keep graph stable
    }

    private func buildRowData() {
        let count = filteredCommits.count
        let newRowData = filteredCommits.enumerated().map { idx, commit in
            CommitRowData(
                id: commit.id,
                commit: commit,
                index: idx,
                laneInfo: laneInfoById[commit.id],
                isFirst: idx == 0,
                isLast: idx == count - 1,
                isWorkingTree: commit.id == "::working-tree::",
                isStriped: idx % 2 == 1
            )
        }
        
        // Only update if data actually changed to prevent unnecessary re-renders
        if newRowData != rowData {
            rowData = newRowData
        }
    }

    func selectCommit(_ c: GitService.GraphCommit) {
        selectedCommit = c
        loadDetail(for: c)
    }

    /// Load detail panel data (files list + first file patch) for the given commit.
    func loadDetail(for commit: GitService.GraphCommit) {
        // The synthetic working-tree node does not correspond to a real commit id.
        // For now, skip detail loading and leave the panel empty.
        if commit.id == "::working-tree::" {
            detailFiles = []
            selectedDetailFile = nil
            detailFilePatch = ""
            isLoadingDetail = false
            return
        }
        guard let repo = self.repo else {
            detailFiles = []
            selectedDetailFile = nil
            detailFilePatch = ""
            detailMessage = ""
            return
        }
        detailTask?.cancel()
        detailTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.isLoadingDetail = true
                self.detailFiles = []
                self.detailFilePatch = ""
                self.detailMessage = ""
            }
            async let filesTask = service.filesChanged(in: repo, commitId: commit.id)
            async let messageTask = service.commitMessage(in: repo, commitId: commit.id)
            let (files, message) = await (filesTask, messageTask)
            if Task.isCancelled { return }
            await MainActor.run {
                self.detailFiles = files
                self.selectedDetailFile = files.first?.path
                self.detailMessage = message
            }
            if let first = files.first {
                await loadDetailPatch(for: first.path, in: repo, commitId: commit.id)
            } else {
                await MainActor.run {
                    self.detailFilePatch = ""
                    self.isLoadingDetail = false
                }
            }
        }
    }

    func loadDetailPatch(for path: String) {
        guard let repo = self.repo, let commit = selectedCommit else { return }
        detailTask?.cancel()
        detailTask = Task { [weak self] in
            await self?.loadDetailPatch(for: path, in: repo, commitId: commit.id)
        }
    }

    private func loadDetailPatch(for path: String, in repo: GitService.Repo, commitId: String) async {
        await MainActor.run {
            self.isLoadingDetail = true
            self.detailFilePatch = ""
        }
        // Show diff of this file in the given commit against its first parent.
        let text = await service.filePatch(in: repo, commitId: commitId, path: path)
        if Task.isCancelled { return }
        await MainActor.run {
            self.detailFilePatch = text
            self.isLoadingDetail = false
        }
    }
    
    private struct LaneLayoutResult: Sendable {
        let byId: [String: LaneInfo]
        let maxLaneCount: Int
        let finalLanes: [String?]
    }

    // MARK: - Lanes
    private func computeIncrementalLayout(newCommits: [GitService.GraphCommit], isInitial: Bool) {
        let snapshot = newCommits
        let initialLanes = isInitial ? [] : currentLanesState
        let initialMax = isInitial ? 1 : maxLaneCount
        let generation = laneLayoutGeneration
        
        laneLayoutTask = Task.detached(priority: .userInitiated) {
            guard let result = Self.computeLaneLayout(
                for: snapshot, 
                initialLanes: initialLanes, 
                initialMaxLane: initialMax
            ) else { return }
            
            if Task.isCancelled { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.laneLayoutGeneration == generation else { return }
                if isInitial {
                    self.laneInfoById = result.byId
                } else {
                    self.laneInfoById.merge(result.byId) { (_, new) in new }
                }
                self.maxLaneCount = result.maxLaneCount
                self.currentLanesState = result.finalLanes
                self.buildRowData()
            }
        }
    }

    nonisolated private static func computeLaneLayout(
        for commits: [GitService.GraphCommit],
        initialLanes: [String?] = [],
        initialMaxLane: Int = 1
    ) -> LaneLayoutResult? {
        guard !commits.isEmpty else {
            return LaneLayoutResult(byId: [:], maxLaneCount: initialMaxLane, finalLanes: initialLanes)
        }

        var lanes: [String?] = initialLanes
        var byId: [String: LaneInfo] = [:]
        var maxLanes = initialMaxLane
        var processed = 0

        for commit in commits {
            if processed & 0x1F == 0, Task.isCancelled {
                return nil
            }
            processed &+= 1

            let before = lanes 

            // Determine current lane for this commit
            let laneIndex: Int
            if let idx = lanes.firstIndex(where: { $0 == commit.id }) {
                laneIndex = idx
            } else if let empty = lanes.firstIndex(where: { $0 == nil }) {
                laneIndex = empty
                if empty >= lanes.count { lanes.append(nil) }
            } else {
                laneIndex = lanes.count
                lanes.append(nil)
            }

            var parentLaneIndices: [Int] = []
            if let firstParent = commit.parents.first {
                if laneIndex < lanes.count { lanes[laneIndex] = firstParent } else {
                    lanes.append(firstParent)
                }
                parentLaneIndices.append(laneIndex)
                
                if commit.parents.count > 1 {
                    for p in commit.parents.dropFirst() {
                        if let existing = lanes.firstIndex(where: { $0 == p }) {
                            parentLaneIndices.append(existing)
                        } else if let empty = lanes.firstIndex(where: { $0 == nil }) {
                            lanes[empty] = p
                            parentLaneIndices.append(empty)
                        } else {
                            lanes.append(p)
                            parentLaneIndices.append(lanes.count - 1)
                        }
                    }
                }
            } else {
                if laneIndex < lanes.count { lanes[laneIndex] = nil }
            }

            let joinLanes: [Int] = before.enumerated().compactMap { index, value in
                (value == commit.id && index != laneIndex) ? index : nil
            }
            if !joinLanes.isEmpty {
                for j in joinLanes where j < lanes.count {
                    lanes[j] = nil
                }
            }

            while let last = lanes.last, last == nil { _ = lanes.popLast() }

            let after = lanes
            let activeCount = max(before.count, after.count)
            var continuing: Set<Int> = []
            if activeCount > 0 {
                for i in 0..<activeCount {
                    let hasBefore = i < before.count ? (before[i] != nil || i == laneIndex) : false
                    let hasAfter = i < after.count ? (after[i] != nil) : false
                    if hasBefore || hasAfter { continuing.insert(i) }
                }
            }

            byId[commit.id] = LaneInfo(
                laneIndex: laneIndex,
                parentLaneIndices: parentLaneIndices,
                activeLaneCount: activeCount,
                continuingLanes: continuing,
                joinLaneIndices: joinLanes
            )
            
            let rowMax = (parentLaneIndices + joinLanes + [laneIndex]).max() ?? 0
            maxLanes = max(maxLanes, rowMax + 1)
        }

        return LaneLayoutResult(byId: byId, maxLaneCount: max(1, maxLanes), finalLanes: lanes)
    }

    func loadBranches() {
        guard let repo else { branches = []; fullBranchList = []; return }
        branchesTask?.cancel()
        isLoadingBranches = true
        branchesTask = Task { [weak self] in
            guard let self else { return }
            let names = await service.listBranches(in: repo, includeRemoteBranches: showRemoteBranches)
            if Task.isCancelled { return }
            await MainActor.run {
                self.fullBranchList = names
                self.applyBranchFilter()
                self.isLoadingBranches = false
                self.branchesTask = nil
            }
        }
    }

    func applyBranchFilter() {
        let query = branchSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            // Limit to first 100 branches for performance
            branches = Array(fullBranchList.prefix(100))
        } else {
            // Filter and limit
            branches = Array(fullBranchList.filter { $0.lowercased().contains(query) }.prefix(100))
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func loadCommits() {
        reload()
    }

    func fetchRemotes() {
        performHistoryAction(.fetch)
    }

    func pullLatest() {
        performHistoryAction(.pull)
    }

    func pushCurrent() {
        performHistoryAction(.push)
    }

    private func performHistoryAction(_ action: HistoryAction) {
        guard historyActionInProgress == nil else { return }
        guard let repo = self.repo else { return }
        historyActionTask?.cancel()
        historyActionTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run { self.historyActionInProgress = action }
            let code: Int32
            switch action {
            case .fetch:
                code = await service.fetchAllRemotes(in: repo)
            case .pull:
                code = await service.pullCurrentBranch(in: repo)
            case .push:
                code = await service.pushCurrentBranch(in: repo)
            }
            if Task.isCancelled {
                await MainActor.run {
                    self.historyActionInProgress = nil
                    self.historyActionTask = nil
                }
                return
            }
            let failureDetail = (code == 0) ? nil : await self.service.takeLastFailureDescription()
            await MainActor.run {
                self.historyActionInProgress = nil
                self.historyActionTask = nil
                if code == 0 {
                    self.errorMessage = nil
                    self.reload()
                } else {
                    if let detail = failureDetail, !detail.isEmpty {
                        self.errorMessage = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        self.errorMessage = "\(action.displayName) failed (exit code \(code))"
                    }
                }
            }
        }
    }
}

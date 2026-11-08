import Combine
import ClipCore
import Foundation

@MainActor
final class HistorySearchModel: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var isSearching = false
    @Published private(set) var presentationRevision: UInt64 = 0
    private var source: [ClipboardEntry] = []
    private var query = ""
    private var filter: ClipboardHistoryFilter = .all
    private let worker: HistorySearchWorker
    private var request: SearchRequest?

    init(index: ClipboardSearchIndex = ClipboardSearchIndex(),
         queue: DispatchQueue = DispatchQueue(label: "com.clip32.search", qos: .userInitiated)) {
        worker = HistorySearchWorker(index: index, queue: queue)
    }

    deinit { request?.cancel() }

    func replaceEntries(_ source: [ClipboardEntry]) {
        self.source = source
        presentationRevision &+= 1
        refresh()
    }

    func setQuery(_ query: String) {
        guard self.query != query else { return }
        self.query = query
        refresh()
    }

    func setFilter(_ filter: ClipboardHistoryFilter) {
        guard self.filter != filter else { return }
        self.filter = filter
        refresh()
    }

    func presentation(for entry: ClipboardEntry) async -> ClipboardPresentation? {
        guard source.contains(where: { $0.id == entry.id && $0.items == entry.items }) else { return nil }
        let request = SearchRequest()
        let revision = presentationRevision
        let value = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                worker.present(id: entry.id, revision: revision, request: request) { continuation.resume(returning: $0) }
            }
        }, onCancel: { request.cancel() })
        return presentationRevision == revision ? value : nil
    }

    private func refresh() {
        request?.cancel()
        let request = SearchRequest()
        self.request = request
        if query.isEmpty {
            entries = source.filter(filter.includes)
            isSearching = false
        } else {
            // Stale results must not remain actionable while a query is running.
            entries = []
            isSearching = true
        }
        worker.submit(source: source, revision: presentationRevision, query: query, filter: filter, request: request) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.request === request, !request.isCancelled else { return }
                self.entries = result
                self.isSearching = false
            }
        }
    }
}

/// One executing search and one replaceable pending request bound retained
/// snapshots even if the user types faster than a large RTF can be imported.
private final class HistorySearchWorker: @unchecked Sendable {
    private struct Work {
        let source: [ClipboardEntry]
        let revision: UInt64
        let query: String
        let filter: ClipboardHistoryFilter
        let request: SearchRequest
        let complete: ([ClipboardEntry]) -> Void
    }

    private struct PresentationWaiter {
        let request: SearchRequest
        let complete: (ClipboardPresentation?) -> Void
    }

    private struct PresentationWork {
        let id: UUID
        let revision: UInt64
        let order: UInt64
        var waiters: [ObjectIdentifier: PresentationWaiter]
    }

    private let queue: DispatchQueue
    private let index: ClipboardSearchIndex
    private let presentations = ClipboardPresentationCache()
    private var source: [UUID: ClipboardEntry] = [:]
    private var sourceRevision: UInt64 = 0
    private let lock = NSLock()
    private var pending: Work?
    private var pendingPresentations: [UUID: PresentationWork] = [:]
    private var presentationOrder: UInt64 = 0
    private var scheduled = false

    init(index: ClipboardSearchIndex, queue: DispatchQueue) {
        self.index = index
        self.queue = queue
    }

    func submit(source: [ClipboardEntry], revision: UInt64, query: String, filter: ClipboardHistoryFilter,
                request: SearchRequest, complete: @escaping ([ClipboardEntry]) -> Void) {
        lock.lock()
        pending = Work(source: source, revision: revision, query: query, filter: filter, request: request, complete: complete)
        let removed = pendingPresentations.values.filter { $0.revision != revision }
        for work in removed { pendingPresentations.removeValue(forKey: work.id) }
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        for work in removed { completePresentation(work, value: nil) }
        if needsSchedule { queue.async { self.drain() } }
    }

    func present(id: UUID, revision: UInt64, request: SearchRequest,
                 complete: @escaping (ClipboardPresentation?) -> Void) {
        let identifier = ObjectIdentifier(request)
        request.whenCancelled { [weak self] in self?.cancelPresentation(id: id, identifier: identifier) }
        lock.lock()
        guard !request.isCancelled else { lock.unlock(); complete(nil); return }
        var removed: [PresentationWork] = []
        if let previous = pendingPresentations[id], previous.revision != revision {
            removed.append(previous)
            pendingPresentations.removeValue(forKey: id)
        }
        if pendingPresentations[id] == nil {
            if pendingPresentations.count >= 256,
               let oldest = pendingPresentations.values.min(by: { $0.order < $1.order }) {
                removed.append(oldest)
                pendingPresentations.removeValue(forKey: oldest.id)
            }
            presentationOrder &+= 1
            pendingPresentations[id] = PresentationWork(id: id, revision: revision, order: presentationOrder, waiters: [:])
        }
        pendingPresentations[id]?.waiters[identifier] = PresentationWaiter(request: request, complete: complete)
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        for work in removed { completePresentation(work, value: nil) }
        if needsSchedule { queue.async { self.drain() } }
    }

    private func cancelPresentation(id: UUID, identifier: ObjectIdentifier) {
        lock.lock()
        let removed = pendingPresentations[id]?.waiters.removeValue(forKey: identifier)
        if pendingPresentations[id]?.waiters.isEmpty == true { pendingPresentations.removeValue(forKey: id) }
        lock.unlock()
        removed?.complete(nil)
    }

    private func completePresentation(_ work: PresentationWork, value: ClipboardPresentation?) {
        for waiter in work.waiters.values { waiter.complete(waiter.request.isCancelled ? nil : value) }
    }

    private func drain() {
        while true {
            lock.lock()
            let work = pending
            pending = nil
            let presentation = work == nil ? pendingPresentations.values.min(by: { $0.order < $1.order }) : nil
            if let presentation { pendingPresentations.removeValue(forKey: presentation.id) }
            guard work != nil || presentation != nil else {
                scheduled = false
                lock.unlock()
                return
            }
            lock.unlock()
            if let work {
                guard !work.request.isCancelled else { continue }
                source = Dictionary(work.source.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                sourceRevision = work.revision
                presentations.synchronize(with: work.source)
                if let result = index.search(work.source, query: work.query, filter: work.filter,
                                             isCancelled: { work.request.isCancelled }) {
                    work.complete(result)
                }
            } else if let presentation {
                guard presentation.revision == sourceRevision, let entry = source[presentation.id],
                      presentation.waiters.values.contains(where: { !$0.request.isCancelled }) else {
                    completePresentation(presentation, value: nil)
                    continue
                }
                let value = autoreleasepool { presentations.presentation(for: entry) }
                completePresentation(presentation, value: value)
            }
        }
    }
}

/// Only cancellation crosses queues; caches stay on the serial worker queue.
private final class SearchRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellationHandler: (() -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let handler = cancellationHandler
        cancellationHandler = nil
        lock.unlock()
        handler?()
    }

    func whenCancelled(_ handler: @escaping () -> Void) {
        lock.lock()
        let invoke = cancelled
        if !cancelled { cancellationHandler = handler }
        lock.unlock()
        if invoke { handler() }
    }
}

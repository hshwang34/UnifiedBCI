import Foundation

/// Projects, recordings, evaluation, results, protocols, models, replay and export.
extension ControlRouter {
    static func record(_ value: some Encodable) -> JSON {
        (try? JSON(encoding: value, encoder: ContractJSON.encoder())) ?? .null
    }

    // MARK: Operator

    func operatorRequest(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        let message = try c.require("message")
        c.job?.awaitOperator(message)
        let yes = await AgentActivity.shared.ask(message, project: s.url)
        c.job?.operatorDone()
        try Task.checkCancellation()
        return ["confirmed": .bool(yes)]
    }

    // MARK: Projects

    func projectCreate(_ c: ControlCall) async throws -> JSON {
        let url = URL(fileURLWithPath: try c.require("path"))
        let name = c.string("name") ?? url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "bciproj" else { throw ControlError(.badRequest, "a project path ends in .bciproj") }
        do {
            let store = try await Task.detached(priority: .userInitiated) { try ProjectStore.create(at: url, name: name) }.value
            let s = await workspace.adopt(store)
            workspace.noteRecent(s.url)
            workspace.show(s.url)
            c.createdProject = s.url
            return await projectSummary(s)
        } catch ProjectStoreError.alreadyExists {
            throw ControlError(.refused, "\(url.path) already exists; a project is never created over a file.")
        }
    }

    func projectImportExample(_ c: ControlCall) async throws -> JSON {
        let url = URL(fileURLWithPath: try c.require("path"))
        guard url.pathExtension == "bciproj" else { throw ControlError(.badRequest, "a project path ends in .bciproj") }
        guard let source = BundledExample.locate(in: .main) else { throw ControlError(.failed, "The bundled example is missing from this copy of the app.") }
        do {
            let store = try await Task.detached(priority: .userInitiated) { try ProjectStore.importBundledExample(from: source, into: url) }.value
            let s = await workspace.adopt(store)
            workspace.noteRecent(s.url)
            workspace.show(s.url)
            c.createdProject = s.url
            return await projectSummary(s)
        } catch ProjectStoreError.alreadyExists {
            throw ControlError(.refused, "\(url.path) already exists; the example is never copied over a file.")
        }
    }

    func projectClose(_ c: ControlCall) async throws -> JSON {
        guard let url = c.projectURL, let s = workspace.sessions[url] else { return ["closed": false, "reason": "not open"] }
        if let ask = Workspace.closeConfirmation(s) { throw ControlError(.refused, ask.message, data: ["reason": .string(ask.info)]) }
        if s.runs.map({ !$0.isFinished }) ?? false || s.isLiveRunning { throw ControlError(.refused, "A run is in progress in \(s.name).") }
        await workspace.closeWindow(of: url)
        return ["closed": true]
    }

    func projectSummary(_ s: ProjectSession) async -> JSON {
        await s.frozen.awaitLoads()
        let protocols = (try? await s.store.protocols().protocols.count) ?? 0
        return .object([
            "path": .string(s.url.path), "name": .string(s.name),
            "recordings": .array(s.recordings.map { recordingRow(s, $0) }),
            "results": .int(Int64(s.results.count)),
            "protocols": .int(Int64(protocols)),
            "models": .int(Int64(s.frozen.models.count)),
            "liveRuns": .int(Int64(s.frozen.liveRuns.count)),
            "evaluating": .bool(s.isRunning),
            "acquisition": acquisitionState(s),
            "loadError": .from(s.loadError),
        ])
    }

    // MARK: Recordings

    func recordingRow(_ s: ProjectSession, _ h: RecordingHandle) -> JSON {
        let m = h.manifest
        let samples = m.chunks.reduce(0) { $0 + $1.sampleCount }
        let rate = m.timing.nominalSampleRateHz
        let events = s.eventsByRecording[h.id] ?? []
        return .object([
            "recordingID": .string(h.id.uuidString), "createdAt": .from(m.createdAt),
            "source": .string(m.source.kind), "boardName": .string(m.source.boardName), "dataset": .from(m.source.dataset),
            "channels": .int(Int64(m.channels.count)), "sampleRateHz": .double(rate),
            "durationS": .double(rate > 0 ? Double(samples) / rate : 0), "segments": .int(Int64(m.segments.count)),
            "montage": .string(m.montage), "evaluableRuns": .int(Int64(RunCountModel.evaluableRuns(events))),
            "minimumRunsToEvaluate": .int(Int64(RunCountModel.minimumRuns)),
            "protocol": .from(s.recordingProtocols[h.id]?.protocolID),
        ])
    }

    func recordingHandle(_ s: ProjectSession, _ c: ControlCall) throws -> RecordingHandle {
        let id = try c.uuid("recording")
        guard let h = s.recordings.first(where: { $0.id == id }) else { throw ControlError(.notFound, "no recording \(id) in \(s.name)") }
        return h
    }

    func recordingsList(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        await s.reload()
        return ["recordings": .array(s.recordings.map { recordingRow(s, $0) })]
    }

    func recordingsShow(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        let h = try recordingHandle(s, c)
        let events = s.eventsByRecording[h.id] ?? []
        let labels = Dictionary(grouping: events, by: \.label).mapValues { JSON.int(Int64($0.count)) }
        let plans = (try? await s.store.runPlans(recording: h.id).plans) ?? []
        return .object(["summary": recordingRow(s, h), "manifest": Self.record(h.manifest),
                        "eventCounts": .object(labels), "runPlans": .array(plans.map(Self.record))])
    }

    func recordingsVerify(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        let h = try recordingHandle(s, c)
        let issues = try await s.store.verify(recording: h.id)
        return ["recordingID": .string(h.id.uuidString), "ok": .bool(issues.isEmpty), "issues": .array(issues.map { .string($0.description) })]
    }

    func recordingsInspect(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        let h = try recordingHandle(s, c)
        if s.inspector.report(for: h.id) == nil {
            try requireIdleUI(s)
            s.showRecording(h.id)
            s.recordingTab = .quality              // the Quality tab starts the inspection on first show
            s.inspect()
            c.job?.onCancel = { s.cancelInspection() }
            while s.inspector.isBusy {
                if case .running(_, let p) = s.inspector.state { c.progress(["stage": .string("\(p)")]) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        if let report = s.inspector.report(for: h.id) { return Self.quality(report, recording: h.id) }
        switch s.inspector.state {
        case .analysisUnavailable(let d): throw ControlError(.failed, "Analysis unavailable: \(d)")
        case .failed(let d): throw ControlError(.failed, d)
        case .cancelled: throw ControlError(.cancelled, "Inspection cancelled.")
        default: throw ControlError(.failed, "The inspection did not finish.")
        }
    }

    /// The inspection as an agent needs it: every flagged or unassessable check by channel.
    static func quality(_ r: InspectionReport, recording: UUID) -> JSON {
        var flaggedChannels = 0
        let segments: [JSON] = r.segments.map { seg in
            .object([
                "index": .int(Int64(seg.index)), "runID": .string(seg.runId), "durationS": .double(seg.durationS),
                "channels": .array(seg.channels.map { ch in
                    let flagged = ch.checks.filter(\.flagged).map { JSON.string($0.rule) }
                    if !flagged.isEmpty { flaggedChannels += 1 }
                    return .object([
                        "id": .string(ch.id), "label": .string(ch.label), "flagged": .array(flagged),
                        "unassessable": .array(ch.checks.filter { !$0.assessable }.map { ["rule": .string($0.rule), "reason": .from($0.reason)] }),
                        "peakHz": .from(ch.peakHz),
                    ])
                }),
            ])
        }
        return .object([
            "recordingID": .string(recording.uuidString),
            "rules": .array(r.rules.map { ["id": .string($0.id), "title": .string($0.title), "flagWhen": .string($0.flagWhen)] }),
            "flaggedChannelSegments": .int(Int64(flaggedChannels)),
            "segments": .array(segments),
            // Decision #24: flags never exclude data on their own.
            "note": "Quality flags never exclude data; decide what to do with flagged channels and say so.",
        ])
    }

    // MARK: Evaluation

    func evaluateDefaults(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        await s.awaitDefaults()
        switch s.defaults {
        case .loaded(let d):
            return .object([
                "seed": .int(Int64(d.params.seed)), "windowOffsetS": .double(d.params.window.offset_s),
                "windowLengthS": .double(d.params.window.length_s), "cspComponents": .int(Int64(d.params.csp_components)),
                "labels": ["left": .string(d.params.labels.left), "right": .string(d.params.labels.right)],
                "holdoutFraction": .double(d.params.holdout_fraction),
                "recipes": .array(d.recipes.map { ["id": .string($0.id), "role": .string($0.role), "name": .string($0.name), "steps": .array($0.steps.map(JSON.string))] }),
            ])
        case .unavailable(let why): throw ControlError(.failed, "Analysis unavailable: \(why)")
        case .loading: throw ControlError(.failed, "The worker is still starting; try again.")
        }
    }

    func evaluateRun(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        try requireIdleUI(s)
        let h = try recordingHandle(s, c)
        s.showRecording(h.id)
        // Exactly the agent's parameters (the inspector shows them); unset ones are the worker's defaults.
        s.parameters = .init(seed: c.int("seed"), cspComponents: c.int("cspComponents"),
                             windowOffsetSeconds: c.double("windowOffsetS"), windowLengthSeconds: c.double("windowLengthS"))
        if let reason = s.evaluateDisabledReason { throw ControlError(.refused, reason, data: ["reason": .string(reason)]) }
        c.job?.onCancel = { s.cancel() }
        c.progress(["stage": "Starting", "detail": .string("Evaluating \(h.id.uuidString)"), "fraction": 0])
        let watch = Task { @MainActor in
            var last = ""
            while !Task.isCancelled {
                if let p = s.progress, p.detail != last {
                    last = p.detail
                    c.progress(["stage": .string(p.stage), "detail": .string(p.detail), "fraction": .double(p.fraction)])
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let state = await s.evaluateAndWait()
        watch.cancel()
        switch state {
        case .done(let id): return try await resultPayload(s, id, byAgent: true)
        case .cancelled: throw ControlError(.cancelled, "Cancelled — nothing saved.")
        case .analysisUnavailable(let why): throw ControlError(.failed, "Analysis unavailable: \(why). The recording is unchanged.")
        case .failed(let why): throw ControlError(.failed, "Evaluation failed: \(why). Nothing was saved.")
        default: throw ControlError(.refused, s.evaluateDisabledReason ?? "Evaluate didn't start.")
        }
    }

    func resultPayload(_ s: ProjectSession, _ id: UUID, byAgent: Bool = false) async throws -> JSON {
        let stored: StoredResult
        do { stored = try await s.store.result(id: id) } catch { throw ControlError(.notFound, "no result \(id): \(error)") }
        let evaluation = (try? JSON.parse(stored.evaluationJSON)) ?? .null
        var o: [String: JSON] = [
            "resultID": .string(id.uuidString), "recordingID": .string(stored.meta.recordingID.uuidString),
            "meta": Self.record(stored.meta), "pipeline": Self.record(stored.pipeline), "evaluation": evaluation,
            "accounting": accounting(s, recording: stored.meta.recordingID, evaluation: evaluation, agentResult: byAgent ? id : nil),
        ]
        if let model = try? ResultDetailModel(stored: stored, allResults: s.results, modelName: s.modelName) {
            o["headline"] = .object(["balancedAccuracy": .string(model.headline.balancedAccuracy), "accuracy": .string(model.headline.accuracy)])
        }
        if let r = stored.meta.reproductionOf { o["reproductionOf"] = .string(r.uuidString) }
        if let r = stored.meta.divergedFrom { o["divergedFrom"] = .string(r.uuidString) }
        return .object(o)
    }

    /// Decision #50: how many attempts this recording has had, so a best-of-many score
    /// can't pass for a single result.
    func accounting(_ s: ProjectSession, recording: UUID, evaluation: JSON, agentResult: UUID? = nil) -> JSON {
        let mine = s.results.filter { $0.recordingID == recording }
        let configs = Set(mine.map { "\($0.configHash)/\($0.seed)" })
        let seeds = Set(mine.map(\.seed))
        // The call answering now is logged only after it returns, so it is counted here.
        var agent = AgentActionLog.agentResultIDs(project: s.url)
        if let agentResult { agent.insert(agentResult.uuidString.uppercased()) }
        var warnings: [JSON] = []
        if configs.count > 5 { warnings.append("multiple_comparisons") }
        if seeds.count > 1 { warnings.append("several_seeds") }
        return .object([
            "evaluationsOnRecording": .int(Int64(mine.count)),
            "distinctConfigurations": .int(Int64(configs.count)),
            "distinctSeeds": .int(Int64(seeds.count)),
            "reproductions": .int(Int64(mine.filter { $0.reproductionOf != nil }.count)),
            "agentInitiated": .int(Int64(mine.filter { agent.contains($0.resultID.uuidString.uppercased()) }.count)),
            "heldOutRuns": evaluation["split_manifest"]?["holdout_runs"] ?? .null,
            "heldOutFixedBeforeFitting": true,
            "warnings": .array(warnings),
            "note": "Each seed picks a different held-out split. Report every configuration tried, not only the best; choosing by held-out score inflates it.",
        ])
    }

    func resultsList(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        let only = try c.string("recording").map { _ in try c.uuid("recording") }
        let metas = s.results.filter { only == nil || $0.recordingID == only }
        return ["results": .array(metas.map(Self.record))]
    }

    func resultsShow(_ c: ControlCall) async throws -> JSON {
        try await resultPayload(try await c.session(), try c.uuid("result"))
    }

    func exportResult(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        let id = try c.uuid("result")
        let destination = URL(fileURLWithPath: try c.require("destination"))
        do {
            let summary = try await s.store.export(result: id, to: destination)
            return .object(["path": .string(destination.path), "leftOutRunPlans": .int(Int64(summary.leftOutRunPlans)),
                            "unverifiedModels": .int(Int64(summary.unverifiedModels)), "unverifiedLiveRuns": .int(Int64(summary.unverifiedLiveRuns)),
                            "leftOut": .from(ExportNoticeText.leftOut(summary)), "added": .from(ExportNoticeText.added(summary))])
        } catch ProjectStoreError.alreadyExists {
            throw ControlError(.refused, "\(destination.lastPathComponent) already exists. Export never overwrites; choose a new name.")
        }
    }

    // MARK: Protocols

    func protocolsList(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        _ = try? await s.store.ensureDefaultProtocol()
        let list = try await s.store.protocols()
        let usage = (try? await s.store.protocolUsage()) ?? [:]
        return .object([
            "protocols": .array(list.protocols.map { p in
                var o = Self.record(p).objectValue ?? [:]
                o["recordingsUsing"] = .int(Int64(usage[p.protocolID] ?? 0))
                o["mislinked"] = .bool(list.mislinked.contains(p.protocolID))
                return .object(o)
            }),
            "unreadable": .int(Int64(list.unreadable)),
        ])
    }

    func protocolsCreate(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        let draft: ProtocolDraft
        do { draft = try (c.params["draft"] ?? .null).decode(ProtocolDraft.self, decoder: ContractJSON.decoder()) } catch {
            throw ControlError(.badRequest, "draft is not a ProtocolDraft: \(error)")
        }
        let list = try await s.store.protocols()
        var base: ProtocolRecord?
        if c.string("basedOn") != nil {
            let id = try c.uuid("basedOn")
            guard let b = list.protocols.first(where: { $0.protocolID == id }) else { throw ControlError(.notFound, "no protocol \(id)") }
            base = b
        }
        do {
            let record = try await s.store.createProtocolVersion(draft, basedOn: base)
            s.loadProtocols()
            await s.awaitProtocols()
            var o = Self.record(record).objectValue ?? [:]
            o["protocolID"] = .string(record.protocolID.uuidString)
            return .object(o)
        } catch {
            throw ControlError(.refused, ProtocolCopy.notSaved(error))
        }
    }

    // MARK: Models and replay

    func modelsList(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        await s.frozen.reload()
        return .object(["models": .array(s.frozen.models.map(Self.record)),
                        "liveRuns": .array(s.frozen.liveRuns.map(Self.record)),
                        "replays": .array(s.frozen.replays.map(Self.record))])
    }

    func modelsFreeze(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        try requireIdleUI(s)
        let id = try c.uuid("result")
        let stored: StoredResult
        do { stored = try await s.store.result(id: id) } catch { throw ControlError(.notFound, "no result \(id)") }
        s.showFreeze(stored)                         // the Freeze sheet opens, as for the person
        if let name = c.string("name") { s.frozen.freezeDraft?.name = name }
        if let raw = c.string("role") {
            guard let role = ModelRole(rawValue: raw) else { s.frozen.sheetClosed(); throw ControlError(.badRequest, "role is reference or baseline") }
            s.frozen.freezeDraft?.role = role
        }
        if let draft = s.frozen.freezeDraft, !draft.sheet.canFreeze {
            s.frozen.sheetClosed()
            throw ControlError(.refused, "This result can't be frozen (its window isn't recorded).")
        }
        guard let model = await s.freeze() else {
            let why = s.frozen.freezeDraft?.error ?? "The model wasn't frozen."
            s.frozen.sheetClosed()
            throw ControlError(.refused, why)
        }
        var o = Self.record(model).objectValue ?? [:]
        o["modelID"] = .string(model.modelID.uuidString)
        return .object(o)
    }

    func replayRun(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        try requireIdleUI(s)
        if s.isLiveRunning { throw ControlError(.refused, LiveRunCopy.pausedDuringLive) }
        let modelID = try c.uuid("model")
        let h = try recordingHandle(s, c)
        await s.frozen.awaitLoads()
        guard s.frozen.models.contains(where: { $0.modelID == modelID }) else { throw ControlError(.notFound, "no frozen model \(modelID)") }
        s.showReplay(model: modelID, recording: h.id)
        if let t = c.double("threshold") { s.frozen.replayDraft?.thresholdText = Fmt.fixed(t) }
        c.job?.onCancel = { s.frozen.runner.cancel() }
        let state = await s.replay()
        let why = s.frozen.replayDraft?.error
        s.frozen.sheetClosed()
        s.replaySheetClosed()
        switch state {
        case .done(let id)?:
            await s.frozen.reload()
            guard let run = s.frozen.replays.first(where: { $0.liveRunID == id }) else { return ["liveRunID": .string(id.uuidString)] }
            var o = Self.record(run).objectValue ?? [:]
            o["liveRunID"] = .string(id.uuidString)
            return .object(o)
        case .cancelled?: throw ControlError(.cancelled, "Replay cancelled.")
        case .refused(let code, let message)?: throw ControlError(.refused, ModelErrorText.describe(code: code, message: message))
        case .analysisUnavailable(let r)?: throw ControlError(.failed, "Analysis unavailable: \(r)")
        case .failed(let r)?: throw ControlError(.failed, r)
        default: throw ControlError(.refused, why ?? "Replay didn't start.")
        }
    }
}

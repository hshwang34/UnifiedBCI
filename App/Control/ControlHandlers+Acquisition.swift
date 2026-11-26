import Foundation

/// Sources, live acquisition, cued protocol runs and live tests (brief 008, decision #48).
/// Human steps stay with the person: a run starts only when the operator presses Space (or
/// Begin), except on the synthetic board and the Demo with `operator: "agent"`.
extension ControlRouter {
    // MARK: State

    static func describe(_ state: AcquisitionSession.State) -> (String, String?) {
        switch state {
        case .disconnected: return ("disconnected", nil)
        case .connecting: return ("connecting", nil)
        case .ready: return ("ready", nil)
        case .streaming: return ("streaming", nil)
        case .interrupted(let r): return ("interrupted", r)
        case .stopping: return ("stopping", nil)
        case .failed(let r): return ("failed", r)
        }
    }

    func acquisitionState(_ s: ProjectSession) -> JSON {
        guard let live = s.live, !live.isClosed else { return ["state": "disconnected"] }
        let (state, reason) = Self.describe(live.state)
        let snap = live.snapshot
        let gaps = snap.health.gaps.reduce(0) { $0 + $1.value.estimatedMissingSamples }
        var o: [String: JSON] = [
            "state": .string(state), "reason": .from(reason), "source": .from(live.source?.id),
            "simulated": .bool(Self.isSimulated(live)),
            "recordingID": .from(snap.recordingID), "lastRecordingID": .from(live.lastRecordingID),
            "recordDisabledReason": .from(live.recordDisabledReason),
            "map": .string({ switch live.choice { case .none: "none"; case .withoutPositions: "undeclared"; case .confirmed: "confirmed" } }()),
            "health": .object(["segment": .int(Int64(snap.health.segment)), "reconnects": .int(Int64(snap.health.reconnects)),
                               "effectiveRateHz": .from(snap.health.effectiveRateHz), "estimatedMissingSamples": .int(Int64(gaps)),
                               "arrivalPauses": .int(Int64(snap.health.arrivalPauses)), "hoursLeft": .from(snap.health.hoursLeft)]),
            "runActive": .bool(s.runs.map { !$0.isFinished } ?? false),
        ]
        if let b = snap.board {
            o["board"] = .object(["name": .string(b.name), "sampleRateHz": .int(Int64(b.samplingRate)), "eegChannels": .int(Int64(b.eegChannelRows.count)),
                                  "labels": .array(live.labels.map(JSON.string))])
        }
        if let m = live.recordMessage { o["message"] = .string(m.text) }
        return .object(o)
    }

    static func isSimulated(_ live: ConnectController) -> Bool {
        live.source == .synthetic || live.source == .demo
    }

    // MARK: Sources

    func sourcesList(_ c: ControlCall) async throws -> JSON {
        let ports = await Task.detached(priority: .userInitiated) { SerialPortScanner.scan() }.value
        let demo = AcquisitionSource.bundledDemo() != nil
        var rows: [JSON] = ports.map { p in
            ["id": .string(p.path), "kind": "serial", "name": .string(ConnectSource.serial(p).title), "available": true,
             "needsHardwarePermission": true]
        }
        rows.append(["id": "synthetic", "kind": "synthetic", "name": .string(ConnectSource.synthetic.title), "available": true, "needsHardwarePermission": false])
        rows.append(["id": "demo", "kind": "demo", "name": "Demo (bundled example EEG played back)", "available": .bool(demo), "needsHardwarePermission": false])
        return ["sources": .array(rows), "hardwareAllowed": .bool(settings.hardwareAllowed)]
    }

    // MARK: Connect

    func acquisitionConnect(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        if let live = s.live, !live.isClosed, live.state != .disconnected, !(live.state.isFailed) {
            throw ControlError(.refused, "\(s.name) is already connected (\(Self.describe(live.state).0)); disconnect first.",
                               data: ["acquisition": acquisitionState(s)])
        }
        try requireIdleUI(s)
        let id = try c.require("source")
        s.showConnectSheet()
        guard let model = s.live else { throw ControlError(.failed, "The Connect sheet didn't open.") }
        func giveUp(_ e: ControlError) async -> ControlError {
            await model.close()
            s.connectSheetClosed()
            return e
        }
        await model.refresh()
        guard let source = model.sources.first(where: { $0.id == id }) else {
            throw await giveUp(ControlError(.notFound, "no source \(id)", data: ["sources": .array(model.sources.map { .string($0.id) })]))
        }
        guard model.isAvailable(source) else { throw await giveUp(ControlError(.refused, "The Demo isn't available in this build.")) }
        if case .serial(let port) = source {
            guard settings.hardwareAllowed else {
                throw await giveUp(ControlError(.hardwareNotAllowed, "Agents may not use hardware. The person can allow it in Settings ▸ Agent Control."))
            }
            if !allowedPorts.contains(port.path) {
                guard await confirmHardware(port.path, s) else { throw await giveUp(ControlError(.hardwareNotAllowed, "The person didn't allow connecting \(port.path).")) }
                allowedPorts.insert(port.path)
            }
        }
        model.selectedID = id
        c.progress(["stage": "connecting"])
        await model.perform(.connect)
        guard model.state == .ready else {
            let (state, reason) = Self.describe(model.state)
            throw await giveUp(ControlError(.failed, "Connect ended \(state)\(reason.map { ": \($0)" } ?? "")."))
        }
        // Decision #31: the map is the agent's explicit choice, never a guess.
        let map = c.params["map"] ?? .null
        if map.stringValue == "declared" {
            guard model.declaredMap != nil else { throw await giveUp(ControlError(.refused, "This source declares no channel map; pass \"undeclared\" or labels.")) }
            model.confirmMap()
        } else if map.stringValue == "undeclared" {
            model.recordWithoutPositions()
        } else if let o = map.objectValue, let labels = o["labels"]?.arrayValue?.compactMap(\.stringValue) {
            guard labels.count == model.labels.count else {
                throw await giveUp(ControlError(.badRequest, "map.labels needs \(model.labels.count) labels, one per EEG channel, in board order."))
            }
            model.labels = labels
            if let m = o["montage"]?.stringValue { model.montage = m }
            if let r = o["reference"]?.stringValue { model.reference = r }
            model.confirmMap()
        } else {
            throw await giveUp(ControlError(.badRequest, "map is \"declared\", \"undeclared\" or {labels:[…]}"))
        }
        guard model.choice != .none else { throw await giveUp(ControlError(.refused, model.mapMessage ?? "The channel map wasn't accepted.")) }
        await model.perform(.startPreview)          // the sheet hands over to the acquisition screen
        let deadline = ContinuousClock.now + .seconds(10)
        while model.state != .streaming, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if s.showsConnectSheet { s.connectSheetClosed() }
        return acquisitionState(s)
    }

    func acquisitionStatus(_ s: ProjectSession) async throws -> JSON { acquisitionState(s) }

    /// The streaming board, checked for hardware permission: a serial board (even one the
    /// person connected) is used by an agent only with "Allow agents to use hardware" on and
    /// its port confirmed this launch (decision #48).
    private func streamingLive(_ s: ProjectSession) async throws -> ConnectController {
        guard let live = s.live, !live.isClosed, live.state == .streaming else {
            throw ControlError(.refused, RecordGate.notStreaming, data: ["reason": .string(RecordGate.notStreaming), "acquisition": acquisitionState(s)])
        }
        if case .serial(let port)? = live.source {
            guard settings.hardwareAllowed else {
                throw ControlError(.hardwareNotAllowed, "Agents may not use hardware. The person can allow it in Settings ▸ Agent Control.")
            }
            if !allowedPorts.contains(port.path) {
                guard await confirmHardware(port.path, s) else { throw ControlError(.hardwareNotAllowed, "The person didn't allow using \(port.path).") }
                allowedPorts.insert(port.path)
            }
        }
        return live
    }

    // MARK: Record

    func acquisitionRecord(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        let live = try await streamingLive(s)
        if s.runs.map({ !$0.isFinished }) ?? false { throw ControlError(.refused, StartRunCopy.alreadyRecording) }
        if let r = live.recordDisabledReason { throw ControlError(.refused, r, data: ["reason": .string(r)]) }
        await live.perform(.record)
        guard live.isRecordingNow else { throw ControlError(.refused, live.recordMessage?.text ?? "Recording didn't start.") }
        // The snapshot is polled every 200 ms; the new recording's id arrives with it.
        let named = ContinuousClock.now + .seconds(2)
        while live.snapshot.recordingID == nil, ContinuousClock.now < named { try? await Task.sleep(for: .milliseconds(50)) }
        let recording = live.snapshot.recordingID
        guard let seconds = c.double("seconds"), seconds > 0 else {
            return ["recordingID": .from(recording), "recording": true]
        }
        var cancelled = false
        c.job?.onCancel = { cancelled = true }
        let start = ContinuousClock.now
        while !cancelled, live.isRecordingNow, ContinuousClock.now - start < .seconds(seconds) {
            try? await Task.sleep(for: .milliseconds(250))
            let elapsed = (ContinuousClock.now - start) / .seconds(1)
            c.progress(["stage": "recording", "elapsedS": .double(elapsed), "seconds": .double(seconds)])
        }
        let endedItself = !live.isRecordingNow
        if live.isRecordingNow { await live.perform(.stopRecording) }
        await s.liveReload?.value
        let result: JSON = ["recordingID": .from(live.lastRecordingID ?? recording), "endedItself": .bool(endedItself),
                            "message": .from(live.recordMessage?.text)]
        if cancelled { throw ControlError(.cancelled, "Recording stopped early; it is kept.", data: result) }
        return result
    }

    func acquisitionStop(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        guard let live = s.live, live.isRecordingNow else { throw ControlError(.refused, "Nothing is recording in \(s.name).") }
        if s.runs.map({ !$0.isFinished }) ?? false { throw ControlError(.refused, "A protocol run owns this recording; cancel its job instead.") }
        await live.perform(.stopRecording)
        await s.liveReload?.value
        return ["recordingID": .from(live.lastRecordingID)]
    }

    func acquisitionDisconnect(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        if s.runs.map({ !$0.isFinished }) ?? false || s.isLiveRunning { throw ControlError(.refused, "A run is in progress; cancel its job first.") }
        guard s.live != nil else { return ["state": "disconnected"] }
        await s.endLive()
        return ["state": "disconnected"]
    }

    // MARK: Runs

    private func operatorMode(_ c: ControlCall, _ live: ConnectController) throws -> Bool {
        switch c.string("operator") ?? "human" {
        case "human": return false
        case "agent":
            guard Self.isSimulated(live) else {
                throw ControlError(.refused, "Unattended runs are allowed only on the synthetic board and the Demo; on hardware the operator starts each run.")
            }
            return true
        default: throw ControlError(.badRequest, "operator is \"human\" or \"agent\"")
        }
    }

    /// Before a session on a person: electrodes and participant, confirmed in the app.
    private func confirmReady(_ c: ControlCall, _ s: ProjectSession, what: String) async throws {
        let message = "An agent wants to start \(what). Are the electrodes checked and the participant ready?"
        c.job?.awaitOperator(message)
        let yes = await AgentActivity.shared.ask(message, project: s.url)
        c.job?.operatorDone()
        try Task.checkCancellation()
        guard yes else { throw ControlError(.refused, "The operator declined to start \(what).") }
    }

    func protocolRun(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        try requireIdleUI(s)
        let live = try await streamingLive(s)
        if let r = s.startRunDisabledReason { throw ControlError(.refused, r, data: ["reason": .string(r)]) }
        let agent = try operatorMode(c, live)
        let protocolID = try c.uuid("protocol")
        guard let p = try await s.store.protocols().protocols.first(where: { $0.protocolID == protocolID }) else {
            throw ControlError(.notFound, "no protocol \(protocolID)")
        }
        if !agent { try await confirmReady(c, s, what: "\(c.int("runs") ?? p.runsPerSession) runs of \"\(p.name)\"") }
        await s.showStartRun(operatorScreen: s.projectWindow?.screen)
        guard var form = s.startRunForm else { throw ControlError(.refused, s.startRunError ?? s.startRunDisabledReason ?? "Start run… didn't open.") }
        guard form.protocols.contains(where: { $0.protocolID == protocolID }) else {
            s.startRunForm = nil
            throw ControlError(.refused, "That protocol version can't be run (its lineage doesn't check out).")
        }
        form.pick(protocolID)
        if let seed = c.int("seed") { form.seedText = "\(seed)" }
        if let n = c.int("runs") { form.runsPerSession = n }
        s.startRuns(form)
        guard let runs = s.runs, !runs.isFinished, s.startRunForm == nil else {
            let why = s.startRunSheetError ?? "The runs didn't start."
            s.startRunForm = nil
            throw ControlError(.refused, why)
        }
        let summaries = try await drive(runs, c, s, agent: agent)
        await s.finishRuns()
        let result: JSON = ["recordingID": .from(s.live?.lastRecordingID), "sessionSeed": .int(Int64(bitPattern: runs.setup.sessionSeed)),
                            "protocolID": .string(protocolID.uuidString), "runs": .array(summaries.runs)]
        if summaries.cancelled { throw ControlError(.cancelled, "The runs were stopped; what was recorded is kept.", data: result) }
        return result
    }

    func liveTest(_ c: ControlCall) async throws -> JSON {
        let s = try await c.session()
        try requireIdleUI(s)
        let live = try await streamingLive(s)
        let agent = try operatorMode(c, live)
        let modelID = try c.uuid("model"), protocolID = try c.uuid("protocol")
        s.section = .liveTest
        s.selectedLiveRunID = nil
        s.liveRunForm = nil
        await s.prepareLiveSetup(operatorScreen: s.projectWindow?.screen)
        guard s.liveRunForm?.protocols.contains(where: { $0.protocolID == protocolID }) == true else { throw ControlError(.notFound, "no runnable protocol \(protocolID)") }
        s.liveRunForm?.pick(protocolID)
        if let seed = c.int("seed") { s.liveRunForm?.seedText = "\(seed)" }
        guard s.frozen.models.contains(where: { $0.modelID == modelID }) else { throw ControlError(.notFound, "no frozen model \(modelID)") }
        s.liveTestForm.modelID = modelID
        if let t = c.double("threshold") { s.liveTestForm.thresholdText = Fmt.fixed(t) }
        if let r = s.liveStartDisabledReason { throw ControlError(.refused, r, data: ["reason": .string(r)]) }
        if !agent { try await confirmReady(c, s, what: "a live run with feedback") }
        let previous = s.liveFeedback
        await s.startLiveFromSetup()
        guard let runs = s.runs, let feedback = s.liveFeedback, feedback !== previous else {
            throw ControlError(.refused, s.startRunSheetError ?? s.liveStartDisabledReason ?? "The live run didn't start.")
        }
        let summaries = try await drive(runs, c, s, agent: agent)
        c.progress(["stage": "replay check"])
        await s.finishRuns()
        await s.frozen.reload()
        var o: [String: JSON] = ["liveRunID": .string(feedback.liveRunID.uuidString), "runs": .array(summaries.runs),
                                 "recordingID": .from(s.live?.lastRecordingID), "finishProblem": .from(feedback.finishProblem),
                                 "checkProblem": .from(feedback.checkProblem)]
        if let run = s.frozen.liveRuns.first(where: { $0.liveRunID == feedback.liveRunID }) { o["liveRun"] = Self.record(run) }
        if summaries.cancelled { throw ControlError(.cancelled, "The live run was stopped; what was recorded is kept.", data: .object(o)) }
        return .object(o)
    }

    /// Runs every run of the session. With a human operator each run waits on its
    /// instructions screen for Space (or Begin); a pause waits for Resume in the app.
    private func drive(_ runs: RunController, _ c: ControlCall, _ s: ProjectSession, agent: Bool) async throws -> (runs: [JSON], cancelled: Bool) {
        let total = runs.setup.runsPerSession
        var cancelled = false
        c.job?.onCancel = { cancelled = true; runs.abortRun() }
        var out: [JSON] = []
        let activity = AgentActivity.shared
        for i in 0..<total {
            if i > 0 {
                guard runs.canStartNextRun else { break }
                runs.startNextRun()
            }
            while runs.status == nil, !cancelled { try? await Task.sleep(for: .milliseconds(50)) }
            var prompt: UUID?
            var asked: String?
            func waitFor(_ text: String) {
                guard asked != text else { return }
                activity.clear(prompt)
                asked = text
                prompt = activity.show(text, project: s.url)
                c.job?.awaitOperator(text)
            }
            func resumed() {
                activity.clear(prompt)
                prompt = nil
                asked = nil
                c.job?.operatorDone()
            }
            if agent {
                try? await Task.sleep(for: .seconds(1))
                runs.begin()
            }
            while runs.isRunActive, !cancelled {
                switch runs.status?.state {
                case .instructions?:
                    if !agent { waitFor("Run \(i + 1) of \(total): press Space in the participant window when the participant is ready.") }
                case .paused(let why)?:
                    waitFor("Run \(i + 1) is paused (\(why.rawValue)). Resume it in the operator panel when ready.")
                case .running?:
                    if asked != nil { resumed() }
                    if let st = runs.status {
                        c.progress(["stage": "run", "run": .int(Int64(i + 1)), "of": .int(Int64(total)),
                                    "trial": .from(st.trial.map { $0 + 1 }), "trials": .int(Int64(st.trialCount)), "phase": .string("\(st.phase)")])
                    }
                default: break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            resumed()
            await runs.awaitRun()
            let st = runs.status
            var row: [String: JSON] = ["runID": .from(st?.runID), "abortedTrials": .array((st?.abortedTrials ?? []).map(JSON.string))]
            switch st?.state {
            case .ended(let aborted)?: row["state"] = aborted ? "aborted" : "completed"
            case .failed(let why)?: row["state"] = "failed"; row["reason"] = .string(why)
            default: row["state"] = .string("\(String(describing: st?.state))")
            }
            out.append(.object(row))
            if cancelled { break }
            if case .failed(let why)? = st?.state {
                await s.finishRuns()
                throw ControlError(.failed, "Run \(i + 1) failed: \(why)", data: ["runs": .array(out)])
            }
        }
        return (out, cancelled)
    }
}

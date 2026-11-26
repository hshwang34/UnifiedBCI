import XCTest
@testable import BCIWorkspace

/// Brief 008: the shared control protocol, the catalogue, `bci` argument parsing and the
/// MCP mapping. None of these needs the app or a worker.
final class ControlProtocolTests: XCTestCase {
    // MARK: JSON

    func testJSONKeepsIntegersApartFromDoubles() throws {
        let j = try JSON.parse(#"{"a":1,"b":1.5,"c":"x","d":[true,null],"e":{"f":-3}}"#)
        XCTAssertEqual(j["a"], .int(1))
        XCTAssertEqual(j["b"], .double(1.5))
        XCTAssertEqual(j["d"], .array([.bool(true), .null]))
        XCTAssertEqual(j["e"]?["f"]?.intValue, -3)
        XCTAssertEqual(try JSON.parse(j.data()), j, "round trip")
        XCTAssertEqual(j.description, #"{"a":1,"b":1.5,"c":"x","d":[true,null],"e":{"f":-3}}"#, "sorted keys, compact")
    }

    func testJSONEncodesStoredRecordsWithContractDates() throws {
        let draft = ProtocolDraft.grazDefault
        let j = try JSON(encoding: draft, encoder: ContractJSON.encoder())
        XCTAssertEqual(j["trialsPerClass"]?.intValue, 20)
        XCTAssertEqual(try j.decode(ProtocolDraft.self, decoder: ContractJSON.decoder()), draft, "an agent can send back what it read")
    }

    // MARK: Framing

    func testLineBufferSplitsAcrossChunksAndRefusesLongLines() throws {
        var b = LineBuffer(maxLineBytes: 16)
        XCTAssertEqual(try b.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(try b.append(Data("1}\n\n{\"b\":2}\n{".utf8)).map { String(decoding: $0, as: UTF8.self) }, [#"{"a":1}"#, #"{"b":2}"#])
        XCTAssertFalse(b.isEmpty)
        XCTAssertThrowsError(try b.append(Data(String(repeating: "x", count: 40).utf8)))
    }

    func testMessagesRoundTripAsOneLine() throws {
        let m = ControlMessage.failure("7", ControlError(.refused, "no", data: ["reason": "Start the preview to record."]))
        let line = m.line()
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(ControlMessage.self, from: line.dropLast()), m)
    }

    func testExitCodesFollowErrorCodes() {
        XCTAssertEqual(ExitCode.for("refused"), .refused)
        XCTAssertEqual(ExitCode.for("ui_busy"), .refused)
        XCTAssertEqual(ExitCode.for("hardware_not_allowed"), .refused)
        XCTAssertEqual(ExitCode.for("bad_request"), .usage)
        XCTAssertEqual(ExitCode.for("protocol_mismatch"), .protocolMismatch)
        XCTAssertEqual(ExitCode.for("cancelled"), .cancelled)
        XCTAssertEqual(ExitCode.for("failed"), .failed)
        XCTAssertEqual(ExitCode.for("something new"), .failed)
    }

    // MARK: Catalogue

    func testCatalogueNamesAreUniqueAndToolSafe() {
        let names = ControlCatalog.methods.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        for m in ControlCatalog.methods {
            XCTAssertNotNil(m.toolName.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression), m.toolName)
            XCTAssertEqual(ControlCatalog.spec(group: m.commandWords.group, verb: m.commandWords.verb)?.name, m.name)
        }
        XCTAssertEqual(ControlCatalog.spec("acquisition.connect")?.hardware, true)
        XCTAssertEqual(ControlCatalog.spec("evaluate.run")?.kind, .job)
    }

    func testValidateRefusesUnknownMissingAndMistypedParameters() {
        let m = ControlCatalog.spec("evaluate.run")!
        XCTAssertNil(ControlCatalog.validate(m, ["project": "/p.bciproj", "recording": "x", "seed": 3]))
        XCTAssertEqual(ControlCatalog.validate(m, ["project": "/p.bciproj"])?.code, "bad_request")
        XCTAssertEqual(ControlCatalog.validate(m, ["project": "/p.bciproj", "recording": "x", "sed": 3])?.message, "evaluate.run has no parameter \"sed\"")
        XCTAssertNotNil(ControlCatalog.validate(m, ["project": "/p.bciproj", "recording": "x", "seed": "three"]))
    }

    // MARK: bci arguments

    func testParsesGroupVerbFlags() throws {
        let cmd = try BCICommand.parse(["evaluate", "run", "--project", "/x/a.bciproj", "--recording", "R", "--window-length-s", "2", "--seed", "4", "--async"], environment: [:])
        XCTAssertEqual(cmd, .call(method: "evaluate.run", params: ["project": "/x/a.bciproj", "recording": "R", "windowLengthS": 2.0, "seed": 4],
                                  async: true, noWait: false))
    }

    func testProjectComesFromEnvironmentAndPathsBecomeAbsolute() throws {
        let cmd = try BCICommand.parse(["recordings", "list"], environment: ["BCI_PROJECT": "/y/b.bciproj"])
        XCTAssertEqual(cmd, .call(method: "recordings.list", params: ["project": "/y/b.bciproj"], async: false, noWait: false))
        guard case .call(_, let p, _, _) = try BCICommand.parse(["project", "import-example", "--path", "rel.bciproj"], environment: [:]) else { return XCTFail() }
        XCTAssertTrue(p["path"]?.stringValue?.hasPrefix("/") ?? false)
    }

    func testMapTakesAWordOrJSON() throws {
        guard case .call(_, let a, _, _) = try BCICommand.parse(["acquisition", "connect", "--project", "/p.bciproj", "--source", "synthetic", "--map", "undeclared"], environment: [:]),
              case .call(_, let b, _, _) = try BCICommand.parse(["acquisition", "connect", "--project", "/p.bciproj", "--source", "demo", "--map", #"{"labels":["C3","C4"]}"#], environment: [:])
        else { return XCTFail() }
        XCTAssertEqual(a["map"], "undeclared")
        XCTAssertEqual(b["map"]?["labels"], ["C3", "C4"])
    }

    func testUsageErrors() {
        XCTAssertThrowsError(try BCICommand.parse(["evaluate", "run", "--project", "/p", "--bogus", "1"], environment: [:]))
        XCTAssertThrowsError(try BCICommand.parse(["evaluate", "fly"], environment: [:]))
        XCTAssertThrowsError(try BCICommand.parse(["nope"], environment: [:]))
        XCTAssertThrowsError(try BCICommand.parse(["evaluate", "run", "--project", "/p", "--recording", "r", "--seed", "x"], environment: [:]))
        XCTAssertEqual(try BCICommand.parse([], environment: [:]), .help(topic: nil))
        XCTAssertEqual(try BCICommand.parse(["call", "app.status"], environment: [:]), .call(method: "app.status", params: .object([:]), async: false, noWait: false))
    }

    // MARK: MCP

    func testMCPInitializeListAndCall() throws {
        var calls: [(String, JSON, Bool)] = []
        let mcp = MCPAdapter(call: { m, p, a in
            calls.append((m, p, a))
            switch m {
            case "evaluate.run": return ["job": "job-1", "state": "running"]
            case "jobs.wait": return ["job": "job-1", "state": "done", "result": ["resultID": "R1"]]
            default: return ["ok": true]
            }
        }, notify: { _ in })
        let ini = try XCTUnwrap(mcp.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]]))
        XCTAssertEqual(ini["result"]?["protocolVersion"], "2025-06-18")
        XCTAssertTrue(ini["result"]?["instructions"]?.stringValue?.contains("held-out") ?? false)
        XCTAssertNil(mcp.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]), "notifications get no answer")
        let list = try XCTUnwrap(mcp.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        XCTAssertEqual(list["result"]?["tools"]?.arrayValue?.count, ControlCatalog.methods.count)

        let read = try XCTUnwrap(mcp.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "bci_app_status", "arguments": [:]]]))
        XCTAssertEqual(read["result"]?["isError"], false)
        XCTAssertEqual(read["result"]?["structuredContent"]?["ok"], true)

        let job = try XCTUnwrap(mcp.handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                            "params": ["name": "bci_evaluate_run", "arguments": ["project": "/p.bciproj", "recording": "x"]]]))
        XCTAssertEqual(job["result"]?["structuredContent"]?["resultID"], "R1", "a job that finishes in time returns its result")
        XCTAssertEqual(calls.map(\.0), ["app.status", "evaluate.run", "jobs.wait"])
        XCTAssertTrue(calls[1].2, "job methods start async")

        let bad = try XCTUnwrap(mcp.handle(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "bci_evaluate_run", "arguments": [:]]]))
        XCTAssertEqual(bad["result"]?["isError"], true, "validation errors come back as tool errors")
        XCTAssertEqual(mcp.handle(["jsonrpc": "2.0", "id": 6, "method": "nope"])?["error"]?["code"], -32601)
    }

    func testMCPReturnsOperatorPromptsInsteadOfWaiting() throws {
        let mcp = MCPAdapter(call: { m, _, _ in
            m == "protocol.run" ? ["job": "job-2", "state": "running"] : ["job": "job-2", "state": "awaiting_operator", "prompt": "press Space"]
        }, notify: { _ in })
        let r = try XCTUnwrap(mcp.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                          "params": ["name": "bci_protocol_run", "arguments": ["project": "/p.bciproj", "protocol": "x"]]]))
        XCTAssertEqual(r["result"]?["structuredContent"]?["state"], "awaiting_operator")
        XCTAssertTrue(r["result"]?["structuredContent"]?["note"]?.stringValue?.contains("Tell your user") ?? false)
    }

    // MARK: Socket server

    func testServerRequiresSameUserTokenAndProtocol() async throws {
        let dir = URL(fileURLWithPath: "/tmp/bcict-\(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = ControlServer(directory: dir, dispatch: { req, conn in conn.send(.response(req.id, ["echo": .string(req.method)])) })
        try server.start(appVersion: "test")
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        let token = try String(contentsOf: ControlProtocol.tokenURL(in: dir), encoding: .utf8)

        let c = try ControlClientConnection(socketPath: server.socketPath)
        XCTAssertThrowsError(try c.call("app.status")) { XCTAssertEqual(($0 as? ControlError)?.code, "unauthorized") }
        XCTAssertThrowsError(try c.hello(token: "wrong", client: "t")) { XCTAssertEqual(($0 as? ControlError)?.code, "unauthorized") }
        let hello = try c.hello(token: token, client: "t")
        XCTAssertEqual(hello["protocol"]?.intValue, ControlProtocol.version)
        XCTAssertEqual(try c.call("app.status")["echo"], "app.status")

        let old = try ControlClientConnection(socketPath: server.socketPath)
        XCTAssertThrowsError(try old.call("hello", params: ["protocol": 99, "token": .string(token)])) {
            XCTAssertEqual(($0 as? ControlError)?.code, "protocol_mismatch")
        }
    }
}

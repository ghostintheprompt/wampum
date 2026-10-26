import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class InterruptionTests: XCTestCase {
    @MainActor func testActiveRequestCancellationClosesConnectionAndRecoversHistory() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let script="""
        import socket,sys,pathlib,json
        root=pathlib.Path(sys.argv[1])
        server=socket.socket();server.bind(('127.0.0.1',0));server.listen(2);server.settimeout(10)
        (root/'port').write_text(str(server.getsockname()[1]))
        for index in range(2):
            conn,_=server.accept();conn.settimeout(5);data=b''
            while b'\\r\\n\\r\\n' not in data: data+=conn.recv(4096)
            header,body=data.split(b'\\r\\n\\r\\n',1)
            size=int(next(line.split(b':',1)[1] for line in header.split(b'\\r\\n') if line.lower().startswith(b'content-length:')))
            while len(body)<size: body+=conn.recv(4096)
            (root/('request'+str(index))).write_text('received')
            if index==0:
                closed=conn.recv(1)==b''
                (root/'closed').write_text(str(closed))
            else:
                payload=json.dumps({'message':{'content':'READY'},'prompt_eval_count':8,'eval_count':1}).encode()
                conn.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Type: application/json\\r\\nContent-Length: '+str(len(payload)).encode()+b'\\r\\nConnection: close\\r\\n\\r\\n'+payload)
            conn.close()
        server.close()
        """
        let server=Process();server.executableURL=URL(fileURLWithPath:"/usr/bin/python3");server.arguments=["-u","-c",script,root.path];server.standardOutput=FileHandle.nullDevice;server.standardError=FileHandle.nullDevice
        try server.run();defer{if server.isRunning{server.terminate()}}
        for _ in 0..<100{if FileManager.default.fileExists(atPath:root.appendingPathComponent("port").path){break};try await Task.sleep(nanoseconds:20_000_000)}
        let port=try String(contentsOf:root.appendingPathComponent("port")), base=try XCTUnwrap(URL(string:"http://127.0.0.1:"+port))
        let m=WorkbenchModel(stateDirectory:root.appendingPathComponent("state"),ollamaBase:base)
        m.models=[try JSONDecoder().decode(LocalModel.self,from:Data("{\"name\":\"fixture-model\"}".utf8))];m.session.model="fixture-model";m.session.notes="PRESERVE_CASE";m.session.draft="UNSAVED_DRAFT";m.session.prompt="synthetic slow request"
        m.send();XCTAssertTrue(m.showRequestReview);m.sendReviewedRequest()
        for _ in 0..<100{if FileManager.default.fileExists(atPath:root.appendingPathComponent("request0").path){break};try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("request0").path));XCTAssertTrue(m.busy)
        let start=Date();m.stopGeneration()
        for _ in 0..<100{if !m.busy{break};try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertFalse(m.busy);XCTAssertLessThan(Date().timeIntervalSince(start),2);XCTAssertNil(m.error);XCTAssertTrue(m.status.contains("cancelled"));XCTAssertEqual(m.session.messages.count,1)
        for _ in 0..<100{if FileManager.default.fileExists(atPath:root.appendingPathComponent("closed").path){break};try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("closed")),"True")
        let restored=WorkbenchModel(stateDirectory:m.store.directory,ollamaBase:base)
        XCTAssertEqual(restored.session.notes,"PRESERVE_CASE");XCTAssertEqual(restored.session.draft,"UNSAVED_DRAFT");XCTAssertEqual(restored.session.messages.count,1);XCTAssertFalse(restored.busy)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("request1").path))
        restored.models=m.models;restored.session.prompt="Reply READY";restored.send();restored.sendReviewedRequest()
        for _ in 0..<100{if !restored.busy{break};try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertNil(restored.error);XCTAssertEqual(restored.session.messages.last?.content,"READY")
    }
    @MainActor func testInterruptedCheckRestoresEvidenceWithoutRerunning() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let record=CheckRecord(project:root.path,command:"touch SHOULD_NOT_EXIST")
        let records=CheckRecordStore(directory:root);try records.save(record)
        try Data("PARTIAL_OUTPUT".utf8).write(to:root.appendingPathComponent(record.logName))
        let m=WorkbenchModel(stateDirectory:root)
        XCTAssertEqual(m.lastCheck?.state,.interrupted);XCTAssertTrue(m.output.contains("PARTIAL_OUTPUT"));XCTAssertFalse(m.running)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("SHOULD_NOT_EXIST").path))
        XCTAssertEqual(try records.load()?.state,.interrupted)
        let file=root.appendingPathComponent("last-check.json"), corrupt=Data("broken".utf8);try corrupt.write(to:file)
        let broken=WorkbenchModel(stateDirectory:root);broken.session.project=root.path;broken.command="printf SHOULD_NOT_RUN";broken.runCheck()
        XCTAssertTrue(broken.checkRecordBlocked);XCTAssertFalse(broken.running);XCTAssertEqual(try Data(contentsOf:file),corrupt)
    }
    @MainActor func testCompletedCheckAndOutputSurviveRestart() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let m=WorkbenchModel(stateDirectory:root.appendingPathComponent("state"));m.session.project=root.path;m.command="printf SAVED_CHECK; exit 9";m.runCheck()
        for _ in 0..<100{if !m.running{break};try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertEqual(m.lastCheck?.exitCode,9);XCTAssertEqual(m.lastCheck?.state,.completed)
        let restored=WorkbenchModel(stateDirectory:m.store.directory)
        XCTAssertTrue(restored.output.contains("SAVED_CHECK"));XCTAssertEqual(restored.lastCheck?.exitCode,9);XCTAssertFalse(restored.running)
    }
    @MainActor func testShutdownForcesOwnedCheckToEnd() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let m=WorkbenchModel(stateDirectory:root.appendingPathComponent("state"));m.session.project=root.path;m.command="trap '' TERM; printf READY > '\(root.appendingPathComponent("ready").path)'; /bin/sleep 30";m.runCheck();XCTAssertTrue(m.running)
        for _ in 0..<100{if FileManager.default.fileExists(atPath:root.appendingPathComponent("ready").path){break};try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("ready").path))
        m.shutdown()
        for _ in 0..<100{if !m.running{break};try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertFalse(m.running);XCTAssertEqual(m.lastCheck?.state,.stopped);XCTAssertEqual(m.lastCheck?.exitCode,137)
    }

}

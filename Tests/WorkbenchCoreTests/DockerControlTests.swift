import XCTest
@testable import WorkbenchCore

final class DockerControlTests: XCTestCase {
    // A real executable stands in for the docker binary so CommandPlan.ownedTool passes.
    private let fakeDocker = URL(fileURLWithPath: "/bin/echo")
    private let scope = AuthorizedScope(["*.target.test", "api.target.test"])

    func testUnknownSubcommandIsOpenButConservativelyRequiresInScopeTarget() throws {
        // Open within RoE: an unknown subcommand is allowed, but treated as network-capable,
        // so it needs a declared in-scope target and fails closed without one / out of scope.
        XCTAssertThrowsError(try DockerControl.plan(executable: fakeDocker, subcommand: "swarm", arguments: ["init"], targets: [], scope: scope))
        XCTAssertThrowsError(try DockerControl.plan(executable: fakeDocker, subcommand: "swarm", arguments: ["init"], targets: ["https://evil.example/"], scope: scope))
        let plan = try DockerControl.plan(executable: fakeDocker, subcommand: "swarm", arguments: ["init"], targets: ["https://node.target.test/"], scope: scope)
        XCTAssertEqual(plan.arguments, ["swarm", "init"])
        XCTAssertEqual(plan.receipt.targets, ["node.target.test"])
    }
    func testSubcommandMustBePlainName() {
        XCTAssertThrowsError(try DockerControl.plan(executable: fakeDocker, subcommand: "--version", arguments: [], targets: [], scope: scope))
        XCTAssertThrowsError(try DockerControl.plan(executable: fakeDocker, subcommand: "", arguments: [], targets: [], scope: scope))
    }

    func testNetworkCapableSubcommandRequiresDeclaredTarget() {
        XCTAssertThrowsError(try DockerControl.plan(executable: fakeDocker, subcommand: "run", arguments: ["alpine", "curl", "x"], targets: [], scope: scope)) { error in
            XCTAssertTrue((error as? WorkbenchError)?.errorDescription?.contains("Declare the in-scope engagement target") == true)
        }
    }

    func testOutOfScopeTargetFailsClosed() {
        XCTAssertThrowsError(try DockerControl.plan(executable: fakeDocker, subcommand: "run", arguments: ["alpine"], targets: ["https://evil.example/"], scope: scope)) { error in
            XCTAssertTrue((error as? WorkbenchError)?.errorDescription?.contains("outside the case's authorized scope") == true)
        }
    }

    func testInScopeNetworkActionBuildsPlanAndReceipt() throws {
        let plan = try DockerControl.plan(executable: fakeDocker, subcommand: "RUN", arguments: ["--rm", "scanner:latest"], targets: ["https://app.target.test/login"], scope: scope)
        XCTAssertEqual(plan.executable, fakeDocker)
        XCTAssertEqual(plan.arguments, ["run", "--rm", "scanner:latest"])
        XCTAssertEqual(plan.receipt.tool, "docker")
        XCTAssertEqual(plan.receipt.action, "run")
        XCTAssertEqual(plan.receipt.targets, ["app.target.test"])
        XCTAssertEqual(plan.receipt.outcome, .planned)
        XCTAssertTrue(plan.receipt.detail.contains("outside Wampum's control"))
    }

    func testReadOnlyActionNeedsNoTarget() throws {
        let plan = try DockerControl.plan(executable: fakeDocker, subcommand: "ps", arguments: ["-a"], targets: [], scope: scope)
        XCTAssertEqual(plan.arguments, ["ps", "-a"])
        XCTAssertTrue(plan.receipt.targets.isEmpty)
    }

    func testControlCharacterInArgumentRejected() {
        XCTAssertThrowsError(try DockerControl.plan(executable: fakeDocker, subcommand: "ps", arguments: ["-a\nrm -rf /"], targets: [], scope: scope))
    }

    func testEmptyScopeBlocksEvenAReadOnlyWithDeclaredTarget() {
        // If the operator declares a target, it must be in scope even for a read-only action.
        XCTAssertThrowsError(try DockerControl.plan(executable: fakeDocker, subcommand: "inspect", arguments: [], targets: ["https://app.target.test/"], scope: AuthorizedScope([])))
    }
}

import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// Remote project commands and Shell on Host against the SSH fixture: the exact argv a
/// terminal tab runs, under `script(1)` for a pty (part of the serialized `SSHRunTests`).
extension SSHRunTests {
    @Test func projectCommandsRunOnTheServerInTheProfilesDirectory() async throws {
        let environment = try await SSHFixture.environment()
        let directory = "/srv/term it's \"odd\" $HOME `x`"
        try await environment.exec("mkdir -p \"$1\" && chmod 755 \"$1\"", arguments: [directory])
        let client = environment.client()
        let endpoint = environment.endpoint()
        defer { Task { await client.disconnect(endpoint) } }
        let target = environment.target(endpoint, directory: directory, php: "/usr/local/bin/php")

        let command = ProjectCommand(name: "where", commandLine: "php -r 'echo getcwd(), \"|\", PHP_BINARY, PHP_EOL;' && echo \"done-$((40 + 2))\"", origin: .driver, source: "Test")
        let request = try ProjectCommandLauncher.terminalRequest(for: command, target: target, dockerExecutable: nil, ssh: client)
        let terminal = try PseudoTerminal(try #require(request.executable), environment: client.environment)
        defer { terminal.stop() }
        #expect(try await terminal.waitFor { !terminal.isRunning }, "\(terminal.text)")
        #expect(terminal.exitCode == 0, "\(terminal.text)")
        #expect(terminal.text.contains("\(directory)|/usr/local/bin/php"), "the server's PHP in the profile's directory: \(terminal.text)")
        #expect(terminal.text.contains("done-42"))
        #expect(!terminal.text.contains("Runlet fixture banner"), "LogLevel=ERROR keeps the banner out")

        // A missing directory is explained in the terminal and the command doesn't run.
        let missing = try ProjectCommandLauncher.terminalRequest(for: command, target: environment.target(endpoint, directory: "/srv/nope"), dockerExecutable: nil, ssh: client)
        let failed = try PseudoTerminal(try #require(missing.executable), environment: client.environment)
        defer { failed.stop() }
        #expect(try await failed.waitFor { !failed.isRunning })
        #expect(failed.exitCode == 2)
        #expect(failed.text.contains("/srv/nope doesn't exist on this server"), "\(failed.text)")
        #expect(!failed.text.contains("done-42"))
    }

    @Test func shellOnHostStartsALoginShellInTheDirectory() async throws {
        let environment = try await SSHFixture.environment()
        let client = environment.client()
        let endpoint = environment.endpoint()
        defer { Task { await client.disconnect(endpoint) } }

        let request = try ProjectCommandLauncher.sshShellRequest(target: environment.target(endpoint, directory: "/srv/app"), title: "Shell", ssh: client)
        let shell = try PseudoTerminal(try #require(request.executable), environment: client.environment)
        defer { shell.stop() }
        #expect(try await shell.waitFor { shell.text.contains("$ ") }, "a prompt: \(shell.text)")
        shell.send("echo \"in:$(pwd):$(shopt -q login_shell && echo login)\"; exit\r")
        #expect(try await shell.waitFor { !shell.isRunning }, "\(shell.text)")
        #expect(shell.text.contains("in:/srv/app:login"), "a bash login shell in the directory: \(shell.text)")

        // An unknown host key: refused in the terminal too, nothing accepted.
        let unknown = environment.endpoint(host: SSHFixture.Environment.unknownKeyHost)
        let refusedRequest = try ProjectCommandLauncher.sshShellRequest(target: environment.target(unknown), title: "Shell", ssh: client)
        let refused = try PseudoTerminal(try #require(refusedRequest.executable), environment: client.environment)
        defer { refused.stop() }
        #expect(try await refused.waitFor { !refused.isRunning })
        #expect(refused.exitCode == 255)
        #expect(refused.text.lowercased().contains("host key verification failed"), "\(refused.text)")
    }
}

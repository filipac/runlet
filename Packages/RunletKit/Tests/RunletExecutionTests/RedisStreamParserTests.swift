import Foundation
import Testing
@testable import RunletCore
@testable import RunletExecution

@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct RedisStreamParserTests {
    private func php(_ body: String) throws -> Data {
        let code = "require " + RedisLiveTests.phpString(TestSupport.repoRoot.appendingPathComponent("Resources/Runner/dist/runlet-runner.php").path) + "; " + body
        let result = try TestProcess.runBlocking([DriverSupport.php, "-r", code], step: "Redis stream parser", within: .seconds(20))
        return Data(result.output.utf8)
    }

    @Test func partialRepliesStillTickAndProtocolErrorsHideBytes() throws {
        let data = try php(#"""
        $pair = stream_socket_pair(STREAM_PF_UNIX, STREAM_SOCK_STREAM, 0);
        stream_set_blocking($pair[0], false);
        fwrite($pair[1], "*3\r\n$7\r\nmessage\r\n$1\r\na\r\n$100\r\npartial");
        $client = new \RunletRunner\RedisClient($pair[0]); $client->payloadLimit = 65536;
        $started = microtime(true);
        $client->tick = static function () use ($started) {
            if (microtime(true) - $started >= 0.15) { throw new \RunletRunner\RedisStreamLimit('idle'); }
        };
        try { $client->read(8, new \RunletRunner\RedisReplyBudget()); }
        catch (\RunletRunner\RedisStreamLimit $error) { $elapsed = microtime(true) - $started; }
        $client->close(); fclose($pair[1]);
        $pair = stream_socket_pair(STREAM_PF_UNIX, STREAM_SOCK_STREAM, 0);
        fwrite($pair[1], "?private-payload\r\n");
        $client = new \RunletRunner\RedisClient($pair[0]); $client->payloadLimit = 65536;
        try { $client->read(8, new \RunletRunner\RedisReplyBudget()); }
        catch (\Throwable $error) { $message = $error->getMessage(); }
        echo json_encode(['elapsed' => $elapsed ?? 99, 'message' => $message ?? '']);
        """#)
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let elapsed = try #require(result["elapsed"] as? Double)
        #expect(elapsed >= 0.15 && elapsed < 1)
        #expect(!(result["message"] as? String ?? "").contains("private-payload"))
    }

    @Test func redactionParityAndStreamingTable() throws {
        let cases = [
            ["AUTH", "pw"], ["AUTH", "user", "pw"], ["HELLO", "3", "AUTH", "user", "pw", "SETNAME", "client"],
            ["MIGRATE", "host", "6379", "key", "0", "1000", "AUTH", "pw"],
            ["MIGRATE", "host", "6379", "key", "0", "1000", "AUTH2", "user", "pw"],
            ["ACL", "SETUSER", "user", ">pw", "<old", "#hash", "!hash", "on", "+@all"],
            ["CONFIG", "SET", "masterauth", "pw", "requirepass", "new", "masteruser", "user"],
            ["SET", "key", "value"], ["AUTH"], ["HELLO", "3"], ["hello", "3", "auth", "u", "pw"]
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: cases), as: UTF8.self)
        let data = try php("$cases = json_decode(\(RedisLiveTests.phpString(json)), true); echo json_encode(array_map(['RunletRunner\\RedisStreamParser', 'secretArguments'], $cases));")
        let actual = try JSONDecoder().decode([[Int]].self, from: data)
        #expect(actual == cases.map { RedisScript.secretArguments($0).sorted() })
        let lists = try php("echo json_encode(\\RunletRunner\\RedisCommands::LIVE_STREAMS);")
        #expect(Set(try JSONDecoder().decode([String].self, from: lists)) == RedisCommands.liveStreams)
    }

    @Test func monitorGrammarAndSecretsBeforeEmission() throws {
        let lines = [
            #"123.456 [0 127.0.0.1:1234] "SET" "key" "a\n\r\t\a\b\\\"\x00\xff" """#,
            #"123.457 [2 lua] "AUTH" "other-password""#,
            #"123.458 [3 unix:/tmp/redis.sock] "HELLO" "3" "AUTH" "user" "hello-password""#,
            #"123.459 [0 lua] "ACL" "SETUSER" "user" ">acl-password" "(redacted)""#,
            #"123.460 [0 lua] "CONFIG" "SET" "masterauth" "config-password""#,
            #"123.461 [0 lua] "AUTH" "(redacted)""#,
            #"123.462 [0 lua] "SET" "key" "stream-password""#,
            #"123.463 [0 lua] "AUTH" "unterminated"#
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: lines), as: UTF8.self)
        let data = try php("\\RunletRunner\\Channel::addSecret('stream-password'); $lines = json_decode(\(RedisLiveTests.phpString(json)), true); echo json_encode(array_map(['RunletRunner\\RedisStreamParser', 'monitor'], $lines));")
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [Any])
        let first = try #require(result[0] as? [String: Any])
        let args = try #require(first["argv"] as? [String])
        #expect(args[3] == "")
        #expect(args[2].contains("\\xFF"))
        #expect((result[1] as? [String: Any])?["client"] as? String == "lua")
        #expect((result[2] as? [String: Any])?["client"] as? String == "unix:/tmp/redis.sock")
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["other-password", "hello-password", "acl-password", "config-password", "stream-password"] { #expect(!text.contains(secret)) }
        #expect(text.contains("(redacted)"))
        #expect(result[7] is NSNull)
    }
}

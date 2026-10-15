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

    /// Large MONITOR lines must not end the run or consume memory past the line cap (#203).
    @Test func oversizedLinesDrainAndKeepTheNextReply() throws {
        let directory = TestSupport.repoRoot.appendingPathComponent("build").path
        let data = try php("$directory = \(RedisLiveTests.phpString(directory)); " + #"""
        $results = [];
        foreach ([8388608, 8388609, 9 * 1024 * 1024 - 1] as $length) {
            $path = tempnam($directory, 'issue-203-monitor-');
            try {
                $file = fopen($path, 'w+b');
                fwrite($file, '+');
                for ($left = $length - 1; $left > 0; $left -= $size) {
                    $size = min($left, 65536);
                    fwrite($file, str_repeat('x', $size));
                }
                fwrite($file, "\r\n+123.456 [0 lua] \"SET\" \"after\" \"visible\"\r\n");
                rewind($file);
                $client = new \RunletRunner\RedisClient($file);
                $client->payloadLimit = 65536;
                $buffer = new ReflectionProperty($client, 'buffer');
                $buffer->setAccessible(true);
                $maxBuffer = 0;
                $ticks = 0;
                $client->tick = static function () use ($client, $buffer, &$maxBuffer, &$ticks) {
                    $ticks++;
                    $maxBuffer = max($maxBuffer, strlen($buffer->getValue($client)));
                };
                $first = $client->read(8, new \RunletRunner\RedisReplyBudget());
                $next = $client->read(8, new \RunletRunner\RedisReplyBudget());
                $results[] = ['type' => $first['t'], 'maxBuffer' => $maxBuffer, 'ticks' => $ticks,
                    'next' => \RunletRunner\RedisStreamParser::monitor($next['v'])['argv']];
                $client->close();
            } finally {
                unlink($path);
            }
        }
        echo json_encode($results);
        """#)
        let results = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(results.map { $0["type"] as? String } == ["+", "omitted", "omitted"])
        for result in results {
            #expect(result["next"] as? [String] == ["SET", "after", "visible"])
            #expect(try #require(result["maxBuffer"] as? Int) <= 8 * 1024 * 1024 + 65536)
            #expect(try #require(result["ticks"] as? Int) > 128)
        }
    }

    /// Stream results share #138's threshold, while errors and AUTH always redact (#203).
    @Test func shortPasswordsLeaveStreamResultsIntact() throws {
        for password in ["a", "ab", "abc", "abcd"] {
            let body = #"""
            \RunletRunner\Channel::addSecret($password);
            $value = 'channel-' . $password . "\x00\xff";
            $line = '123.456 [0 lua] "SET" "key" "' . $password . '"';
            $auth = '123.456 [0 lua] "AUTH" "' . $password . '"';
            echo json_encode([
                'payload' => base64_encode(\RunletRunner\Channel::scrubResult($value)),
                'channel' => \RunletRunner\RedisStreamParser::safe('channel-' . $password),
                'monitor' => \RunletRunner\RedisStreamParser::monitor($line)['argv'],
                'auth' => \RunletRunner\RedisStreamParser::monitor($auth)['argv'],
                'error' => \RunletRunner\Channel::scrub('error-' . $password)
            ]);
            """#
            let data = try php("$password = \(RedisLiveTests.phpString(password)); " + body)
            let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let expected = password.count >= 4 ? "•••" : password
            #expect(result["channel"] as? String == "channel-" + expected)
            let encoded = try #require(result["payload"] as? String)
            let payload = try #require(Data(base64Encoded: encoded))
            #expect(payload == Data(("channel-" + expected).utf8) + Data([0, 255]))
            #expect(result["monitor"] as? [String] == ["SET", "key", expected])
            #expect(result["auth"] as? [String] == ["AUTH", "•••"])
            #expect(result["error"] as? String == "error-•••")
        }
        let data = try php(#"""
        \RunletRunner\Channel::addSecret('long-password', false);
        echo json_encode(\RunletRunner\RedisStreamParser::safe('long-password'));
        """#)
        #expect(try JSONDecoder().decode(String.self, from: data) == "long-password")
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
            #"123.463 [0 lua] "AUTH" "unterminated"#,
            #"123.464 [0 [::1]:1234] "SET" "key" "value""#
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
        #expect((result[8] as? [String: Any])?["client"] as? String == "[::1]:1234")
    }
}

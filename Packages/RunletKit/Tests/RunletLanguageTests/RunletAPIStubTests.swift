import Foundation
import RunletCore
import Testing
@testable import RunletLanguage

/// Runlet's snippet API in the editor (#196): the stub PHPantom gets matches the runner's public
/// API, and `\Runlet\` completes and hovers in a snippet.
@Suite(.phpantom)
struct RunletAPIStubTests {
    static var php: String? { ExecutableLocator.resolve("php") }
    static var runner: URL { LanguageTestSupport.repoRoot.appendingPathComponent("Resources/Runner/dist/runlet-runner.php") }

    /// Every function in the `Runlet` namespace, and `Runlet\Inspector`'s public constants and
    /// methods without `@internal`, by reflection: names, parameters (type, default, by
    /// reference, variadic), and return types.
    static let reflect = #"""
    <?php
    require $argv[1];
    function runlet_signature(ReflectionFunctionAbstract $function): array {
        $parameters = [];
        foreach ($function->getParameters() as $parameter) {
            $entry = ['name' => $parameter->getName(), 'type' => (string) $parameter->getType(), 'optional' => $parameter->isOptional(), 'byReference' => $parameter->isPassedByReference(), 'variadic' => $parameter->isVariadic()];
            if ($parameter->isDefaultValueAvailable()) {
                $entry['default'] = var_export($parameter->getDefaultValue(), true);
            }
            $parameters[] = $entry;
        }
        return ['parameters' => $parameters, 'returns' => (string) $function->getReturnType()];
    }
    $api = ['functions' => [], 'methods' => [], 'constants' => []];
    foreach (get_defined_functions()['user'] as $name) {
        if (strpos($name, 'runlet\\') === 0 && substr_count($name, '\\') === 1) {
            $function = new ReflectionFunction($name);
            $api['functions'][$function->getName()] = runlet_signature($function);
        }
    }
    $class = new ReflectionClass('Runlet\Inspector');
    foreach ($class->getMethods(ReflectionMethod::IS_PUBLIC) as $method) {
        if (strpos((string) $method->getDocComment(), '@internal') === false) {
            $api['methods'][$method->getName()] = runlet_signature($method) + ['static' => $method->isStatic()];
        }
    }
    foreach ($class->getReflectionConstants() as $constant) {
        if ($constant->isPublic()) {
            $api['constants'][$constant->getName()] = $constant->getValue();
        }
    }
    ksort($api['functions']);
    ksort($api['methods']);
    ksort($api['constants']);
    echo json_encode($api, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    """#

    static func api(of file: URL, php: String) throws -> String {
        let script = LanguageTestSupport.tempDirectory().appendingPathComponent("reflect.php")
        try reflect.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: php)
        process.arguments = ["-n", script.path, file.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test(.enabled(if: RunletAPIStubTests.php != nil, "requires host PHP"))
    func theStubMatchesTheRunnersPublicAPI() throws {
        let php = try #require(Self.php)
        let stub = LanguageTestSupport.tempDirectory().appendingPathComponent("runlet-api.php")
        try RunletAPIStub.source.write(to: stub, atomically: true, encoding: .utf8)
        let expected = try Self.api(of: Self.runner, php: php)
        let declared = try Self.api(of: stub, php: php)
        #expect(expected.contains("\"Runlet\\\\notice\""), "\(expected)")
        #expect(expected.contains("\"Runlet\\\\explainPlan\"") && expected.contains("\"watchPdo\""), "\(expected)")
        #expect(declared == expected, "Update RunletAPIStub.source to match Resources/Runner/src (php scripts/build-runner.php first).\nStub:\n\(declared)\nRunner:\n\(expected)")
    }

    @Test(.enabled(if: LanguageTestSupport.hasBinary, "run scripts/fetch-phpantom.sh"))
    func runletCompletesAndHoversInASnippet() async throws {
        let root = LanguageTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = await LanguageTestSupport.session(root, kind: .basic)
        defer { Task { await session.stop() } }

        let editorText = "\\Runlet\\\n\\Runlet\\Inspector::current()->\n\\Runlet\\warning('x');"
        let (uri, mapping) = await LanguageTestSupport.open(session, root: root, editorText: editorText)
        let functions = LanguageTestSupport.labels(try await session.completion(uri: uri, position: mapping.toLSP(LSPPosition(line: 0, character: 8)), triggerCharacter: "\\"))
        for name in ["notice", "warning", "error", "bench", "explainPlan"] {
            #expect(functions.contains(name), "\(name) in \(functions)")
        }
        // PHPantom labels classes with their namespace.
        #expect(functions.contains("Runlet\\Inspector"), "\(functions)")
        let methods = LanguageTestSupport.labels(try await session.completion(uri: uri, position: mapping.toLSP(LSPPosition(line: 1, character: 30)), triggerCharacter: ">"))
        for name in ["notice", "warning", "error", "record", "log"] {
            #expect(methods.contains(name), "\(name) in \(methods)")
        }
        let hover = try await session.hover(uri: uri, position: mapping.toLSP(LSPPosition(line: 2, character: 10)))
        #expect(hover?.markdown.contains("warning card") == true, "\(hover?.markdown ?? "no hover")")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".runlet-scratch").path), "the stub is never written")
    }
}

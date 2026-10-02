import Foundation
import RunletCore

/// Facts about a target detected *without running project code*: framework/driver from
/// files on disk and versions from source constants. Runs later replace them with exact values.
public struct DetectedFacts: Sendable, Codable, Equatable {
    public var framework: String?
    public var frameworkVersion: String?
    public var driverName: String?
    public var phpVersion: String?

    public init(framework: String? = nil, frameworkVersion: String? = nil, driverName: String? = nil, phpVersion: String? = nil) {
        self.framework = framework
        self.frameworkVersion = frameworkVersion
        self.driverName = driverName
        self.phpVersion = phpVersion
    }
}

public enum TargetInspector {
    /// Reads a project directory on this Mac. Never executes PHP.
    public static func staticFacts(projectRoot: URL) -> DetectedFacts {
        let fm = FileManager.default
        func exists(_ path: String) -> Bool { fm.fileExists(atPath: projectRoot.appendingPathComponent(path).path) }
        func read(_ path: String) -> String? {
            let url = projectRoot.appendingPathComponent(path)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path), (attributes[.size] as? Int ?? 0) < 2_000_000 else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }

        // Project drivers (.runlet/*Driver.php) win, like the runner's detection order.
        let runlet = projectRoot.appendingPathComponent(".runlet", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(atPath: runlet.path) {
            let drivers = files.filter { $0.hasSuffix("Driver.php") }.sorted()
            if let file = drivers.first, let source = try? String(contentsOf: runlet.appendingPathComponent(file), encoding: .utf8) {
                let className = firstMatch(#"class\s+([A-Za-z_][A-Za-z0-9_]*)\s+extends"#, in: source) ?? String(file.dropLast(4))
                return DetectedFacts(
                    framework: "custom:\(className)",
                    frameworkVersion: literalReturn(of: "version", in: source),
                    driverName: literalReturn(of: "name", in: source) ?? className
                )
            }
        }

        if exists("bootstrap/app.php") && (exists("artisan") || exists("vendor/laravel-zero/framework")) {
            let version = read("vendor/laravel/framework/src/Illuminate/Foundation/Application.php").flatMap { firstMatch(#"const\s+VERSION\s*=\s*'([^']+)'"#, in: $0) }
            let lumen = exists("vendor/laravel/lumen-framework")
            return DetectedFacts(framework: lumen ? "lumen" : (exists("vendor/laravel-zero/framework") ? "laravel-zero" : "laravel"), frameworkVersion: version)
        }
        for base in ["", "web/wp/", "public/wp/", "wordpress/", "wp/"] where exists(base + "wp-load.php") {
            let version = read(base + "wp-includes/version.php").flatMap { firstMatch(#"\$wp_version\s*=\s*'([^']+)'"#, in: $0) }
            return DetectedFacts(framework: "wordpress", frameworkVersion: version)
        }
        if exists("bin/console") && (exists("src/Kernel.php") || exists("config/bundles.php")) {
            let version = read("vendor/symfony/http-kernel/Kernel.php").flatMap { firstMatch(#"const\s+VERSION\s*=\s*'([^']+)'"#, in: $0) }
            return DetectedFacts(framework: "symfony", frameworkVersion: version)
        }
        if exists("composer.json") || exists("vendor/autoload.php") {
            return DetectedFacts(framework: "composer")
        }
        return DetectedFacts(framework: "plain")
    }

    /// `public function name(): string { return 'Literal'; }` → "Literal".
    static func literalReturn(of method: String, in source: String) -> String? {
        firstMatch(#"function\s+"# + method + #"\s*\([^)]*\)\s*(?::\s*\??[A-Za-z]+\s*)?\{\s*return\s+'([^']*)'\s*;"#, in: source)
            ?? firstMatch(#"function\s+"# + method + #"\s*\([^)]*\)\s*(?::\s*\??[A-Za-z]+\s*)?\{\s*return\s+"([^"$]*)"\s*;"#, in: source)
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

extension DockerCLI {
    /// The container's PHP version via `php -n -r` (no php.ini, nothing from the project runs).
    public func phpVersion(containerId: String, phpExecutable: String, user: String?) async -> String? {
        var arguments = ["exec"]
        if let user, !user.isEmpty { arguments += ["--user", user] }
        arguments += [containerId, phpExecutable, "-n", "-r", "echo PHP_VERSION;"]
        guard let result = try? await runCommand(spec(arguments), timeout: .seconds(8)), result.exitCode == 0 else { return nil }
        let version = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty || version.count > 40 ? nil : version
    }

    /// Framework/driver detection inside a container by file checks only (`php -n`, no
    /// project code), for profiles without a local source. Versions come from source constants.
    public func detectFacts(containerId: String, phpExecutable: String, user: String?, workingDirectory: String) async -> DetectedFacts? {
        let code = #"""
        $w = $argv[1]; $r = ['framework' => 'plain'];
        $read = function ($p, $re) { $s = @file_get_contents($p, false, null, 0, 2000000); return ($s !== false && preg_match($re, $s, $m)) ? $m[1] : null; };
        $drivers = glob("$w/.runlet/*Driver.php") ?: [];
        sort($drivers);
        if ($drivers) {
            $s = (string) @file_get_contents($drivers[0]);
            $class = preg_match('/class\s+([A-Za-z_][A-Za-z0-9_]*)\s+extends/', $s, $m) ? $m[1] : basename($drivers[0], '.php');
            $r = ['framework' => "custom:$class", 'driverName' => $class];
            if (preg_match("/function\s+name\s*\([^)]*\)\s*(?::\s*\??[A-Za-z]+\s*)?\{\s*return\s+'([^']*)'\s*;/", $s, $m)) { $r['driverName'] = $m[1]; }
            if (preg_match("/function\s+version\s*\([^)]*\)\s*(?::\s*\??[A-Za-z]+\s*)?\{\s*return\s+'([^']*)'\s*;/", $s, $m)) { $r['frameworkVersion'] = $m[1]; }
        } elseif (is_file("$w/bootstrap/app.php") && (is_file("$w/artisan") || is_dir("$w/vendor/laravel-zero/framework"))) {
            $r = ['framework' => 'laravel', 'frameworkVersion' => $read("$w/vendor/laravel/framework/src/Illuminate/Foundation/Application.php", "/const\s+VERSION\s*=\s*'([^']+)'/")];
        } elseif (is_file("$w/bin/console") && (is_file("$w/src/Kernel.php") || is_file("$w/config/bundles.php"))) {
            $r = ['framework' => 'symfony', 'frameworkVersion' => $read("$w/vendor/symfony/http-kernel/Kernel.php", "/const\s+VERSION\s*=\s*'([^']+)'/")];
        } else {
            foreach (['', 'web/wp/', 'public/wp/', 'wordpress/', 'wp/'] as $b) {
                if (is_file("$w/{$b}wp-load.php")) { $r = ['framework' => 'wordpress', 'frameworkVersion' => $read("$w/{$b}wp-includes/version.php", "/\\\$wp_version\s*=\s*'([^']+)'/")]; break; }
            }
            if ($r['framework'] === 'plain' && (is_file("$w/composer.json") || is_file("$w/vendor/autoload.php"))) { $r = ['framework' => 'composer']; }
        }
        $r['phpVersion'] = PHP_VERSION;
        echo json_encode($r);
        """#
        var arguments = ["exec"]
        if let user, !user.isEmpty { arguments += ["--user", user] }
        arguments += [containerId, phpExecutable, "-n", "-r", code, "--", workingDirectory]
        guard let result = try? await runCommand(spec(arguments), timeout: .seconds(10)), result.exitCode == 0 else { return nil }
        return try? JSONDecoder().decode(DetectedFacts.self, from: result.stdout)
    }
}

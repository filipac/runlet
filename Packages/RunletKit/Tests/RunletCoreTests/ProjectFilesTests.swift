import Foundation
import Testing
@testable import RunletCore

/// #45: `@` files stay inside the project folder, and only text files of a sane size that don't
/// usually hold secrets are read.
struct ProjectFilesTests {
    /// A project "shop" with a few files, a sibling folder outside it, and symbolic links both
    /// ways. Removed by `cleanUp`.
    struct Fixture {
        let base: URL
        var root: URL { base.appendingPathComponent("shop", isDirectory: true) }
        var outside: URL { base.appendingPathComponent("elsewhere", isDirectory: true) }

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-project-files-\(UUID().uuidString)", isDirectory: true)
            let files: [String: String] = [
                "shop/app/Models/Order.php": "<?php\n\nclass Order {}\n",
                "shop/app/Models/User.php": "<?php\n\nclass User {}\n",
                "shop/app/Services/InvoiceTotals.php": "<?php\n\nclass InvoiceTotals {}\n",
                "shop/routes/web.php": "<?php\n",
                "shop/.env": "APP_KEY=base64:abc\n",
                "shop/.env.example": "APP_KEY=\n",
                "shop/.env.production": "DB_PASSWORD=secret\n",
                "shop/storage/oauth-private.key": "key\n",
                "shop/auth.json": "{}\n",
                "shop/vendor/laravel/framework/src/Model.php": "<?php\n",
                "shop/node_modules/x/index.js": "x\n",
                "shop/.git/config": "[core]\n",
                "shop/.runlet/snippets/orders.php": "<?php\n",
                "shop/.idea/workspace.xml": "<x/>\n",
                "elsewhere/secrets.txt": "outside\n",
            ]
            for (path, text) in files {
                let url = base.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            let binary = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])
            try FileManager.default.createDirectory(at: base.appendingPathComponent("shop/public"), withIntermediateDirectories: true)
            try binary.write(to: base.appendingPathComponent("shop/public/logo.png"))
            try FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent("shop/escape.txt").path, withDestinationPath: "../elsewhere/secrets.txt")
            try FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent("shop/linked-folder").path, withDestinationPath: base.appendingPathComponent("elsewhere").path)
            try FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent("shop/order-link.php").path, withDestinationPath: "app/Models/Order.php")
            try FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent("shop/config.txt").path, withDestinationPath: ".env")
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: base)
        }
    }

    @Test func readsTextFilesInsideTheProject() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let order = try ProjectFiles.read("app/Models/Order.php", in: fixture.root).get()
        #expect(order.path == "app/Models/Order.php")
        #expect(order.text == "<?php\n\nclass Order {}\n")
        #expect(order.bytes == 22)
        #expect(try ProjectFiles.read("./app//Models/User.php", in: fixture.root).get().path == "app/Models/User.php")
        // A link that stays inside the project is fine; vendor files work when named.
        #expect(try ProjectFiles.read("order-link.php", in: fixture.root).get().text.contains("class Order"))
        #expect(try ProjectFiles.read("vendor/laravel/framework/src/Model.php", in: fixture.root).get().text == "<?php\n")
        #expect(try ProjectFiles.read(".env.example", in: fixture.root).get().text == "APP_KEY=\n")
    }

    @Test func nothingOutsideTheProjectIsRead() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let outside = fixture.outside.appendingPathComponent("secrets.txt").path
        for reference in ["../elsewhere/secrets.txt", "app/../../elsewhere/secrets.txt", outside, "~/.ssh/id_rsa", "escape.txt", "linked-folder/secrets.txt"] {
            #expect(ProjectFiles.read(reference, in: fixture.root) == .failure(.outsideProject), "\(reference)")
        }
    }

    @Test func foldersSecretsBinariesAndMissingFilesAreRefused() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        #expect(ProjectFiles.read("app/Models", in: fixture.root) == .failure(.folder))
        #expect(ProjectFiles.read(".", in: fixture.root) == .failure(.folder))
        #expect(ProjectFiles.read("app/Models/Missing.php", in: fixture.root) == .failure(.notFound))
        #expect(ProjectFiles.read("", in: fixture.root) == .failure(.notFound))
        for secret in [".env", ".env.production", "storage/oauth-private.key", "auth.json", ".git/config", "config.txt"] {
            #expect(ProjectFiles.read(secret, in: fixture.root) == .failure(.secret), "\(secret)")
        }
        #expect(ProjectFiles.read("public/logo.png", in: fixture.root) == .failure(.binary))
        #expect(ProjectFiles.read("app/Models/Order.php", in: fixture.root, maxBytes: 10) == .failure(.tooLarge(bytes: 22)))
        #expect(ProjectFileError.tooLarge(bytes: 2_000_000).message.hasPrefix("It's 2 MB"))
    }

    @Test func specialFilesAreNeverOpened() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let fifo = fixture.root.appendingPathComponent("queue.pipe").path
        #expect(mkfifo(fifo, 0o600) == 0)
        // Opening a FIFO for reading would block until a writer comes.
        #expect(ProjectFiles.read("queue.pipe", in: fixture.root) == .failure(.notAFile))
    }

    @Test func secretNames() {
        for path in [".env", ".env.local", "deploy/.env.staging", "id_rsa", "keys/id_ed25519.pub", "certs/server.pem", "storage/oauth-private.key", ".git/HEAD", "auth.json", "home/.ssh/config"] {
            #expect(ProjectFiles.isSecret(path), "\(path)")
        }
        for path in [".env.example", "app/Models/Order.php", "config/auth.php", "keys.php", "resources/views/environment.blade.php"] {
            #expect(!ProjectFiles.isSecret(path), "\(path)")
        }
    }

    @Test func completionListsProjectFilesAndRanksThem() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let files = ProjectFiles.list(in: fixture.root)
        #expect(Set(files).isSuperset(of: ["app/Models/Order.php", "app/Models/User.php", "routes/web.php", ".runlet/snippets/orders.php", ".env.example", "order-link.php"]))
        for hidden in [".env", ".env.production", "auth.json", "storage/oauth-private.key", "vendor/laravel/framework/src/Model.php", "node_modules/x/index.js", ".git/config", ".idea/workspace.xml", "linked-folder/secrets.txt", "linked-folder", "escape.txt"] {
            #expect(!files.contains(hidden), "\(hidden)")
        }
        #expect(ProjectFiles.list(in: fixture.root, limit: 2).count == 2)

        let paths = ["app/Models/Order.php", "app/Models/OrderLine.php", "app/Http/Controllers/OrderController.php", "database/factories/OrderFactory.php", "routes/web.php", "app/Models/User.php"]
        #expect(ProjectFiles.rank(paths, query: "order", limit: 3) == ["app/Models/Order.php", "app/Models/OrderLine.php", "database/factories/OrderFactory.php"])
        #expect(ProjectFiles.rank(paths, query: "Order.php").first == "app/Models/Order.php")
        #expect(ProjectFiles.rank(paths, query: "app/models/u") == ["app/Models/User.php"])
        #expect(ProjectFiles.rank(paths, query: "amu") == ["app/Models/User.php"])
        #expect(ProjectFiles.rank(paths, query: "zzz").isEmpty)
        #expect(ProjectFiles.rank(paths, query: "", limit: 1) == ["routes/web.php"])
    }
}

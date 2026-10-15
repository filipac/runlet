import Testing
@testable import RunletCore

struct KubernetesLogSourceTests {
    @Test func sourceListUsesPodPathsAndNeverTheLocalSourceCopy() {
        let sources = LogSource.remoteSources(base: "/app", group: .container, hasContainer: true, hasHostFolder: false,
                                             driverPaths: ["storage/logs/laravel.log", "/var/log/worker.log", "logs/*.log"],
                                             found: ["/app/storage/logs/laravel.log", "/app/logs/found.log"],
                                             otherPaths: ["logs/typed.log"], framework: "laravel", outputCommand: "kubectl logs")
        #expect(sources.map(\.kind) == [.containerFile("/app/storage/logs/laravel.log"), .containerFile("/var/log/worker.log"),
                                      .containerFile("/app/logs/found.log"), .containerFile("/app/logs/typed.log"), .containerOutput])
        #expect(sources.allSatisfy { $0.isRemote })
        #expect(sources.last?.detail == "kubectl logs")
        #expect(sources.first?.title == "storage/logs/laravel.log")
    }
}

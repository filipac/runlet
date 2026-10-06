import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// The Docker profile form's container list (#318): a click always makes its container the
/// profile's, listings only highlight, and the fields a click fills in follow the latest click
/// until the user edits them.
struct DockerContainerSelectionTests {
    func container(_ id: String, service: String, user: String = "", workingDir: String = "", mounts: [ContainerMount] = [], project: String = "shop", number: String = "1") -> ContainerInfo {
        ContainerInfo(id: id, name: "\(project)-\(service)-\(number)", image: "\(service):1", running: true, status: "running",
                      labels: ["com.docker.compose.project": project, "com.docker.compose.service": service, "com.docker.compose.container-number": number],
                      workingDir: workingDir, user: user, mounts: mounts, created: "")
    }

    /// Like the fixtures (and the report): a database without a working directory, a cache with
    /// a user, and two PHP services whose working directories are bind-mounted from the host.
    var db: ContainerInfo { container("db1", service: "db") }
    var cache: ContainerInfo { container("mc1", service: "memcached", user: "memcache") }
    var api: ContainerInfo { container("api1", service: "microservice", workingDir: "/var/www", mounts: [ContainerMount(type: "bind", source: "/src/api", destination: "/var/www")]) }
    var app: ContainerInfo { container("app1", service: "app", user: "1000:1000", workingDir: "/app", mounts: [ContainerMount(type: "bind", source: "/src/app", destination: "/app")]) }
    var all: [ContainerInfo] { [db, cache, api, app] }

    let blank = DockerProfile(name: "", identity: ContainerIdentity(), workingDirectory: "/var/www/html")
    let folders: Set<String> = ["/src/api", "/src/app"]

    func newSelection(_ profile: DockerProfile? = nil) -> DockerContainerSelection {
        DockerContainerSelection(profile: profile ?? blank, isNew: true)
    }

    func click(_ container: ContainerInfo, _ selection: inout DockerContainerSelection, _ profile: DockerProfile) -> DockerProfile {
        #expect(selection.needsApplying(container.id, profile: profile, among: all))
        selection.highlight(container.id)
        #expect(selection.isApplying)
        return selection.click(container, in: profile) { folders.contains($0) }
    }

    @Test func theLatestClickWinsWithEveryFieldItFills() {
        var selection = newSelection()
        var profile = click(db, &selection, blank)
        profile = click(cache, &selection, profile)
        profile = click(api, &selection, profile)
        #expect(selection.highlighted == "api1")
        #expect(!selection.isApplying)
        #expect(profile.identity == api.identity)
        #expect(profile.name == "microservice")
        // memcached's user doesn't stay behind; the service runs as the image's user.
        #expect(profile.user == nil)
        #expect(profile.workingDirectory == "/var/www")
        #expect(profile.localSourcePath == "/src/api")
        #expect(!selection.disagrees(with: profile, among: all))
    }

    @Test func aContainerWithoutAWorkingDirectoryGoesBackToTheDefault() {
        var selection = newSelection()
        var profile = click(app, &selection, blank)
        #expect(profile.workingDirectory == "/app")
        #expect(profile.localSourcePath == "/src/app")
        #expect(profile.user == "1000:1000")
        profile = click(db, &selection, profile)
        #expect(profile.identity == db.identity)
        #expect(profile.workingDirectory == "/var/www/html")
        #expect(profile.localSourcePath == nil)
        #expect(profile.user == nil)
    }

    @Test func aMountedFolderThatIsntOnThisMacIsNoLocalSource() {
        var selection = newSelection()
        let profile = selection.click(api, in: blank) { _ in false }
        #expect(profile.workingDirectory == "/var/www")
        #expect(profile.localSourcePath == nil)
    }

    @Test func editedFieldsAreKeptAndClearingOneHandsItBack() {
        var selection = newSelection()
        var profile = click(app, &selection, blank)
        profile.user = "www-data"
        selection.edit(.user, value: "www-data")
        profile.name = "Billing API"
        selection.edit(.name, value: "Billing API")
        profile = click(cache, &selection, profile)
        #expect(profile.identity == cache.identity)
        #expect(profile.user == "www-data")
        #expect(profile.name == "Billing API")
        // Untouched fields still follow.
        #expect(profile.workingDirectory == "/var/www/html")
        profile.user = nil
        selection.edit(.user, value: "")
        profile = click(app, &selection, profile)
        #expect(profile.user == "1000:1000")
        #expect(profile.name == "Billing API")
    }

    @Test func aChosenWorkingDirectoryAndLocalSourceAreKept() {
        var selection = newSelection()
        var profile = click(api, &selection, blank)
        profile.workingDirectory = "/var/www/current"
        selection.edit(.workingDirectory, value: profile.workingDirectory)
        profile.localSourcePath = "/Users/me/api"
        selection.edit(.localSource, value: profile.localSourcePath)
        profile = click(app, &selection, profile)
        #expect(profile.workingDirectory == "/var/www/current")
        #expect(profile.localSourcePath == "/Users/me/api")
    }

    @Test func theLocalSourceFollowsAnEditedWorkingDirectory() {
        var selection = newSelection()
        var profile = blank
        profile.workingDirectory = "/var/www/public"
        selection.edit(.workingDirectory, value: profile.workingDirectory)
        profile = click(api, &selection, profile)
        #expect(profile.workingDirectory == "/var/www/public")
        #expect(profile.localSourcePath == nil, "/src/api/public isn't a folder on this Mac")
    }

    @Test func aSavedProfileKeepsItsValues() {
        let saved = DockerProfile(name: "orders-api", identity: db.identity, workingDirectory: "/srv/orders", user: "deploy", localSourcePath: "/Users/me/orders")
        var selection = DockerContainerSelection(profile: saved, isNew: false)
        #expect(selection.userFields == Set(DockerContainerSelection.Field.allCases))
        let profile = click(api, &selection, saved)
        #expect(profile.identity == api.identity)
        #expect(profile.name == "orders-api")
        #expect(profile.user == "deploy")
        #expect(profile.workingDirectory == "/srv/orders")
        #expect(profile.localSourcePath == "/Users/me/orders")
    }

    @Test func aSavedProfileWithoutAUserTakesTheContainers() {
        let saved = DockerProfile(name: "orders-api", identity: db.identity, workingDirectory: "/srv/orders")
        var selection = DockerContainerSelection(profile: saved, isNew: false)
        let profile = click(app, &selection, saved)
        #expect(profile.user == "1000:1000")
        #expect(profile.workingDirectory == "/srv/orders")
        #expect(profile.localSourcePath == nil, "/srv/orders isn't mounted")
    }

    @Test func aDuplicateKeepsItsWorkingDirectory() {
        let copy = DockerProfile(name: "orders-api copy", identity: db.identity, workingDirectory: "/srv/orders")
        var selection = DockerContainerSelection(profile: copy, isNew: true)
        let profile = click(api, &selection, copy)
        #expect(profile.workingDirectory == "/srv/orders")
        #expect(profile.name == "orders-api copy")
    }

    @Test func listingsHighlightTheProfilesContainerAndNeverChangeIt() {
        // Opening a saved profile highlights its container; that row repeated back isn't a click.
        let saved = DockerProfile(name: "orders-api", identity: api.identity, workingDirectory: "/var/www")
        var selection = DockerContainerSelection(profile: saved, isNew: false)
        #expect(selection.highlighted == nil)
        selection.listed(all, profile: saved)
        #expect(selection.highlighted == "api1")
        #expect(!selection.needsApplying("api1", profile: saved, among: all))
        #expect(selection.needsApplying("db1", profile: saved, among: all))
        // A new profile has nothing to highlight.
        var fresh = newSelection()
        fresh.listed(all, profile: blank)
        #expect(fresh.highlighted == nil)
    }

    @Test func aRefreshBetweenClicksKeepsTheChoice() {
        var selection = newSelection()
        var profile = click(db, &selection, blank)
        selection.listed(all.reversed(), profile: profile)
        #expect(selection.highlighted == "db1")
        profile = click(app, &selection, profile)
        selection.listed(all, profile: profile)
        #expect(selection.highlighted == "app1")
        #expect(profile.identity == app.identity)
        // Recreated since the click: the same service, highlighted under its new ID.
        let recreated = container("app2", service: "app", user: "1000:1000", workingDir: "/app")
        selection.listed([db, cache, api, recreated], profile: profile)
        #expect(selection.highlighted == "app2")
        // Stopped: nothing highlighted, and the profile keeps its container.
        selection.listed([db, cache, api], profile: profile)
        #expect(selection.highlighted == nil)
        #expect(profile.identity == app.identity)
    }

    @Test func aRowHighlightedByARefreshIsAppliedWhenClicked() {
        // The highlight disagrees with the profile (it must not, but if it does): a click on
        // that row applies it, and the form can say so until then.
        var selection = newSelection()
        let profile = click(db, &selection, blank)
        selection.highlight("api1")
        #expect(!selection.disagrees(with: profile, among: all), "a click being applied isn't a disagreement")
        let other = DockerProfile(name: "x", identity: cache.identity, workingDirectory: "/")
        var stale = DockerContainerSelection(profile: other, isNew: true)
        stale.listed(all, profile: profile)
        #expect(stale.highlighted == "db1")
        #expect(stale.disagrees(with: other, among: all))
        #expect(stale.needsApplying("db1", profile: other, among: all))
        let applied = stale.click(db, in: other) { _ in false }
        #expect(applied.identity == db.identity)
        #expect(!stale.disagrees(with: applied, among: all))
    }

    @Test func aClickWaitingToBeAppliedSurvivesARefresh() {
        var selection = newSelection()
        var profile = click(db, &selection, blank)
        selection.highlight("app1")
        // The form skips listings while a click is being applied; once it is, the listing agrees.
        profile = selection.click(app, in: profile) { folders.contains($0) }
        selection.listed(all, profile: profile)
        #expect(selection.highlighted == "app1")
        #expect(profile.identity == app.identity)
    }

    @Test func replicasKeepTheClickedOne() {
        let first = container("w1", service: "worker", number: "1")
        let second = container("w2", service: "worker", number: "2")
        var selection = newSelection()
        let profile = selection.click(second, in: blank) { _ in false }
        selection.listed([first, second], profile: profile)
        #expect(selection.highlighted == "w2")
        #expect(profile.identity.lastContainerId == "w2")
    }

    @Test func aClickOnAFilteredListAppliesTheVisibleRow() {
        // The search filter only hides rows; a click on a row it shows applies that container,
        // and the listing (always of every container) keeps the choice when the filter clears.
        let visible = all.filter { matchesSearch("mem", in: $0.name, $0.image, $0.composeProject ?? "", $0.composeService ?? "") }
        #expect(visible.map(\.id) == ["mc1"])
        var selection = newSelection()
        let profile = click(visible[0], &selection, blank)
        #expect(profile.identity == cache.identity)
        #expect(profile.user == "memcache")
        selection.listed(all, profile: profile)
        #expect(selection.highlighted == "mc1")
    }

    @Test func anotherProfileUsingTheContainerIsAllowedAndNamed() {
        let mine = UUID()
        let api2 = DockerProfile(name: "lease-api docker", identity: api.identity, workingDirectory: "/var/www")
        let dbProfile = DockerProfile(name: "db", identity: db.identity, workingDirectory: "/")
        let byName = DockerProfile(name: "legacy", identity: ContainerIdentity(containerName: "legacy"), workingDirectory: "/")
        var selection = newSelection()
        let profile = click(api, &selection, blank)
        #expect(profile.identity == api.identity)
        let profiles = [api2, dbProfile, byName, DockerProfile(id: mine, name: "me", identity: api.identity, workingDirectory: "/")]
        #expect(DockerContainerSelection.profiles(sharing: profile.identity, in: profiles, except: mine).map(\.name) == ["lease-api docker"])
        #expect(DockerContainerSelection.profiles(sharing: ContainerIdentity(containerName: "legacy"), in: profiles, except: mine).map(\.name) == ["legacy"])
        #expect(DockerContainerSelection.profiles(sharing: ContainerIdentity(containerName: "shop-db-1"), in: profiles, except: mine).isEmpty,
                "a Compose profile isn't matched by name")
    }

    @Test func theSSHContainerStepIsChosenInOneProfile() {
        var profile = SSHProfile(name: "", host: "app.example.com", remoteDirectory: "", container: RemoteContainerStep())
        let chosen = profile.choosingContainer(app)
        #expect(chosen.container?.identity == app.identity)
        #expect(chosen.container?.workingDirectory == "/app")
        #expect(chosen.container?.user == "1000:1000")
        #expect(chosen.remoteDirectory == "/src/app")
        #expect(chosen.name == "app on app.example.com")
        // Values already set are kept; without a container step nothing changes.
        var set = chosen
        set.name = "Billing"
        set.container?.user = "deploy"
        let again = set.choosingContainer(api)
        #expect(again.container?.identity == api.identity)
        #expect(again.container?.user == "deploy")
        #expect(again.container?.workingDirectory == "/app")
        #expect(again.remoteDirectory == "/src/app")
        #expect(again.name == "Billing")
        profile.container = nil
        #expect(profile.choosingContainer(app) == profile)
    }
}

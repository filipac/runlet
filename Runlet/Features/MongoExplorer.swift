import RunletCore
import SwiftUI

struct MongoExplorer: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @Bindable private var state = MongoUI.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("MongoDB Collections", systemImage: "leaf.fill").font(.headline)
            Text(model.sqlConnectionChoice(for: tab).savedConnection?.name ?? "Application MongoDB").foregroundStyle(.secondary)
            HStack {
                Button("Load Collections") { model.mongoMetadata("listCollections", tab: tab) }
                Menu {
                    Button("List Databases") { model.mongoMetadata("listDatabases", tab: tab) }
                } label: { Image(systemName: "ellipsis.circle") }
            }.disabled(tab.isRunning)
            if let result = state.collections[model.mongoCacheKey(tab)] {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(result.rows.enumerated()), id: \.offset) { _, row in
                            let name = row.first?.text ?? ""
                            VStack(alignment: .leading, spacing: 5) {
                                Label(name, systemImage: "tray.full").fontWeight(.medium)
                                if row.count > 2 { Text("Estimated count: \(row[2].text)").font(.caption).foregroundStyle(.secondary) }
                                HStack {
                                    Button("Indexes") { model.mongoMetadata("getIndexes", collection: name, tab: tab) }
                                    Button("Sample Fields") { model.mongoMetadata("sampleSchema", collection: name, tab: tab) }
                                }.buttonStyle(.borderless).disabled(tab.isRunning)
                                Button("Open Find Query") {
                                    let data = try! JSONSerialization.data(withJSONObject: ["collection": name, "operation": "find", "filter": [:]], options: [.prettyPrinted, .sortedKeys])
                                    tab.replaceCode(String(decoding: data, as: UTF8.self))
                                }.buttonStyle(.borderless)
                            }
                            Divider()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Load collections on demand. Indexes and sampled field types appear in the output. Sampling reads up to 50 documents; production asks first.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(12).frame(maxHeight: .infinity, alignment: .top)
    }
}

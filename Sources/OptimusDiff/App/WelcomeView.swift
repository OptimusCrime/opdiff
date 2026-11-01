import DiffCore
import SwiftUI

struct WelcomeView: View {
    let model: CompareModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("OptimusDiff").font(.largeTitle.bold())
            Text("Review every change between two branches before you open a pull request.")
                .foregroundStyle(.secondary)
            Button("Open Repository…") { model.chooseRepository() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if !model.recentRepos.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent").font(.headline)
                    ForEach(model.recentRepos, id: \.self) { path in
                        Button {
                            Task { await model.openRepository(URL(fileURLWithPath: path)) }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent).fontWeight(.medium)
                                Text(path).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }
            Text("Tip: drop a folder here, or run `opdiff` inside a repository.")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import SwiftUI

struct RemoteImage: View {
    let url: URL?
    let title: String
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFit()
            case .failure:
                Label("Не удалось загрузить изображение", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary).padding(28)
            case .empty:
                if url == nil { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
                else { ProgressView().padding(28) }
            @unknown default: EmptyView()
            }
        }
        .accessibilityLabel(title.isEmpty ? Text("Изображение публикации") : Text(verbatim: title))
    }
}

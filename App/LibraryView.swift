import BoostyCore
import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State private var path: [Post] = []
    @State private var confirmLogout = false
    @State private var confirmDisconnect = false
    @FocusState private var focused: PostKey?
    @FocusState private var accountFocused: Bool
    private let columns = [GridItem(.adaptive(minimum: 410), spacing: 36)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 36) {
                        header
                        authors
                        if model.subscriptions.isEmpty, model.subscriptionError == nil {
                            Text("Подписок пока нет. Если вы ожидали увидеть авторов, проверьте, что вошли в нужный аккаунт.")
                                .foregroundStyle(.secondary).focusable()
                        }
                        if let notice = model.sessionNotice { ErrorBanner(message: notice) }
                        if let error = model.errorMessage, error != model.sessionNotice {
                            ErrorBanner(message: error)
                            Button("Повторить загрузку библиотеки") { Task { await model.loadLibrary() } }
                        }
                        if model.posts.isEmpty && !model.loading && model.feedError == nil {
                            ContentUnavailableView("Публикаций пока нет", systemImage: "rectangle.stack",
                                description: Text("Посты появятся здесь после публикации вашими авторами."))
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 44) {
                            ForEach(model.posts, id: \.key) { post in
                                NavigationLink(value: post) { PostCard(post: post, language: model.language) }
                                    .buttonStyle(.card)
                                    .disabled(post.blog.isEmpty)
                                    .focused($focused, equals: post.key)
                                    .id(post.key)
                                    .accessibilityIdentifier("post:\(post.blog):\(post.id)")
                            }
                        }
                        if model.loading { ProgressView().frame(maxWidth: .infinity).padding(30) }
                        if let error = model.feedError {
                            ErrorBanner(message: error)
                            Button("Повторить загрузку страницы") { Task { await model.retryFeed() } }
                                .accessibilityIdentifier("library-retry-page")
                        } else if model.hasMore {
                            Button("Загрузить ещё", systemImage: "arrow.down") {
                                Task { await model.loadFeed(blog: model.selectedBlog, more: true) }
                            }
                            .disabled(model.loading)
                            .accessibilityIdentifier("library-load-more")
                        }
                    }
                    .padding(.horizontal, 72).padding(.vertical, 45)
                }
                .onChange(of: focused) { _, value in
                    guard let value else { return }
                    model.focusedPost = value
                    if let post = model.posts.first(where: { $0.key == value }) {
                        Task { await model.loadMoreIfNeeded(near: post) }
                    }
                }
                .onChange(of: path.isEmpty) { _, isRoot in
                    if isRoot, let saved = model.focusedPost {
                        reader.scrollTo(saved, anchor: .center)
                        focused = saved
                    }
                }
                .navigationDestination(for: Post.self) { PostView(model: model, initialPost: $0) }
            }
            .navigationBarHidden(true)
        }
        .accessibilityIdentifier("library-root")
        .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Выйти из аккаунта", role: .destructive) { Task { await model.logout() } }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Отключиться от сервера?", isPresented: $confirmDisconnect) {
            Button("Отключиться", role: .destructive) { model.changeServer() }
                .accessibilityIdentifier("disconnect-confirm")
            Button("Отмена", role: .cancel) {}
                .accessibilityIdentifier("disconnect-cancel")
        } message: { Text("Вы вернётесь к выбору сервера. Приложение останется открытым.") }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Boosty").font(.system(size: 60, weight: .bold)).foregroundStyle(.orange)
                if let blog = model.selectedBlog {
                    Text(verbatim: model.subscriptions.first { $0.blog == blog }?.title ?? blog).font(.title3)
                } else { Text("Публикации ваших авторов").font(.title3).foregroundStyle(.secondary) }
            }
            Spacer()
            Menu {
                Button("Обновить") { Task { await model.loadLibrary() } }
                languageButtons
                Button("Отключиться от сервера", systemImage: "rectangle.portrait.and.arrow.right") {
                    confirmDisconnect = true
                }
                .accessibilityIdentifier("library-disconnect")
                Button("Выйти из аккаунта", role: .destructive) { confirmLogout = true }
                    .accessibilityIdentifier("library-logout")
            } label: {
                Label(model.profile?.name ?? "Boosty", systemImage: "person.crop.circle")
            }
            .accessibilityIdentifier("library-account")
            .focused($accountFocused)
        }
    }

    @ViewBuilder private var languageButtons: some View {
        ForEach(AppLanguage.allCases) { language in
            Button { model.language = language } label: {
                Label(language.title, systemImage: model.language == language ? "checkmark.circle.fill" : "globe")
            }
            .accessibilityIdentifier("language-\(language.rawValue)")
        }
    }

    private var authors: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Мои авторы").font(.title2)
            ScrollView(.horizontal) {
                HStack(spacing: 24) {
                    Button { Task { await model.loadFeed(blog: nil) } } label: {
                        Label("Все авторы", systemImage: model.selectedBlog == nil ? "checkmark.circle.fill" : "square.grid.2x2")
                    }
                    .accessibilityIdentifier("author:all")
                    ForEach(model.subscriptions) { subscription in
                        Button { Task { await model.loadFeed(blog: subscription.blog) } } label: {
                            HStack(spacing: 18) {
                                AsyncImage(url: subscription.avatar) { image in image.resizable().scaledToFill() }
                                    placeholder: { Image(systemName: "person.crop.circle.fill").resizable() }
                                    .frame(width: 68, height: 68).clipShape(Circle())
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(verbatim: subscription.title).font(.headline)
                                    Text(verbatim: subscription.name).font(.caption).foregroundStyle(.secondary)
                                }
                                if model.selectedBlog == subscription.blog { Image(systemName: "checkmark.circle.fill") }
                            }.frame(minWidth: 220, alignment: .leading)
                        }
                        .accessibilityIdentifier("author:\(subscription.blog)")
                    }
                }.padding(14)
            }
            .scrollClipDisabled()
            .onMoveCommand { direction in
                if direction == .up { accountFocused = true }
            }
        }
    }
}

private struct PostCard: View {
    let post: Post
    let language: AppLanguage
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: post.preview, title: post.title)
                    .frame(height: 230).frame(maxWidth: .infinity).clipped()
                if post.locked {
                    Label("По подписке", systemImage: "lock.fill")
                        .font(.caption).padding(12).background(.black.opacity(0.8), in: Capsule()).padding(12)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: post.author).font(.caption).foregroundStyle(.orange).lineLimit(1)
                Text(verbatim: post.title).font(.headline).lineLimit(2).frame(height: 65, alignment: .topLeading)
                Text(verbatim: language.date(post.publishedAt)).font(.caption2).foregroundStyle(.secondary)
                Text(verbatim: post.summary).font(.caption).lineLimit(3).frame(minHeight: 64, alignment: .topLeading)
                if let video = post.videos.first {
                    Label(AppLanguage.duration(video.duration), systemImage: "play.fill").font(.caption)
                } else { Label("Текст и изображения", systemImage: "doc.text.image").font(.caption) }
            }.padding(22)
        }
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

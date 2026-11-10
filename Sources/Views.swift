import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: VM

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let e = vm.err {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(e).font(.caption).lineLimit(3)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
            }
            list
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear { vm.refresh() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { vm.up() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(vm.path == "/" || vm.loading)

            Text(vm.path)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.secondary)

            Spacer()

            Text("连接").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $vm.threads) {
                Text("256").tag(256)
                Text("512").tag(512)
                Text("1024").tag(1024)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .disabled(vm.downloading)

            Button { vm.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(vm.loading)

            Button { vm.openDownloads() } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("打开下载目录")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(vm.items) { item in
                    FileRow(item: item)
                }
                if vm.items.isEmpty && !vm.loading {
                    Text("空目录")
                        .font(.callout).foregroundStyle(.tertiary)
                        .padding(.top, 40)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
        .overlay {
            if vm.loading { ProgressView().controlSize(.small).padding(6) }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vm.downloading {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                    Text(vm.currentName).font(.callout).lineLimit(1)
                    Spacer()
                    Button("取消") { vm.cancel() }.controlSize(.small)
                }
                ProgressView(value: vm.fraction).progressViewStyle(.linear)
                HStack {
                    Text("\(humanSize(vm.downloaded)) / \(humanSize(vm.total))")
                    Spacer()
                    Text(vm.speedText)
                    Text(vm.etaText)
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            } else if let f = vm.finishedName {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("已完成：\(f)").font(.callout).lineLimit(1)
                    Spacer()
                    Button("在 Finder 中显示") { vm.openDownloads() }.controlSize(.small)
                }
            } else {
                Text("单击文件夹进入 · 双击文件开始下载 · 默认 \(vm.threads) 连接（夸克按连接限速，约 10 KB/s/连接）")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct FileRow: View {
    let item: QItem
    @EnvironmentObject var vm: VM

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.dir ? "folder.fill" : "doc.fill")
                .foregroundStyle(item.dir ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if item.dir {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            } else {
                Text(humanSize(item.size))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("下载") { vm.download(item) }
                    .controlSize(.small)
                    .disabled(vm.downloading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.dir { vm.enter(item) } else { vm.download(item) }
        }
        .onTapGesture(count: 1) {
            if item.dir { vm.enter(item) }
        }
    }
}

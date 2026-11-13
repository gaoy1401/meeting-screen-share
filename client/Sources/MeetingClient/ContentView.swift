import MeetingWebRTC
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: MeetingModel
    @State private var showingScreenSharePicker = false

    var body: some View {
        VStack(spacing: 16) {
            connectionPanel

            HStack {
                Label("\(model.participantCount) 人在线", systemImage: "person.2.fill")
                Spacer()
                Text(model.status)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()

            HStack(spacing: 24) {
                Toggle(isOn: Binding(
                    get: { model.microphoneEnabled },
                    set: { model.setMicrophone($0) }
                )) {
                    Label("麦克风", systemImage: model.microphoneEnabled ? "mic.fill" : "mic.slash")
                }
                .toggleStyle(.switch)
                .disabled(!model.isConnected)

                Button {
                    if model.screenShareEnabled {
                        model.setScreenShare(false)
                    } else {
                        showingScreenSharePicker = true
                    }
                } label: {
                    Label(
                        model.screenShareEnabled ? "停止共享" : "选择共享内容",
                        systemImage: model.screenShareEnabled
                            ? "rectangle.slash"
                            : "rectangle.on.rectangle"
                    )
                }
                .disabled(!model.isConnected)
            }

            Group {
                if let track = model.remoteWebRTCVideo {
                    WebRTCVideoSurface(track)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else if let image = model.receivedScreen {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "display")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("等待屏幕共享")
                            .font(.headline)
                        Text("同房间成员开始共享后，画面会显示在这里。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(minHeight: 300)
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 600)
        .sheet(isPresented: $showingScreenSharePicker) {
            ScreenSharePicker(
                model: model,
                isPresented: $showingScreenSharePicker
            )
        }
    }

    private var connectionPanel: some View {
        HStack(alignment: .bottom, spacing: 12) {
            field("服务器", text: $model.serverAddress, width: 210)
            field("房间号", text: $model.roomID, width: 130)
            field("昵称", text: $model.displayName, width: 150)
            Button(model.isConnected ? "离开会议" : "加入会议") {
                model.connect()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .disabled(model.status.contains("正在加入") || model.status.contains("正在建立"))
    }

    private func field(_ title: String, text: Binding<String>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .disabled(model.isConnected)
        }
    }
}

private struct ScreenSharePicker: View {
    @ObservedObject var model: MeetingModel
    @Binding var isPresented: Bool

    private var displays: [WebRTCScreenShareSource] {
        model.screenShareSources.filter { $0.kind == .display }
    }

    private var windows: [WebRTCScreenShareSource] {
        model.screenShareSources.filter { $0.kind == .window }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("选择共享内容")
                .font(.title2.bold())

            if model.isLoadingScreenShareSources {
                HStack {
                    ProgressView()
                    Text("正在读取显示器和窗口…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        sourceSection("显示器", sources: displays)
                        sourceSection("窗口", sources: windows)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220, maxHeight: 360)
            }

            Divider()

            Toggle(
                "共享系统声音",
                isOn: $model.shareSystemAudioEnabled
            )
            Text("麦克风和系统声音是独立选项；系统声音会通过同一条 Opus 音轨发送。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("刷新列表") {
                    model.refreshScreenShareSources()
                }
                .disabled(model.isLoadingScreenShareSources)

                Spacer()

                Button("取消") {
                    isPresented = false
                }
                Button("开始共享") {
                    isPresented = false
                    model.setScreenShare(true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.selectedScreenShareSourceID == nil ||
                        model.isLoadingScreenShareSources
                )
            }
        }
        .padding(20)
        .frame(width: 560, height: 500)
        .onAppear {
            model.refreshScreenShareSources()
        }
    }

    @ViewBuilder
    private func sourceSection(
        _ title: String,
        sources: [WebRTCScreenShareSource]
    ) -> some View {
        if !sources.isEmpty {
            Text(title)
                .font(.headline)
            ForEach(sources) { source in
                Button {
                    model.selectedScreenShareSourceID = source.id
                } label: {
                    HStack(spacing: 10) {
                        Image(
                            systemName: model.selectedScreenShareSourceID == source.id
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .foregroundStyle(
                            model.selectedScreenShareSourceID == source.id
                                ? Color.accentColor
                                : Color.secondary
                        )
                        Image(
                            systemName: source.kind == .display
                                ? "display"
                                : "macwindow"
                        )
                        Text(source.name)
                            .lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
    }
}

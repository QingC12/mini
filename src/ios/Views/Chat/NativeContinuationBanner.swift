import SwiftUI

/// Non-owning recovery links: deleting the source never deletes its successor.
@MainActor
struct NativeContinuationBanner: View {
    let sessionID: String
    @ObservedObject private var coordinator = ContinuationCoordinator.shared

    var body: some View {
        if let record = coordinator.status(for: sessionID) {
            let isSource = record.sourceSessionID == sessionID
            let otherID = isSource ? record.destinationSessionID : record.sourceSessionID
            VStack(alignment: .leading, spacing: 6) {
                Label(isSource ? statusText(record) : "来自原会话的自动续接", systemImage: "arrow.triangle.branch")
                    .font(.caption.weight(.semibold))
                if let error = record.lastError, !error.isEmpty {
                    Text(error).font(.caption2).lineLimit(3).textSelection(.enabled)
                }
                HStack {
                    if let url = URL(string: "minis://sessions/" + otherID) {
                        Link(isSource ? "打开续接会话" : "查看原会话", destination: url)
                    }
                    Spacer()
                    if !record.state.isTerminal || record.state == .redirected {
                        Button("停止续接链", role: .destructive) {
                            coordinator.userStopped(sessionID)
                            if let vm = ViewModelCache.shared.get(for: sessionID), vm.isProcessing { vm.cancel() }
                        }
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.25)))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func statusText(_ record: ContinuationRecord) -> String {
        switch record.state {
        case .pending, .destinationCreated: return "服务商会话已满，正在准备续接"
        case .seedPersisted, .submitting: return "交接已保存，等待新会话真实响应"
        case .running: return "新会话已响应，任务正在续接"
        case .redirected: return "任务已转交后续会话"
        case .finished: return "续接运行已结束"
        case .paused: return "自动续接已暂停"
        case .failed: return "自动续接失败，已停止重试"
        }
    }
}

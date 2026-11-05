import SwiftUI

/// 根视图顶部的失败横幅（点击可立即关闭，4 秒后自动消失）。
struct SaveFailureBanner: View {
    @ObservedObject private var center = SaveFailureCenter.shared

    var body: some View {
        VStack {
            if let message = center.message {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message)
                        .lineLimit(2)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous)
                        .fill(Color.red.opacity(0.92))
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .onTapGesture { center.dismiss() }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.25), value: center.message)
        .allowsHitTesting(center.message != nil)
    }
}

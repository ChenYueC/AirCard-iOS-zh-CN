import SwiftUI

struct AirCardAboutView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        Image(systemName: "creditcard.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(.black)
                            .frame(width: 86, height: 86)
                            .background(Color.blue, in: Circle())
                        Text(AppL("AirCard")).font(.largeTitle.bold())
                        Text(AppL("在 iPhone 本机自定义 Apple 钱包卡面"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                            Text(AppL("版本 \(version)")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 12) {
                        Label(AppL("当前项目"), systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.headline)
                        Text(AppL("AirCard 简体中文版本，提供卡片管理、原始卡面备份与恢复，以及可编辑的卡面资源库。"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        repositoryLink("ChenYueC/AirCard-iOS-zh-CN", url: "https://github.com/ChenYueC/AirCard-iOS-zh-CN")
                    }
                    .aboutCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Label(AppL("上游项目"), systemImage: "arrow.triangle.branch")
                            .font(.headline)
                        Text(AppL("感谢上游作者及贡献者。本项目基于 Mak5er/AirCard-iOS 实现，在原项目的基础上新增或调整功能。"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        repositoryLink("Mak5er/AirCard-iOS", url: "https://github.com/Mak5er/AirCard-iOS")
                    }
                    .aboutCard()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    contentHeight = ceil(height)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(AppL("关于"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { AppLanguageMenu() }
                ToolbarItem(placement: .confirmationAction) { Button(AppL("完成")) { dismiss() }.fontWeight(.semibold) }
            }
        }
        // The detent excludes the bottom safe area; include the navigation bar and grabber space.
        .presentationDetents([.height(max(300, contentHeight + 60))])
    }

    private func repositoryLink(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                Text(AppL(title)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
            }
            .font(.subheadline)
            .padding(12)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private extension View {
    func aboutCard() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

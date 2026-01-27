import SwiftUI

public struct MurmurEmptyStateView: View {
    public var hintText: String?

    public init(hintText: String? = nil) {
        self.hintText = hintText
    }

    public var body: some View {
        VStack(spacing: contentSpacing) {
            Spacer()

            Image(systemName: MurmurTokens.Symbol.emptyState)
                .font(.system(size: MurmurTokens.Sizing.emptyIconSize))
                .foregroundStyle(MurmurTokens.accent.opacity(0.4))

            VStack(spacing: 6) {
                Text("No transcriptions yet")
                    .font(MurmurTokens.Typography.emptyTitle)
                    .foregroundStyle(.secondary)

                if let hint = hintText ?? defaultHint {
                    Text(LocalizedStringKey(hint))
                        .font(MurmurTokens.Typography.emptySubtitle)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(padding)
    }

    private var defaultHint: String? {
        #if os(macOS)
        return "Hold **Control-Space** or click Record"
        #elseif os(iOS)
        return "Tap the microphone to start"
        #elseif os(watchOS)
        return "Tap to record"
        #else
        return nil
        #endif
    }

    private var contentSpacing: CGFloat {
        #if os(watchOS)
        return 10
        #else
        return 16
        #endif
    }

    private var padding: CGFloat {
        #if os(watchOS)
        return 12
        #else
        return 24
        #endif
    }
}

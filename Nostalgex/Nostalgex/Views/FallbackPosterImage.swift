import SwiftUI

/// A poster that tries each URL in turn: the next one when a load fails, so a missing season poster falls to the
/// series poster, and that to the episode's frame (`PlexPosterChain`). It shows `placeholder` while a load is in
/// flight and `onAllFailed` only when every URL has failed.
struct FallbackPosterImage<Failed: View, Loading: View>: View {
    let urls: [URL]
    let size: CGSize
    let cornerRadius: CGFloat
    @ViewBuilder var loading: () -> Loading
    @ViewBuilder var onAllFailed: () -> Failed
    @State private var index = 0

    var body: some View {
        Group {
            if index < urls.count {
                AsyncImage(url: urls[index]) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                    .strokeBorder(Color.nxRestingOutline, lineWidth: 2)
                            )
                    case .failure:
                        // Not drawn: the next address is tried as soon as this one is on screen.
                        Color.clear.frame(width: size.width, height: size.height)
                            .onAppear { index += 1 }
                    default:
                        loading().frame(width: size.width, height: size.height)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    }
                }
            } else {
                onAllFailed()
            }
        }
        // A different item brings a different list: start again at the first.
        .id(urls.map(\.absoluteString))
        .onChange(of: urls) { _, _ in index = 0 }
    }
}

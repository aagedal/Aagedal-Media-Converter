// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Helper views and styles used by PreviewPlayerView.

import SwiftUI

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

extension LabelStyle where Self == TrailingIconLabelStyle {
    static var trailingIcon: TrailingIconLabelStyle { TrailingIconLabelStyle() }
}

struct CheckerboardBackground: View {
    private let squareSize: CGFloat = 24
    private let lightColor = Color.white.opacity(0.14)
    private let darkColor = Color.white.opacity(0.06)

    var body: some View {
        Canvas { context, size in
            guard squareSize > 0 else { return }

            let columns = Int(ceil(size.width / squareSize))
            let rows = Int(ceil(size.height / squareSize))

            for row in 0..<rows {
                for column in 0..<columns {
                    let origin = CGPoint(
                        x: CGFloat(column) * squareSize,
                        y: CGFloat(row) * squareSize
                    )
                    let rect = CGRect(
                        origin: origin,
                        size: CGSize(
                            width: min(squareSize, size.width - origin.x),
                            height: min(squareSize, size.height - origin.y)
                        )
                    )

                    let color = ((row + column).isMultiple(of: 2) ? lightColor : darkColor)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .background(Color.black)
    }
}

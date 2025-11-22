import SwiftUI

struct PlaybackSpeedIndicator: View {
    let speed: Float
    let isReversing: Bool
    
    var body: some View {
        if speed != 1.0 || isReversing {
            HStack(spacing: 4) {
                if isReversing {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 14, weight: .semibold))
                } else if speed > 1.0 {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14, weight: .semibold))
                } else if speed < 1.0 {
                    Image(systemName: "tortoise.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
                
                Text(isReversing ? "REV" : "\(formattedSpeed)×")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.75))
            )
            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
        }
    }
    
    private var formattedSpeed: String {
        if speed == floor(speed) {
            return String(format: "%.0f", speed)
        } else {
            return String(format: "%.1f", speed)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        PlaybackSpeedIndicator(speed: 0.5, isReversing: false)
        PlaybackSpeedIndicator(speed: 1.0, isReversing: false)
        PlaybackSpeedIndicator(speed: 1.5, isReversing: false)
        PlaybackSpeedIndicator(speed: 2.0, isReversing: false)
        PlaybackSpeedIndicator(speed: 1.0, isReversing: true)
    }
    .padding()
    .background(Color.gray.opacity(0.3))
}

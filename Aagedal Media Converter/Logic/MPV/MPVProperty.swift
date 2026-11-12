// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct MPVProperty {
    // Video parameters
    static let videoParamsColormatrix = "video-params/colormatrix"
    static let videoParamsColorlevels = "video-params/colorlevels"
    static let videoParamsPrimaries = "video-params/primaries"
    static let videoParamsGamma = "video-params/gamma"
    static let videoParamsSigPeak = "video-params/sig-peak"

    // Playback state
    static let duration = "duration"
    static let timePos = "time-pos"
    static let path = "path"
    static let pause = "pause"
    static let pausedForCache = "paused-for-cache"
    static let eofReached = "eof-reached"
    static let seekable = "seekable"
    static let speed = "speed"

    // Audio
    static let volume = "volume"
    /// Extra gain in dB on top of `volume`, used to preview an export volume.
    static let volumeGain = "volume-gain"
    static let mute = "mute"
    static let aid = "aid"
    static let trackListCount = "track-list/count"

    // Subtitles
    static let sid = "sid"
    static let subVisibility = "sub-visibility"
}

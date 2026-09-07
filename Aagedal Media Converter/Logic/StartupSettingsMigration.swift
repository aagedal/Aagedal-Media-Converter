import Foundation

/// One-time schema upgrades, injectable so migrations never need the user's store in tests.
struct StartupSettingsMigration {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// One-time migration: seed the multi-display selection (`captureDisplayIDs`) from the legacy
    /// single-display choice (`captureDisplayID`) so upgrading users keep their previously selected
    /// screen. A legacy value of 0 ("Automatic / Main") maps to an empty selection.
    func migrateCaptureDisplaySelection() {
        guard !defaults.bool(forKey: AppConstants.captureDisplayIDsMigratedKey) else { return }
        defer { defaults.set(true, forKey: AppConstants.captureDisplayIDsMigratedKey) }

        let legacyID = defaults.integer(forKey: AppConstants.captureDisplayIDKey)
        let existing = defaults.string(forKey: AppConstants.captureDisplayIDsKey) ?? ""
        if existing.isEmpty, legacyID != 0 {
            defaults.set(String(legacyID), forKey: AppConstants.captureDisplayIDsKey)
        }
    }

    /// One-time migration: consolidate 3 audio presets into unified Audio Only preset
    func migrateAudioPresets() {
        let migrationKey = "audioPresetMigrationV1"
        guard !defaults.bool(forKey: migrationKey) else { return }

        // Migrate default preset selection
        if let currentDefault = defaults.string(forKey: AppConstants.defaultPresetKey) {
            switch currentDefault {
            case "Audio only WAV (all channels)":
                defaults.set(ExportPreset.audioOnly.rawValue, forKey: AppConstants.defaultPresetKey)
                if defaults.object(forKey: AppConstants.audioOnlyFormatKey) == nil {
                    defaults.set(AudioOnlyFormat.wav.rawValue, forKey: AppConstants.audioOnlyFormatKey)
                }
            case "Audio only AAC (stereo downmix)":
                defaults.set(ExportPreset.audioOnly.rawValue, forKey: AppConstants.defaultPresetKey)
                if defaults.object(forKey: AppConstants.audioOnlyFormatKey) == nil {
                    defaults.set(AudioOnlyFormat.aac.rawValue, forKey: AppConstants.audioOnlyFormatKey)
                }
            case "Audio only MP4 (all tracks)":
                defaults.set(ExportPreset.audioOnly.rawValue, forKey: AppConstants.defaultPresetKey)
                if defaults.object(forKey: AppConstants.audioOnlyFormatKey) == nil {
                    defaults.set(AudioOnlyFormat.mp4.rawValue, forKey: AppConstants.audioOnlyFormatKey)
                }
            default:
                break
            }
        }

        // Migrate visibility: visible if any of the three old presets was visible
        let wavVisible = defaults.object(forKey: AppConstants.audioWAVVisibleKey) as? Bool ?? true
        let aacVisible = defaults.object(forKey: AppConstants.audioAACVisibleKey) as? Bool ?? true
        let mp4Visible = defaults.object(forKey: AppConstants.audioMP4VisibleKey) as? Bool ?? true
        if defaults.object(forKey: AppConstants.audioOnlyVisibleKey) == nil {
            defaults.set(wavVisible || aacVisible || mp4Visible, forKey: AppConstants.audioOnlyVisibleKey)
        }

        defaults.set(true, forKey: migrationKey)
    }

}

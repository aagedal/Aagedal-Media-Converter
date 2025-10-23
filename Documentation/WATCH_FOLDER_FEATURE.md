# Watch Folder Mode Feature

## Overview
This feature allows the app to automatically monitor a designated folder for new video files and add them to the conversion queue. When enabled, files are automatically encoded without manual intervention.

## Implementation Details

### Components Added

#### 1. WatchFolderManager (Logic/WatchFolderManager.swift)
- **Purpose**: Handles folder monitoring with file growth detection
- **Key Features**:
  - Scans watch folder every 5 seconds
  - Tracks file sizes to detect if files are still being written/copied
  - Only reports files as "ready" when size hasn't changed between two consecutive scans (10-second stability check)
  - Uses actor isolation for thread-safe file tracking

#### 2. UI Controls

**Toolbar Toggle (ContentView.swift)**
- Eye icon button in toolbar
- Disabled when no watch folder is configured
- Shows current folder path in tooltip
- State synchronized via `@AppStorage`

**Settings Panel (SettingsView.swift)**
- New "Watch Folder" section
- Folder selection with NSOpenPanel
- "Show in Finder" and "Clear" buttons
- Saves security-scoped bookmark for folder access
- Explanatory text about 5-second scanning interval

#### 3. AppStorage Keys (Utils/AppConstants.swift)
- `watchFolderModeKey`: Boolean for toggle state
- `watchFolderPathKey`: String for folder path

### Workflow

1. **Configuration**
   - User selects watch folder in Settings
   - Security-scoped bookmark is saved for sandboxed access

2. **Activation**
   - User clicks watch mode toggle in toolbar
   - `WatchFolderManager` starts monitoring
   - Folder is scanned every 5 seconds

3. **File Detection**
   - New files are tracked with their initial size
   - On next scan (5 seconds later), size is checked again
   - If size unchanged → file is stable and added to queue
   - If size changed → file is still growing, wait for next scan

4. **Auto-Encoding**
   - When new files are added to queue in watch mode:
     - 2-second delay is triggered
     - After delay, if not already converting and files are waiting:
       - Conversion automatically starts
   - This works for any file added to the queue (not just watch folder)

### File Growth Detection Strategy

**Why 10 seconds (two 5-second checks)?**
- More reliable than single check
- Handles various file copy/write speeds
- Prevents partial encodes of incomplete files
- First scan: Track file and its size
- Second scan: Compare size - if unchanged, file is complete

**Alternative approaches considered:**
- Single 5-second check: Too quick, might miss slow transfers
- File system events: Complex, platform-specific, requires additional entitlements
- Longer intervals: Unnecessary delay for most files

### Security & Sandboxing

- Uses `SecurityScopedBookmarkManager` for persistent folder access
- Bookmark saved when watch folder is selected
- Access requested before each scan
- Access released after each scan
- Works within macOS sandbox restrictions

### State Management

- Watch mode state persists across app launches via `@AppStorage`
- Watch folder path persists via `@AppStorage`
- Monitoring resumes automatically if enabled when app launches
- Two-way sync between Settings and ContentView (per existing pattern)

### Integration Points

- **ContentView**: Main UI, toolbar toggle, state management
- **SettingsView**: Configuration interface
- **WatchFolderManager**: Core monitoring logic
- **VideoFileUtils**: File validation and VideoItem creation
- **ConversionManager**: Auto-start encoding when files added

## User Experience

1. Open Settings (Cmd+,)
2. Select watch folder in "Watch Folder" section
3. Enable watch mode via toolbar toggle (eye icon)
4. Drop video files into watch folder
5. Files automatically appear in queue after 10 seconds
6. Encoding starts automatically after 2-second delay
7. Disable watch mode via toolbar toggle when done

## Testing Scenarios

1. **Basic Operation**
   - Select folder, enable watch mode, copy video file
   - Should appear in queue after ~10 seconds
   - Should start encoding after additional 2 seconds

2. **Large File Handling**
   - Copy large file that takes >10 seconds to transfer
   - Should not appear in queue until fully copied
   - File size tracking prevents premature adds

3. **Multiple Files**
   - Copy several files at once
   - All should be detected and queued
   - Encoding should process them sequentially

4. **Manual Override**
   - Add files manually while watch mode active
   - Should still trigger auto-encode
   - Watch folder continues monitoring

5. **State Persistence**
   - Enable watch mode, quit app, relaunch
   - Watch mode should resume automatically
   - Folder should still be monitored

6. **Error Handling**
   - Delete watch folder while monitoring
   - Should handle gracefully, log warning
   - Can disable and select new folder

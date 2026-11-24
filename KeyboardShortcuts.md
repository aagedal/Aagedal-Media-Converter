# Keyboard Shortcuts

In **Settings → Shortcuts**, customize shortcuts across the **Main Window**, **Trim View**, and **Fullscreen Player** separately. An on-screen keyboard labelled for your current keyboard layout shows what each key runs in each modifier layer (click or hold ⌘ ⌥ ⌃ ⇧). Each command can have up to two shortcuts: click a shortcut field to record, drag a command onto a key, or click a key to inspect and assign combinations in Key Details. Save custom layouts as named presets and share or import them as `.amckeys` files. Reserved macOS and built-in shortcuts are protected; clicking **Built-in Shortcuts…** lists the fixed shortcuts for sheets, overlays, and secondary windows.

On keyboard layouts that do not type Latin letters (such as Russian or Greek), and on French layouts for digits, letter and digit shortcuts also match the key at the corresponding U.S. position.

The list below shows the default bindings.


## Main Window

### File Operations
- Command + N: New encoding group
- Command + I: Open import dialogue
- Command + Shift + I: Import camera card
- Command + D: Show URL input overlay (for downloading)
- Command + P: Open preset quick-select overlay
- Option + F: Select output folder
- Option + W: Toggle watch folder (if no watch folder is selected you will be asked for one)

### Conversion
- Command + Return: Start/Stop Encoding
- Option + M: Toggle merging of clips (only available if all input files are in the same format)
- Command + 1-9, 0: Instantly select preset at that position (0 = 10th)

### Queue Navigation
- Tab: Select metadata comment text field of the first clip, or cycle to the next clip if a clip is already selected
- Shift + Tab: Select metadata comment text field of the last clip, or cycle to the previous clip if a clip is already selected
- Arrow Up/Down: Move between items
- Command + Up/Down: Move the selected item(s) up or down in the queue
- Option + D: Deselect all items
- Control + S: Cycle through sort modes

### Item Management
- Delete or Command + Delete: Remove selected items from the queue
- Command + R: Reset the conversion status of the selected items
- Command + Shift + R: Reset conversion status of all items in the queue
- Control + D: Toggle the metadata date tag on selected items
- Control + M: Toggle mute on selected items
- Command + U: Toggle upload on selected items
- Command + Option + U: Toggle source file upload on selected items
- Command + E: Toggle auto-encode on selected items (for download items)

### Other
- Command + ,: Open Settings
- Command + Shift + C: Open Capture Mode
- Control + R: Show new random tip
- Control + K: Open Shortcuts help (opens Settings to Shortcuts tab)


## Single Item Selected in Main Window

- Command + T or Return: Open trim view
- Command + F or Space: Open fullscreen player
- Option + T: Open Timecode override view
- Option + A: Open Audio Routing view
- Option + I: Open metadata view
- Option + C: Open Crop mode
- Command + Option + T: Toggle transcription on selected items
- Tab: Activate focus on the comment field


## Trim View

### Playback
- Space or K: Toggle play/pause
- J/K/L: Play backwards, play/pause, play forwards (like in most NLEs)
- Option + J / Option + L: Slow reverse / slow forward
- Command + L: Toggle loop mode (only available for the native AVPlayer for technical reasons)

### Navigation
- Arrow Left/Right: Go to previous/next frame
- Arrow Up/Down: Seek back/forward 10 frames
- I/O: Set in and out point
- Option + I / Option + O: Clear the in or out point
- Option + X: Clear both trim points
- Shift + I / Shift + O: Jump to the in or out point

### Timecode Input
- +/- before a number: Jump that many seconds back/forward when pressing Enter
- Any number: Activates timecode input, press Enter to jump to the entered timecode
- Full timecode input is also supported (hours:minutes:seconds:frames)

### Tools
- C: Enter crop tool
- T: Toggle timecode display mode
- Command + A: Toggle audio meter
- Command + S: Capture screenshot
- Command + F: Toggle fullscreen
- Escape: Close editor


## Fullscreen Player

### Playback
- Space or K: Toggle playback
- J: Start reverse playback simulation
- L: Fast forward
- Option + J / Option + L: Slow reverse / slow forward

### Navigation
- Left Arrow: Seek back 1 frame
- Right Arrow: Seek forward 1 frame
- Up Arrow: Seek back 10 frames
- Down Arrow: Seek forward 10 frames
- Command + B: Go to previous item in queue
- Command + N: Go to next item in queue

### Trim
- I/O: Set in and out point
- Option + I / Option + O: Clear the in or out point
- Option + X: Clear both trim points
- Shift + I / Shift + O: Jump to the in or out point

### Other
- A: Toggle Auto Next mode
- Command + L: Toggle Loop Queue (only available when Auto Next is enabled)
- T: Toggle timecode mode
- M: Toggle mute
- Command + Up/Down Arrow: Raise or lower the volume by 10%
- Number keys (0-9) or timecode characters (+, -, ., :, ;): Activate timecode input
- Command + S: Capture screenshot
- Escape: Close fullscreen player


## Metadata Window

- Command + F: Search fields and values
- Escape: Clear search


## Audio Routing View

- Control + M: Toggle mute audio
- Command + 1 through Command + 8: Toggle individual audio track (1-8)
- Command + Option + 1 through Command + Option + 9: Toggle stereo for individual output track position
- Command + Option + S: Toggle stereo for all surround tracks


## Timecode Configuration View

- Command + 1: Switch to Preserve Source mode
- Command + 2: Switch to Manual mode
- Command + 3: Switch to Disabled mode
- Number keys (0-9): Start typing in manual mode / activate manual input


## Settings Window

- Command + F: Focus Settings search
- Control + 1: General
- Control + 2: Metadata
- Control + 3: Presets
- Control + 4: Screen Capture
- Control + 5: Waveform
- Control + 6: Watch Folder
- Control + 7: Downloads
- Control + 8: Upload
- Control + 9: Transcription
- Control + 0: Analytics
- Control + A: Updates
- Control + K: Shortcuts (also works from main window)


## Any Overlay View

- Escape: Close the overlay (settings are automatically saved)


## URL Input Overlay

- Down Arrow: Navigate into download history (older entries)
- Up Arrow: Navigate back (newer entries or original text)
- Return: Submit URL and start download
- Escape: Close URL input overlay


## Preset Quick-Select Overlay

- Arrow Up/Down: Navigate through presets
- Enter: Confirm selection
- Command + 1-9, 0: Instantly select preset at that position (0 = 10th)
- Escape: Close without changing


## Capture Mode

- Escape or Command + .: Close/Cancel capture mode


## Crop Mode

- Command + 1: Free aspect ratio
- Command + 2–9: 21:9, 16:9, 3:2, 4:3, 1:1, 3:4, 2:3 and 9:16 aspect ratios
- Command + 0: Reset crop
- Command + + / Command + -: Scale the crop box larger or smaller
- Command + Arrow keys: Move the crop box
- Hold Shift before dragging: Keep the crop box's shape


## Trim Timeline Modifiers

The drag mode is chosen when you press the mouse button:
- Hold Command: Range selection — click and drag to set in and out points
- Hold Shift: Range sliding — drag to move the whole trim range, keeping its length
- Hold Option: Symmetric scaling — drag a handle to move both handles symmetrically

# Manual Playback meter sync check

Software tests compare the Playback meter with MPV's own playback clock. They
cannot see when sound leaves a speaker or a frame reaches a display. This check
does, by eye and ear, in about ten minutes. Run it on each output you care about
(built-in speakers, wired headphones, Bluetooth, an external interface).

## Make the test file

```sh
ffmpeg -f lavfi -i "testsrc2=size=1280x720:rate=25:duration=60" \
  -f lavfi -i "aevalsrc='if(lt(mod(t,2),0.05),0.5*sin(2*PI*1000*t),0)':s=48000:d=60:c=stereo" \
  -vf "drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='lt(mod(t,2),0.04)'" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 192k sync-check.mp4
```

Every two seconds the picture flashes white for one frame and a 50 ms beep plays
at about −6 dBFS; the rest is silence. The flash and the beep start at the same media
time.

## Steps

1. Add `sync-check.mp4` to the queue and open Preview / Trim. Turn the volume up
   to a comfortable level; the meter reads levels before volume, so this does not
   change the readings.
2. Open the audio meter and choose **Playback β**.
3. Play from the start and watch the flash, the meter and the sound together for
   at least ten beeps.
4. Pause, seek to about 30 s, and play again. Repeat once at 2× speed (L twice).
5. Switch the Mac's output device while playing (or connect Bluetooth headphones)
   and watch ten more beeps.

## What to look for

- **Pass:** each meter jump arrives with the beep you hear, never before it. Up to
  about 0.1–0.2 s after the beep is expected (the meter refreshes ten times a
  second and shows a reading once the playhead passes it).
- **Fail:** the meter jumps clearly before you hear the beep, or more than about
  half a second after it.
- With Bluetooth, the sound may come late compared with the *picture*; that is
  the device's latency. The meter should still follow the sound and the
  playhead, not the picture alone. Note how far apart they are.
- After a pause, seek or speed change the LUFS values show "—" until enough audio
  has played (0.4 s momentary, 3 s short-term). That is expected.

For comparison, choose **Source**: it follows the playhead the same way but
measures the file directly.

## Optional: measure it

Record the speaker and the screen with a phone at 240 fps (slow motion) with the
meter in frame. Step through the video and count frames from the beep's first
waveform onset (in an editor such as Audacity, after extracting the audio) to the
meter's first change. At 240 fps one frame is about 4 ms.

Note the Mac model, macOS version, output device and result for each run in
`docs/AUDIO-METERING-PLAN.md`.

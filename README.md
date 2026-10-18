# Visualizer

A music visualizer for the Mac that listens to whatever your Mac is playing (Music, Spotify, YouTube in a browser, anything) and turns it into flowing light.

It starts from what makes MilkDrop great (each frame smears into the next, so motion leaves glowing trails) and adds:

- **Hears every app** directly through macOS's own audio capture (macOS 14.2 or later). No extra audio drivers.
- **Locks onto the beat.** It works out the song's tempo and keeps time, so pulses land on the kick instead of just following loudness.
- **Changes with the song.** Scenes blend into each other on drops and every 16 beats, not on a random timer.
- **Curated colors.** Every scene uses one two- or three-tone palette (Ember, Deep Sea, Glacier, Aurora, Gilded Night, Rose Gold, Moonlight); old light is gently kept inside the palette so trails never go muddy.
- **Clean HDR rendering** with real glow and tone mapping.

## Install

1. Download [Visualizer.zip](https://github.com/RichardNasty/Visualizer/releases/download/current/Visualizer.zip) and unzip it.
2. Drag **Visualizer** into Applications.
3. The first time, right-click it and choose **Open**, then **Open** again (it isn't from the App Store).
4. When macOS asks, allow Visualizer to record system audio. If you said no, use **Sound › Allow Listening…** in the menu bar.

## Controls

| Key | Does |
| --- | --- |
| → or Space | Next scene |
| ← | Previous scene |
| P | Next colors |
| L | Stay on this scene (stop automatic changes) |
| ⌘F or double-click | Full screen |
| Esc | Leave full screen |

**Sound** in the menu bar picks where your Mac plays (speakers, AirPlay, Bluetooth); the visualizer follows along.

## Scenes

Nebula, Tunnel, Liquid, Vortex, Kaleidoscope and Shockwave.

## Building

Every push to `main` builds the app on GitHub Actions (macOS 15), runs `Visualizer --selftest` (silence, tempo and beat-timing checks on synthetic tracks, then GPU renders of every scene) and publishes the `current` release with `Visualizer.zip` and preview stills.

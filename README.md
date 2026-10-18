# Visualizer

A Mac music visualizer that listens to whatever your Mac is playing (Spotify, Apple Music, YouTube, games, anything) and turns each song into a hidden story told only with glowing lines (one for every musical note), particles and a waveform.

## Install

1. Download **[Visualizer.zip](../../releases/latest/download/Visualizer.zip)** and double-click it to unzip.
2. Drag **Visualizer** into your **Applications** folder.
3. Open it. The first time, macOS will say it can't check the app for malware, because it isn't from the App Store. Click **Done**, then open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to Visualizer.
4. Allow the requests that pop up:
   - **System Audio Recording**: lets it hear your Mac's sound. If you miss this, turn Visualizer on under **Privacy & Security › Screen & System Audio Recording**.
   - **Music / Spotify / Safari / Chrome**: lets it ask which song is playing so it can find the lyrics.

Needs macOS 14.2 or newer.

## Using it

- Play music in any app. The visuals follow the beat right away.
- Every musical note from low C to high B has its own line. A line lights up and ripples while its note is playing, and the last few seconds scroll along it, so you can watch melodies and chords move. Notes are grouped by color, one color family per octave: bass notes red, then orange, yellow, green and blue up to violet for the highest notes. Under **Visualizer › Settings** you can group them by note name instead (every C one color, every D another).
- When the app knows the song (from Music, Spotify, a YouTube tab, or by listening), it looks up the lyrics and stages a story for it. The story moves the lines and the particle clouds: they gather close, split apart, rise, fall or shatter with the lyrics, line by line, and every lyric line sends a pulse of light along them.
- **Sound output** (speaker button): send the sound to your speakers, Bluetooth headphones or AirPlay speakers.
- **AirPlay button**: Apple's AirPlay and Bluetooth picker.
- **Show on a TV**: use AirPlay screen mirroring from Control Center, then click the full-screen button.

## AI stories (optional)

Out of the box, a built-in reader turns the lyrics into a story for free. For richer stories written by Claude, add an API key under **Visualizer › Settings**. You can get a key at [console.anthropic.com](https://console.anthropic.com/settings/keys). Each new song costs a few cents, and stories are saved, so replaying a song costs nothing.

## For developers

```sh
./scripts/build-app.sh                                   # builds build/Visualizer.app
./build/Visualizer.app/Contents/MacOS/Visualizer --selftest
```

Every push to `main` is built on GitHub Actions and published as the `latest` release.

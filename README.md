# Visualizer

A Mac music visualizer that listens to whatever your Mac is playing (Spotify, Apple Music, YouTube, games, anything) and turns each song into a hidden story told only with particles, glowing 3D shapes and a waveform.

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
- When the app knows the song (from Music, Spotify, a YouTube tab, or by listening), it looks up the lyrics and stages a story for it. The characters are the shapes, and how they move, meet, drift apart, rise or shatter follows the lyrics line by line.
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

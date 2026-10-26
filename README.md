# yap

Dictation for the Mac (and now the iPhone), built for talking to Claude Code. Hold **Right Command**, talk, let go: Yap transcribes it, on the Mac or with OpenAI, and types the text into whichever app was in front.

- **Hold** Right Command to talk; release to send.
- **Tap** it (under 0.3 s) to record hands free, then tap again to send. A *Tink* starts it and a *Pop* ends it. It sends on its own after 10 minutes.
- Using Right Command for a shortcut (⌘Tab and so on) cancels the dictation, so shortcuts still work.
- The key is configurable: see [Key](#key).
- Clips that are too short or silent are dropped. Transcription models make up words for silence.

Split out of Hob, a voice assistant that was doing too much.

## Setup

```sh
brew install xcodegen   # once
make run                # build, install to /Applications/Yap.app, launch
```

Building it yourself? `project.yml` signs with my Apple team (`DEVELOPMENT_TEAM`). Change it to yours. It has to be a real certificate, not ad-hoc: macOS ties the Accessibility and Microphone grants to the signature, so an ad-hoc build asks for them again after every rebuild.

Grant Accessibility (to hear the key and type) and Microphone when asked. The menu bar icon's menu tells you if Accessibility is missing.

To use OpenAI (optional; see [On the Mac, or OpenAI](#on-the-mac-or-openai)), put a key in `~/Library/Application Support/yap/secrets.env` (mode 600):

```
OPENAI_API_KEY=sk-...
```

`OPENAI_API_KEY` in the environment wins over the file. The file is read on every clip, so a new key needs no relaunch.

## Dictionary

`~/Library/Application Support/yap/dictionary.txt` (**Edit dictionary** in the menu). It's read on every clip.

```
# A line on its own is a term, sent to the model as vocabulary.
lane
autoblog
# "heard => written" replaces a mishearing afterwards (whole word, any case).
auto blog => autoblog
```

**Only the first 25 terms are sent.** More vocabulary measured worse, not better: twelve hard words came back right 18/24 times with the top 15–25 terms, 16/24 with 80, 14/24 with all 153, and 6/24 with none. Keep the list short and ranked, and use fixes for the long tail.

## Overlay

While you talk, a panel at the bottom of the screen shows a waveform and what Yap has heard so far. At each pause, the last phrase is transcribed and added to it. On send, the whole clip is transcribed again and replaces the preview, and that version is what gets typed. The preview is only for watching, so a chunk that fails costs nothing. The panel never takes focus or clicks, so typing still goes to the app you were in.

With OpenAI, the chunks roughly double the audio sent. On the Mac, the preview comes from the same live transcription that gets typed, and costs nothing. Set `"overlay": false` in `config.json` to turn it off.

## On the Mac, or OpenAI

**Transcribe With** in the menu picks the engine (`"engine"` in `config.json`: `onDevice` or `openAI`):

- **This Mac**: Apple's speech model (SpeechAnalyzer), with no key and no network. Yap downloads the model for your language the first time; the menu says while it is downloading. It transcribes while you talk, so the text is ready a fraction of a second after you let go. **Clean Up with Apple Intelligence** then fixes punctuation, filler words and false starts, with the same guards as the iPhone (see [On device, or OpenAI](#on-device-or-openai)). It needs Apple Intelligence on, and adds a second or so.
- **OpenAI**: better with jargon, billed to your key.

Either falls back to the other when it fails, and the status line says so.

## Transcripts

Every transcript is saved before Yap tries to type it, so a focus change or an app that won't come forward can't lose it. If typing fails you hear the error sound, and the menu says where to find it.

- **Copy Last Transcript** copies the newest one.
- **Recent Transcripts** lists the last five; click one to copy it. ⚠︎ marks one that never reached its app. **Open Transcripts Folder** is at the bottom.
- **Keep Transcripts** saves them to `~/Library/Application Support/yap/transcripts/`, one `YYYY-MM-DD.jsonl` file per day, and deletes days older than the retention period (30 by default). With it off, only the last five are kept, in memory, until you quit.

## Settings

The menu has checkboxes for **Dictate with *key***, **Press Return After Dictating** (off, so you can review the text before sending) and **Keep Transcripts**. **Edit Settings…** opens `~/Library/Application Support/yap/config.json`, which you can edit by hand. Any setting you leave out uses its default. Yap notices a saved edit within two seconds, without a relaunch:

```json
{
  "key": "rightCommand",
  "keepTranscripts": true,
  "overlay": true,
  "retentionDays": 30
}
```

### Key

`key` is the key you hold or tap. It can be:

- **A modifier on its own:** `rightCommand` (the default), `leftCommand`, `rightOption`, `leftOption`, `rightControl`, `leftControl`, `rightShift`, `leftShift` or `fn`. Holding one does nothing else, and using it in a shortcut cancels the dictation.
- **A function key:** `f1` to `f20`. Yap only listens, so the key still reaches the app in front. Pick one that does nothing there, such as F13 to F20 on a full-size keyboard.
- **Any key by its code:** `keycode:105`.

Case, spaces and dashes don't matter (`"Right Option"` works), and the usual short forms (`rcmd`, `ralt`, `rctrl`) do too. If Yap doesn't recognize the name, it keeps the last key and says so in the menu.

The model defaults to `gpt-transcribe`. To change it:

```sh
defaults write dev.yap.Yap model gpt-4o-transcribe
```

## iPhone

`iOS/` is an iPhone app with a Yap keyboard. Tap the microphone key, talk, tap ✓, and the transcript goes in wherever you were typing. The app holds the dictionary and the settings.

iOS gives keyboards no microphone, so the keyboard doesn't record. The app does, and the two talk over Darwin notifications and files in a shared app group (`Core/Bridge.swift`):

1. The first tap opens the app (`yap://dictate`). It starts an audio session and starts recording. iOS only lets an app start recording from the foreground.
2. Go back with **◀** in the top-left corner. iOS has no way to send you back on its own.
3. The session stays up in the background (15 minutes by default; set it under Session Length). Until it ends, the mic key starts and stops recording without leaving the keyboard. While a session is up, iOS shows the microphone indicator.
4. On ✓ the app transcribes the clip, applies the dictionary, and leaves the result for the keyboard. The keyboard claims it at most once and types it. A result left unclaimed for two minutes is dropped. It is still in Recent in the app.

Setup on the phone: install Yap, then turn it on under **Settings › Apps › Yap › Keyboards**, with **Allow Full Access**. Without Full Access the keyboard can't reach the app group.

### On device, or OpenAI

By default the iPhone transcribes on the phone with Apple's speech model, which needs no key and keeps the audio on the phone. The app downloads the model the first time it opens. Then Apple Intelligence cleans up the text: punctuation, filler words, false starts, and "no wait, I mean…" corrections. Clean-up can only improve a transcript or leave it alone:

- A rewrite that adds words that weren't said is thrown away. A small model asked to tidy "what's the capital of France?" is tempted to answer it (`Refiner.accepts`).
- So is one that drops more than half of what was said.
- Any failure gives back the text as heard.

With the dictionary's terms, Yap uses the system dictation model (`DictationTranscriber`), because it is the one that listens for expected words. On synthetic speech it got autoblog, Tailscale, next-cloud, Parade and Coolify right with the terms and wrong without, while `SpeechTranscriber` ignored them. Its own punctuation is sparse, and the clean-up fills that in.

An OpenAI key is optional. With one you can choose OpenAI under **Transcribe With**: it is better with jargon, and it is billed to your account. Either engine falls back to the other when it fails, and the app says when that happened. The key stays in the app's Keychain, where the keyboard can't read it.

Limits:

- The keyboard is only a mic, space, delete and return. Use the globe to switch to a full keyboard. App Review (4.4.1) expects a keyboard to type, so this works in TestFlight but may need letter keys before the App Store.
- The keyboard opens the app through the responder chain, which iOS doesn't officially offer to keyboards. If a future iOS breaks this, the keyboard says to open Yap by hand.
- Recording uses the phone's own mic, not a Bluetooth headset's. Switching to a headset mic drops the audio to call quality and pauses music.

```sh
make ios          # build for the simulator
make testflight   # archive and upload; needs your account in Xcode › Settings › Accounts
```

## Layout

| Path | What |
|---|---|
| `App` | The menu bar app: the hotkey, mic capture, typing into other apps. |
| `iOS/App`, `iOS/Keyboard` | The iPhone app and its keyboard extension. They share `AudioCapture` and `PCMRecorder` with the Mac app. |
| `Packages/Core` | Pure Swift, unit-tested: the OpenAI request, WAV encoding, the dictionary, key lookup, and the app–keyboard bridge. |
| `project.yml` | XcodeGen spec. Run `make generate` before opening the project in Xcode. |

`make test` runs the Core tests.

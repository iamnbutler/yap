# yap

Dictation for the Mac, built for talking to Claude Code. Hold **Right Command**, talk, let go: OpenAI transcribes it and Yap types the text into whichever app was in front.

- **Hold** Right Command to talk; release to send.
- **Tap** it (under 0.3 s) to record hands free, then tap again to send. A *Tink* starts it and a *Pop* ends it. It sends on its own after 10 minutes.
- Using Right Command for a shortcut (⌘Tab and so on) cancels the dictation, so shortcuts still work.
- The key is configurable: see [Key](#key).
- Clips that are too short or silent are dropped. Transcription models make up words for silence.

Split out of [Hob](https://github.com/iamnbutler/hob), which was doing too much.

## Setup

```sh
brew install xcodegen   # once
make run                # build, install to /Applications/Yap.app, launch
```

Grant Accessibility (to hear the key and type) and Microphone when asked. The menu bar icon's menu tells you if Accessibility is missing.

Put an OpenAI key in `~/Library/Application Support/yap/secrets.env` (mode 600):

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

The chunks roughly double the audio sent to OpenAI. Set `"overlay": false` in `config.json` to turn it off.

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

## Layout

| Path | What |
|---|---|
| `App` | The menu bar app: the hotkey, mic capture, typing into other apps. |
| `Packages/Core` | Pure Swift, unit-tested: the OpenAI request, WAV encoding, the dictionary, key lookup. |
| `project.yml` | XcodeGen spec. Run `make generate` before opening the project in Xcode. |

`make test` runs the Core tests.

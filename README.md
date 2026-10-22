# yap

Dictation for the Mac, built for talking to Claude Code. Hold **Right Command**, talk, let go: OpenAI transcribes it and Yap types the text into whichever app was in front.

- **Hold** Right Command to talk; release to send.
- **Tap** it (under 0.3 s) to record hands free, then tap again to send. A *Tink* starts it and a *Pop* ends it. It sends on its own after 10 minutes.
- Using Right Command for a shortcut (⌘Tab and so on) cancels the dictation, so shortcuts still work.
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

## Settings

The menu has two checkboxes: **Dictate with Right Command** and **Press Return after dictating** (off, so you can review the text before sending). The model defaults to `gpt-transcribe`. To change it:

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

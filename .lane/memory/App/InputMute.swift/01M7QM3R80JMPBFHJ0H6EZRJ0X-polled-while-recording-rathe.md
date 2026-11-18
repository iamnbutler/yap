---
id: 01M7QM3R80JMPBFHJ0H6EZRJ0X
anchor: InputMute
created: 2026-11-18T15:23:54Z
norm: '1'
---

Polled while recording rather than kept current with property listeners: the default device can change mid-session, and a 200 ms read of a few properties costs nothing. AVAudioApplication input mute and AUVoiceIO muted-speech don't apply: Yap sets neither and doesn't use voice processing.

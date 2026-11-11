`providers.pcm` is a short synthetic English voice fixture naming OpenAI,
AssemblyAI and ElevenLabs, generated for the shared-vocabulary integration work.
It contains no user recording. Format: 16 kHz mono signed PCM16, little endian.

`speaker-owner.wav`, `speaker-other.wav` and `speaker-reference.json` are synthetic speaker-recognition fixtures from [SpeechKit](https://github.com/emileberhard/SpeechKit). They verify the real bundled model and the app capture/filter boundary without microphone input or playback.

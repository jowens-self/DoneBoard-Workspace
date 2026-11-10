# Sounds

Empty on purpose. Drop audio in here and each file becomes an option in Settings →
Celebration → Sound, on both platforms, with no code change: the picker is built from
whatever this folder contains at build time.

`.caf` is the safest format — `AudioServices` on iOS is fussy, and 16-bit PCM CAF is what it
wants. `.aiff`, `.wav`, `.m4a` and `.mp3` are also tried. To convert something:

```
afconvert -f caff -d LEI16@44100 whatever.wav Resources/Sounds/Whatever.caf
```

The file's name is the name shown in the picker, so call it what you want to see.

With this folder empty the app falls back to the platform's own celebratory alert, which is
*referenced* rather than shipped — nothing of Apple's travels in this repository.

#!/usr/bin/env python3
import math
from pathlib import Path
import struct
import wave


def main():
    sample_rate = 44_100
    duration = 0.65
    samples = bytearray()
    for index in range(round(sample_rate * duration)):
        t = index / sample_rate
        envelope = min(t / 0.003, 1) * math.exp(-10 * t)
        tail = max(0, 1 - (t / duration) ** 4)
        tone = sum(amplitude * math.sin(2 * math.pi * frequency * t)
                   for frequency, amplitude in [(1568, 0.40), (2352, 0.18), (3136, 0.08)])
        samples.extend(struct.pack('<h', round(32767 * envelope * tail * tone)))
    path = Path(__file__).resolve().parent.parent / 'RemoteCoder/Resources/remote-coder-notification.wav'
    with wave.open(str(path), 'wb') as sound:
        sound.setnchannels(1)
        sound.setsampwidth(2)
        sound.setframerate(sample_rate)
        sound.writeframes(samples)


if __name__ == '__main__':
    main()

import wave, struct, sys, glob
# For each s*.wav: find end of speech (last 10ms frame with RMS above 3% of peak), write
#  full  = speech + 500ms silence (user held key well past the word)
#  atend = cut exactly at end of speech (release right on the last phoneme)
#  early = cut 150ms before end of speech (release as the word finishes + lost in-flight buffer)
for f in sorted(glob.glob('s[0-9].wav')):
    w = wave.open(f); n = w.getnframes(); sr = w.getframerate(); d = w.readframes(n); w.close()
    x = struct.unpack('<%dh' % n, d)
    fr = sr // 100
    rms = [ (sum(v*v for v in x[i:i+fr]) / fr) ** .5 for i in range(0, n - fr, fr)]
    peak = max(rms); last = max(i for i, r in enumerate(rms) if r > .03 * peak)
    end = (last + 1) * fr
    def out(name, samples):
        o = wave.open(f.replace('.wav', '-%s.wav' % name), 'w'); o.setnchannels(1); o.setsampwidth(2); o.setframerate(sr)
        o.writeframes(struct.pack('<%dh' % len(samples), *samples)); o.close()
    out('full', list(x[:end]) + [0] * (sr // 2))
    out('atend', x[:end])
    out('early', x[:max(0, end - int(.15 * sr))])
    out('cut300', x[:max(0, end - int(.30 * sr))])
    out('cut450', x[:max(0, end - int(.45 * sr))])
    # After the fix: same release points, capture continues 500 ms past them.
    padded = list(x) + [0] * sr
    out('tail300', padded[:end - int(.30 * sr) + sr // 2])
    out('tail450', padded[:end - int(.45 * sr) + sr // 2])
    print(f, 'speech ends at %.2fs' % (end / sr))

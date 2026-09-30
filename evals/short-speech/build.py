# Builds what the app sends for a short dictation:
# 0.30 s pre-roll room noise | start tone picked up by the mic at t=0.30 | word from t=0.75 | 0.50 s tail.
import wave, struct, glob, random, json
def rd(f):
    w=wave.open(f); x=struct.unpack('<%dh'%w.getnframes(), w.readframes(w.getnframes())); w.close(); return [v/32768 for v in x]
def trim(x):
    fr=160; rms=[(sum(v*v for v in x[i:i+fr])/fr)**.5 for i in range(0,len(x)-fr,fr)]; pk=max(rms)
    idx=[i for i,r in enumerate(rms) if r>.03*pk]; return x[idx[0]*fr:(idx[-1]+1)*fr]
tone=rd('tone.wav'); tp=max(abs(v) for v in tone)
random.seed(1); out={}
for f in sorted(glob.glob('w*.wav'), key=lambda s:int(s[1:-4])):
    word=trim(rd(f)); wp=max(abs(v) for v in word)
    for level,peak in (('normal',.30),('quiet',.06),('soft',.03),('whisper',.015)):
        for tg in (0,.05):
            n=int(16000*(0.75+len(word)/16000+0.5))
            buf=[random.uniform(-1,1)*0.0015*3**.5 for _ in range(n)]
            for i,v in enumerate(tone): buf[int(.30*16000)+i]+=v/tp*tg if int(.30*16000)+i<n else 0
            for i,v in enumerate(word): buf[int(.75*16000)+i]+=v/wp*peak
            name='%s-%s-tone%s'%(f[:-4],level,'on' if tg else 'off')
            open(name+'.f32','wb').write(struct.pack('<%df'%n,*buf)); out[name]=round(len(word)/16000,2)
json.dump(out,open('words.json','w'),indent=0); print(len(out),'buffers; word lengths s:',sorted(set(out.values())))

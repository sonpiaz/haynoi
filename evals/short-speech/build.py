# Buffers shaped like a short dictation, as the gate sees them.
# Positives: 0.30 s pre-roll room noise | tone as the mic hears it at 0.30 s (off, or 0.05) |
#            word at 0.55 or 0.75 s, peak normal .30 / quiet .06 / soft .03 / whisper .015 | 0.50 s tail.
# Negatives (average < 0.005, so the whole-buffer shortcut does not decide): tone alone at three
#            levels, on time / 200 ms / 450 ms late; a 0.18 s burst then the tone; a thump; clicks; fan; room.
import wave, struct, glob, random
def rd(f):
    w=wave.open(f); x=struct.unpack('<%dh'%w.getnframes(), w.readframes(w.getnframes())); w.close(); return [v/32768 for v in x]
def trim(x):
    fr=160; rms=[(sum(v*v for v in x[i:i+fr])/fr)**.5 for i in range(0,len(x)-fr,fr)]; pk=max(rms)
    idx=[i for i,r in enumerate(rms) if r>.03*pk]; return x[idx[0]*fr:(idx[-1]+1)*fr]
tone=rd('tone.wav'); tp=max(abs(v) for v in tone); R=16000
random.seed(1)
def base(sec, rms=0.0015): return [random.uniform(-1,1)*rms*3**.5 for _ in range(int(R*sec))]
def add(buf, sig, at, gain):
    s=int(at*R)
    for i,v in enumerate(sig):
        if s+i<len(buf): buf[s+i]+=v*gain
def save(name, buf): open(name+'.f32','wb').write(struct.pack('<%df'%len(buf),*buf))
for f in sorted(glob.glob('w*.wav'), key=lambda s:int(s[1:-4])):
    word=trim(rd(f)); wp=max(abs(v) for v in word)
    for level,peak in (('normal',.30),('quiet',.06),('soft',.03),('whisper',.015)):
        for tg in (0,.05):
            for at in (.55,.75):
                buf=base(at+len(word)/R+0.5)
                if tg: add(buf,tone,.30,tg/tp)
                add(buf,word,at,peak/wp)
                save('%s-%s-tone%s-at%d'%(f[:-4],level,'on' if tg else 'off',int(at*100)),buf)
for g in (.01,.02,.03):
    for late in (0,.2,.45):
        b=base(2.0); add(b,tone,.30+late,g/tp); save('neg-tone%.2f-late%d'%(g,int(late*1000)),b)
b=base(2.0); add(b,[random.uniform(-1,1) for _ in range(int(.18*R))],.22,.012); add(b,tone,.5,.03/tp); save('neg-burst-then-tone',b)
b=base(2.0); add(b,[random.uniform(-1,1) for _ in range(int(.12*R))],1.0,.017); save('neg-thump',b)
b=base(2.0)
for k in range(10): add(b,[random.uniform(-1,1) for _ in range(int(.06*R))],.1+k*.18,.02)
save('neg-clicks',b); save('neg-fan',base(3,.004)); save('neg-room',base(3))
print(len(glob.glob('*.f32')),'buffers')

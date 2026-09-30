#!/usr/bin/env python3
"""Fixed-set accuracy of the cloud path exactly as Haynoi sends it (W37-1574).

say -v Linh reads each line of sentences.txt; each clip goes to Kyma
/v1/audio/transcriptions with model transcribe-quality, the app's prompt
(\"Custom vocabulary: … \" + the Normal mode prompt), response_format=json and
include[]=logprobs — the fields STTProvider.callTranscribe sends. Scores WER
(case/punctuation-insensitive), glossary-term hits and tokens under the app's
-0.3 logprob floor (which would trigger the correction pass).
Run: ~/cos/bin/chay-an ~/kyma-api/.env KYMA_API_KEY -- python3 run.py
"""
import json, os, re, subprocess, sys, tempfile, unicodedata
HERE = os.path.dirname(os.path.abspath(__file__))
TERMS = ['deck', 'Mandeck', 'agent', 'Haynoi', 'Affitor', 'Kyma', 'Pheme', 'Pidot', 'Mac mini', 'Markdown', 'HTML', 'output']
MODE = 'Transcribe this audio accurately. It may contain Vietnamese and English.'
key = next(l.split('=', 1)[1].strip().strip("'") for l in open(os.path.expanduser('~/kyma-api/.env')) if l.startswith('KYMA_API_KEY='))

def norm(s):
    s = unicodedata.normalize('NFC', s.lower())
    return re.sub(r'[^\w\s]', ' ', s).split()

def wer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)], len(r)

CORRECTION = ("The text is a raw speech-to-text transcript. Fix misrecognized words using the context above. "
              "Change nothing else — no rephrasing, no formatting, no additions or removals. Return only the corrected text.")

def correct(text):
    """STTProvider.rewriteSystemPrompt(base: correctionPassPrompt, glossary: TERMS), gemini-3.5-flash-lite, t=0.3."""
    system = ("The user's preferred spellings for names and terms (use these exact forms when they occur): "
              + ', '.join(TERMS) + '.\n\n' + CORRECTION)
    body = json.dumps({'model': 'gemini-3.5-flash-lite', 'temperature': 0.3, 'max_tokens': 1024,
                       'messages': [{'role': 'system', 'content': system}, {'role': 'user', 'content': text}]})
    out = subprocess.run(['curl', '-s', '-H', 'Authorization: Bearer ' + key, '-H', 'Content-Type: application/json',
                          '-d', body, 'https://kymaapi.com/v1/chat/completions'], capture_output=True, text=True).stdout
    return json.loads(out)['choices'][0]['message']['content'].strip()

def stt(path, prompt):
    args = ['curl', '-s', '-H', 'Authorization: Bearer ' + key, '-F', f'file=@{path}', '-F', 'model=transcribe-quality',
            '-F', 'response_format=json', '-F', 'include[]=logprobs']
    if prompt: args += ['-F', 'prompt=' + prompt]
    out = subprocess.run(args + ['https://kymaapi.com/v1/audio/transcriptions'], capture_output=True, text=True).stdout
    j = json.loads(out)
    lp = [t.get('logprob', 0) for t in (j.get('logprobs') or [])]
    return j.get('text', ''), sum(1 for x in lp if x < -0.3)

tmp = tempfile.mkdtemp()
for label, prompt in (('app prompt (glossary + mode)', 'Custom vocabulary: ' + ', '.join(TERMS) + '. ' + MODE), ('mode prompt only', MODE)):
    errs = words = hits = total = doubt = cerrs = chits = 0
    print(f'== {label}')
    for i, ref in enumerate(l.strip() for l in open(os.path.join(HERE, 'sentences.txt')) if l.strip()):
        wav = os.path.join(tmp, f'{i}.wav')
        subprocess.run(['say', '-v', 'Linh', '-o', wav, '--data-format=LEI16@16000', ref], check=True)
        hyp, d = stt(wav, prompt)
        fixed = correct(hyp) if d else hyp   # the app runs the pass only when a token is under -0.3
        e, n = wer(ref, hyp); errs += e; words += n; doubt += d
        ce, _ = wer(ref, fixed); cerrs += ce
        for t in TERMS:
            if t.lower() in ref.lower():
                total += 1; hits += t.lower() in hyp.lower(); chits += t.lower() in fixed.lower()
        print(f'  {e}/{n} -> {ce}/{n}  doubt={d}  {hyp}  =>  {fixed}')
    print(f'  raw STT: WER {errs}/{words} = {errs / words:.1%} · terms {hits}/{total}')
    print(f'  after correction pass: WER {cerrs}/{words} = {cerrs / words:.1%} · terms {chits}/{total} · tokens under -0.3: {doubt}')

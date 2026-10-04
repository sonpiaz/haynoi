"""Per-stage latency of one Haynoi dictation, measured off the app (W37-1424).

Stages after key-up, in pipeline order:
  tail      PipelineController.tailMs, fixed
  stt       transcribe-quality with logprobs (what STTProvider.callTranscribe sends)
  correct   gemini-3.5-flash-lite correction pass — only when a token < -0.3
  proxy     api.haynoi.com hop: unauthenticated POST of the same m4a (TLS + upload + 401)
Kyma is called directly with KYMA_API_KEY read from the .env (run under chay-an).
Prints one JSON line per call, then a summary.
"""
import glob, json, os, statistics, subprocess, sys, tempfile

N = int(sys.argv[1]) if len(sys.argv) > 1 else 5
HERE = os.path.dirname(os.path.abspath(__file__))
KYMA = 'https://kymaapi.com/v1'
FLOOR = -0.3  # STTProvider.lowConfidenceLogprob

key = ''
for line in open(os.environ.get('KYMA_ENV', os.path.expanduser('~/kyma-api/.env'))):
    if line.startswith('KYMA_API_KEY='):
        key = line.split('=', 1)[1].strip().strip("'")
if len(key) < 20:
    print('no usable key'); sys.exit(1)

W = '%{json}'

def curl(args):
    with tempfile.NamedTemporaryFile(delete=False) as hdr:
        hdr.write(('Authorization: Bearer ' + key).encode()); hp = hdr.name
    try:
        r = subprocess.run(['curl', '-s', '-o', '/dev/stdout', '-w', '\n' + W, '-H', '@' + hp] + args,
                           capture_output=True, text=True, timeout=60)
    finally:
        os.unlink(hp)
    body, _, meta = r.stdout.rpartition('\n')
    try: m = json.loads(meta)
    except Exception: m = {}
    return body, m

def stt(path):
    body, m = curl(['-F', 'file=@' + path + ';type=audio/m4a', '-F', 'model=transcribe-quality',
                    '-F', 'response_format=json', '-F', 'include[]=logprobs',
                    KYMA + '/audio/transcriptions'])
    try: j = json.loads(body)
    except Exception: j = {}
    lps = [e.get('logprob') for e in (j.get('logprobs') or []) if isinstance(e.get('logprob'), (int, float))]
    return {'code': m.get('http_code'), 's': m.get('time_total'), 'ttfb': m.get('time_starttransfer'),
            'text': (j.get('text') or '')[:80], 'n_lp': len(lps),
            'min_lp': round(min(lps), 3) if lps else None,
            'fires': any(x < FLOOR for x in lps)}, j.get('text') or ''

SYSTEM = ("The user's preferred spellings for names and terms (use these exact forms when they occur): "
          "Mandeck, Haynoi, Affitor, Kyma, EVOX, Pidot.\n\n"
          "Known misrecognitions from this user's dictation history — when the left side appears, it was almost certainly meant as the right side:\n"
          "\"Man deck\" → \"Mandeck\"\n\"Hanoi\" → \"Haynoi\"\nApply a correction only where the misrecognized form actually occurs; never insert these terms anywhere else.\n\n"
          "The text is a raw speech-to-text transcript. Fix misrecognized words using the context above. "
          "Change nothing else — no rephrasing, no formatting, no additions or removals. Return only the corrected text.")

def correct(text):
    payload = json.dumps({'model': 'gemini-3.5-flash-lite', 'temperature': 0.3, 'max_tokens': 1024,
                          'messages': [{'role': 'system', 'content': SYSTEM}, {'role': 'user', 'content': text}]})
    body, m = curl(['-H', 'Content-Type: application/json', '--data-binary', payload, KYMA + '/chat/completions'])
    return {'code': m.get('http_code'), 's': m.get('time_total')}

def proxy(path):
    r = subprocess.run(['curl', '-s', '-o', '/dev/null', '-w', W, '-F', 'file=@' + path + ';type=audio/m4a',
                        '-F', 'model=transcribe-quality', 'https://api.haynoi.com/v1/proxy/audio/transcriptions'],
                       capture_output=True, text=True, timeout=60)
    m = json.loads(r.stdout)
    return {'code': m.get('http_code'), 's': m.get('time_total'), 'tls': m.get('time_appconnect')}

rows = []
for f in sorted(glob.glob(os.path.join(HERE, 'l[0-9].m4a'))):
    name = os.path.basename(f)
    for i in range(N):
        s, text = stt(f)
        c = correct(text) if text else {'code': None, 's': None}
        p = proxy(f)
        row = {'file': name, 'run': i + 1, 'stt': s, 'correct': c, 'proxy': p}
        rows.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)

def q(xs, p):
    xs = sorted(x for x in xs if x is not None)
    return round(xs[min(len(xs) - 1, int(p * len(xs)))], 2) if xs else None

print('\nSUMMARY  (seconds; p50 / p90 / max)')
for name in sorted({r['file'] for r in rows}):
    rs = [r for r in rows if r['file'] == name]
    st = [r['stt']['s'] for r in rs if r['stt']['code'] == 200]
    co = [r['correct']['s'] for r in rs if r['correct']['code'] == 200]
    px = [r['proxy']['s'] for r in rs]
    fires = sum(r['stt']['fires'] for r in rs)
    print(f"{name}: stt {q(st,.5)}/{q(st,.9)}/{q(st,1)} n={len(st)} · correction fires {fires}/{len(rs)}, "
          f"cost {q(co,.5)}/{q(co,.9)}/{q(co,1)} · proxy {q(px,.5)}/{q(px,.9)}/{q(px,1)} codes {sorted({r['proxy']['code'] for r in rs})}")

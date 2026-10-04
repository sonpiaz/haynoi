import os, sys, json, glob, subprocess
key = ''
for line in open(os.environ.get('KYMA_ENV', os.path.expanduser('~/kyma-api/.env'))):
    if line.startswith('KYMA_API_KEY='): key = line.split('=', 1)[1].strip().strip("'")
if len(key) < 20:
    print('no usable key'); sys.exit(1)
model = sys.argv[1]
for f in sorted(glob.glob(os.path.join(os.path.dirname(__file__), 's[0-9]-*.wav'))):
    r = subprocess.run(['curl', '-s', '-o', '-', '-w', '\n%{http_code}', '-H', 'Authorization: Bearer ' + key,
                        '-F', 'file=@' + f, '-F', 'model=' + model, '-F', 'language=vi',
                        'https://kymaapi.com/v1/audio/transcriptions'], capture_output=True, text=True)
    body, _, code = r.stdout.rpartition('\n')
    try: text = json.loads(body).get('text', '')
    except Exception: text = '<unparsed>'
    print(os.path.basename(f), code, text.strip() or body[:200])

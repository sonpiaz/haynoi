"""Offline tests for check-model-retirements.py: python3 scripts/test_check_model_retirements.py"""
import datetime, importlib.util, json, os, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('cmr', os.path.join(HERE, 'check-model-retirements.py'))
cmr = importlib.util.module_from_spec(spec); spec.loader.exec_module(cmr)

CATALOG = {
    'data': [{'id': 'gemini-3.5-flash-lite', 'retires_on': None},
             {'id': 'whisper-v3-turbo', 'retires_on': None},
             {'id': 'gpt-4o-mini-transcribe-2025-12-15', 'retires_on': '2027-02-26'}],
    'aliases': {'transcribe': 'whisper-v3-turbo', 'transcribe-quality': 'gpt-4o-mini-transcribe-2025-12-15',
                'fast': 'gemini-3.5-flash-lite', 'code': 'qwen-3-coder'},
}

def scan(swift):
    root = tempfile.mkdtemp(); os.makedirs(os.path.join(root, 'Sources'))
    open(os.path.join(root, 'Sources', 'A.swift'), 'w').write(swift)
    names = {m['id'] for m in CATALOG['data']} | set(CATALOG['aliases'])
    return cmr.literals(root, names)

class T(unittest.TestCase):
    APP = 'let m = q ? "transcribe-quality" : "transcribe"\nlet body = ["model": "gemini-3.5-flash-lite"]\n'

    def test_alias_is_resolved_and_its_retirement_seen(self):
        rows, bad = cmr.check(CATALOG, scan(self.APP), datetime.date(2026, 11, 15), 120)
        self.assertIn(('transcribe-quality', 'gpt-4o-mini-transcribe-2025-12-15', '2027-02-26'), [r[:3] for r in rows])
        self.assertEqual(bad, ['transcribe-quality'])

    def test_far_from_retirement_is_clean(self):
        _, bad = cmr.check(CATALOG, scan(self.APP), datetime.date(2026, 9, 30), 120)
        self.assertEqual(bad, [])

    def test_a_model_gone_from_the_catalog_fails(self):
        cat = dict(CATALOG, data=[m for m in CATALOG['data'] if m['id'] != 'whisper-v3-turbo'])
        _, bad = cmr.check(cat, scan(self.APP), datetime.date(2026, 9, 30), 120)
        self.assertEqual(bad, ['transcribe'])

    def test_plain_word_tags_are_not_models(self):
        used = scan('Text("Fast").tag("fast")\nlet c = json["code"]\n// "transcribe-quality" in a comment\n')
        self.assertEqual(used, {})

    def test_a_plain_word_on_a_model_line_counts(self):
        self.assertIn('fast', scan('let body = ["model": "fast"]\n'))

class Seen(unittest.TestCase):
    """Review r1/r2: a model the catalog drops must stay visible while Sources quote it."""
    def setUp(self):
        self.root = tempfile.mkdtemp(); os.makedirs(os.path.join(self.root, 'Sources'))
        open(os.path.join(self.root, 'Sources', 'A.swift'), 'w').write(
            'return q ? "transcribe-quality" : "transcribe"\nText("Fast").tag("fast")\n// "gone-model-9" in a comment\n')
        self.seen = os.path.join(self.root, 'seen.txt')
        self.day = datetime.date(2026, 9, 30)

    def drop(self, *ids):
        cat = json.loads(json.dumps(CATALOG))
        cat['aliases'] = {k: v for k, v in cat['aliases'].items() if k not in ids}
        return cat

    def test_both_aliases_survive_a_drop_of_the_hyphenated_one(self):
        cmr.run(CATALOG, self.root, self.day, 120, self.seen)
        rows, bad = cmr.run(self.drop('transcribe-quality'), self.root, self.day, 120, self.seen)
        self.assertEqual(bad, ['transcribe-quality'])
        self.assertEqual(open(self.seen).read().split(), ['transcribe', 'transcribe-quality'])
        _, bad = cmr.run(self.drop('transcribe-quality', 'transcribe'), self.root, self.day, 120, self.seen)
        self.assertEqual(sorted(bad), ['transcribe', 'transcribe-quality'])

    def test_comments_and_ui_tags_never_enter_the_seen_file(self):
        open(self.seen, 'w').write('gone-model-9\nfast\n')
        _, bad = cmr.run(CATALOG, self.root, self.day, 120, self.seen)
        self.assertEqual(bad, [])
        self.assertNotIn('gone-model-9', open(self.seen).read())

if __name__ == '__main__':
    unittest.main()

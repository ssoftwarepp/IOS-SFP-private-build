import json
from pathlib import Path

bundle = Path(__file__).resolve().parent
settings = json.loads((bundle / 'settings.json').read_text(encoding='utf-8'))
account = settings.get('account', '')
loops = int(settings.get('loops', 1))
mode = settings.get('mode', 'normal')
notify = bool(settings.get('notify', False))

for index in range(loops):
    print('run', index + 1, 'account', account, 'mode', mode)
if notify:
    print('done')

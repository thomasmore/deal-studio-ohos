#!/usr/bin/env python3
"""Host-only test of bench.sh's actual remote prompt command; no hdc or model calls."""
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
script = (root / 'tools/vera-bench/bench.sh').read_text()
# Source only the function used by start_generation, not the device-driving script.
function = script.split('prompt_command() {', 1)[1].split('\n}', 1)[0]
function = 'prompt_command() {' + function + '\n}'
corpus = json.loads((root / 'docs/prompts/coverage-gold.json').read_text())
prompts = [row['prompt'] for row in corpus]
prompts += ["It's $12, not $18", 'He said "return it"', r'C:\books\new',
            '`touch injected`', '$(touch injected)', "quotes: ' \" \\ $HOME ${USER}"]
with tempfile.TemporaryDirectory() as td:
    directory = Path(td)
    # Fake uitest receives precisely the argv that the phone command would receive.
    uitest = directory / 'uitest'
    uitest.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
    uitest.chmod(0o755)
    for prompt in prompts:
        command = subprocess.check_output(['bash', '-c', function + '\nPROMPT_FIELD="626 639"\nprompt_command "$1"', 'test', prompt], text=True)
        result = subprocess.check_output(['sh', '-c', 'PATH=' + str(directory) + ':"$PATH"; ' + command], text=True, cwd=directory)
        assert json.loads(result) == ['uiInput', 'inputText', '626', '639', prompt], (prompt, result)
    assert not (directory / 'injected').exists(), 'Prompt text executed as a shell command'
print(f'bench transport: {len(prompts)} exact round trips passed; substitutions stayed literal')

#!/usr/bin/env bash
# Exercise keep-clean public CLI with isolated API and git fixtures.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TASK_TMP=$(fm_test_tmproot fm-keep-clean)
export TASK_TMP ROOT
python3 - <<'PY'
import base64
import datetime as dt
import json
import os
from pathlib import Path
import subprocess

root = Path(os.environ['ROOT'])
temp = Path(os.environ['TASK_TMP'])
project = temp / 'project'
project.mkdir()
subprocess.run(['git', 'init', '-q', str(project)], check=True)
subprocess.run(['git', '-C', str(project), 'remote', 'add', 'origin', 'https://github.com/example/project.git'], check=True)
fakebin = temp / 'bin'
fakebin.mkdir()
fake = fakebin / 'gh-axi'
fake.write_text('''#!/usr/bin/env python3
import base64,json,os,sys
from pathlib import Path
data=json.loads(Path(os.environ['API_FIXTURE']).read_text())
path=sys.argv[2]
if path not in data: sys.exit(1)
print('api_response:\\n  body: '+base64.b64encode(json.dumps(data[path]).encode()).decode()+'\\n  truncated: false')
''')
fake.chmod(0o755)
env = dict(os.environ, PATH=str(fakebin)+os.pathsep+os.environ['PATH'], API_FIXTURE=str(temp/'api.json'))
today = dt.datetime.now(dt.timezone.utc).date()
policy = {'sort_done': today.isoformat()}
pulls = [{'number': i, 'user': {'login': 'person'}, 'labels': [], 'body': 'Replaces: none',
          'created_at': dt.datetime.now(dt.timezone.utc).isoformat(), 'html_url': f'https://github.com/example/project/pull/{i}'} for i in range(1, 107)]

def fixture(policy_value=policy, values=None, marker=True):
    values = pulls[:5] if values is None else values
    data = {'/repos/example/project/contents': [{'name': '.github'}],
            '/repos/example/project/contents/.github': [{'name': 'keep-clean.json'}] if marker else [],
            '/repos/example/project/contents/.github/keep-clean.json':
                {'content': base64.b64encode(json.dumps(policy_value).encode()).decode()}}
    for page in range(len(values)//100+1):
        data[f'/repos/example/project/pulls?state=open&per_page=100&page={page+1}'] = values[page*100:(page+1)*100]
    (temp/'api.json').write_text(json.dumps(data))

def cli(*args, ok=True, data=None, contains=None):
    result = subprocess.run(['python3', str(root/'bin/fm-keep-clean.py'), *map(str,args)],
                            input=json.dumps(data) if data else None, env=env, capture_output=True, text=True)
    assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
    if contains:
        assert contains in result.stdout+result.stderr, (contains, result.stdout, result.stderr)
    return result.stdout

common = [project, '--home', temp/'home']
fixture(marker=False)
cli('check-spawn', *common, ok=False, contains='Monday sort due')
fixture({'sort_done': None})
cli('check-spawn', *common, ok=False, contains='Monday sort due')
fixture()
cli('check-spawn', *common, ok=False, contains='Monday sort due')
cli('sort', *common, '--done')
cli('check-spawn', *common, ok=False, contains='5 or more')
fixture(values=pulls[:4])
cli('check-spawn', *common)
fixture()
cli('check-spawn', *common, ok=False, contains='5 or more')
fixture(values=pulls)
cli('sort', *common, contains='https://github.com/example/project/pull/106')
(temp/'api.json').write_text('{}')
cli('check-spawn', *common, ok=False)
cli('idea', *common, 'A useful future change', '--replaces', 'old-task')
cli('ideas', *common, contains='"replaces": "old-task"')
record_path = temp/'home/data/keep-clean/example/project.json'
record = json.loads(record_path.read_text())
assert record['ideas'][0]['expires'] == (today+dt.timedelta(days=14)).isoformat()
record['ideas'][0]['expires'] = today.isoformat()
record['sorted_week'] = '2000-01-03'
record_path.write_text(json.dumps(record))
cli('ideas', *common, contains='expired:')
fixture(values=[])
cli('check-spawn', *common, ok=False, contains='Monday sort due')
cli('sort', *common)
cli('check-spawn', *common, ok=False, contains='Monday sort due')
cli('sort', *common, '--done')
cli('check-spawn', *common)

def ci(number, values, policy_value=policy, ok=True):
    cli('check-pr', data={'number': number, 'pulls': values, 'policy': policy_value}, ok=ok)

ci(5, pulls[:5])
ci(6, pulls[:6], ok=False)
ci(1, pulls[:6])  # An older PR remains admissible when another is opened.
ci(6, pulls[:6], {'sort_done': None}, ok=False)
ci(6, pulls[:6], {}, ok=False)
exempt = json.loads(json.dumps(pulls[:6]))
exempt[5]['user']['login'] = 'dependabot[bot]'
ci(6, exempt, ok=False)
exempt[5]['user']['login'] = 'person'
exempt[5]['labels'] = [{'name':'urgent'}]
ci(6, exempt, ok=False)
exempt[5]['labels'] = []
ci(6, exempt, ok=False)
expired = json.loads(json.dumps(pulls[:1]))
expired[0]['created_at'] = (dt.datetime.now(dt.timezone.utc)-dt.timedelta(days=14, seconds=5)).isoformat()
fixture(values=expired)
ci(1, expired)
ci(2, expired + pulls[1:2], ok=False)
ci(1, expired + pulls[1:6])
expired_overflow = json.loads(json.dumps(pulls[:6]))
for pull in expired_overflow:
    pull['created_at'] = expired[0]['created_at']
ci(6, expired_overflow, ok=False)
cli('check-spawn', *common, ok=False, contains='Expired PRs require disposition')
record = json.loads(record_path.read_text())
record['sorted_week'] = '2000-01-03'
record_path.write_text(json.dumps(record))
cli('sort', *common, '--done', ok=False, contains='Expired PRs require disposition')
assert json.loads(record_path.read_text())['sorted_week'] == '2000-01-03'
fixture(values=[])
cli('sort', *common, '--done')
cli('check-spawn', *common)
fixture()
print('ok - PR boundaries, unconditional enforcement, pagination, expiry, ideas, replacements, Monday sort and API failure')
PY

# Prove real ship admission refuses before emitting launch artifacts.
fm_test_spawn_home "$TASK_TMP/home" claude
fm_git_init_commit "$TASK_TMP/spawn-project"
git -C "$TASK_TMP/spawn-project" remote add origin https://github.com/example/project.git
fm_test_spawn_brief "$TASK_TMP/home" limit-task $'Build one more feature.\nPR exception: urgent'
FAKEBIN=$(fm_test_make_spawn_fakebin "$TASK_TMP/spawn-tools")
cp "$TASK_TMP/bin/gh-axi" "$FAKEBIN/gh-axi"
set +e
OUTPUT=$(API_FIXTURE="$TASK_TMP/api.json" fm_test_run_spawn "$TASK_TMP/home" "$TASK_TMP/spawn-project" "$FAKEBIN" \
  limit-task "$TASK_TMP/spawn-project" --mode no-mistakes --yolo off)
RESULT=$?
set -e
expect_code 1 "$RESULT" 'sixth ship is refused'
assert_contains "$OUTPUT" '5 or more' 'spawn must reach PR-budget admission'
[ ! -f "$TASK_TMP/home/state/limit-task.meta" ] || fail 'refused ship wrote task metadata'
[ ! -f "$TASK_TMP/home/data/limit-task/launch-brief.md" ] || fail 'refused ship wrote launch brief'
pass 'real spawn refuses full budget before worker artifacts'

fm_test_spawn_brief "$TASK_TMP/home" limit-scout 'Ship the investigated feature.'
fm_write_meta "$TASK_TMP/home/state/limit-scout.meta" "kind=scout" "project=$TASK_TMP/spawn-project"
set +e
OUTPUT=$(FM_HOME="$TASK_TMP/home" API_FIXTURE="$TASK_TMP/api.json" PATH="$FAKEBIN:$PATH" \
  bash "$ROOT/bin/fm-promote.sh" limit-scout --mode no-mistakes --yolo off 2>&1)
RESULT=$?
set -e
expect_code 1 "$RESULT" 'full budget refuses scout promotion'
assert_contains "$OUTPUT" '5 or more' 'promotion must reach PR-budget admission'
assert_grep 'kind=scout' "$TASK_TMP/home/state/limit-scout.meta" 'refused promotion preserves scout'
[ ! -f "$TASK_TMP/home/data/limit-scout/ship-instructions.md" ] || fail 'refused promotion wrote ship instructions'
pass 'scout promotion cannot bypass the ship budget'

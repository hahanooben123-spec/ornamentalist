"""Read this project's Actions status/logs. Credentials stay in process memory."""
import argparse
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

REPOSITORY = 'hahanooben123-spec/ornamentalist'
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
BASE = 'https://api.github.com/repos/' + REPOSITORY


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected and urllib.parse.urlparse(newurl).hostname != 'api.github.com':
            redirected.remove_header('Authorization')
        return redirected


def credential():
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0', GCM_INTERACTIVE='never')
    result = subprocess.run(['git', 'credential', 'fill'], input='protocol=https\nhost=github.com\n\n',
                            capture_output=True, text=True, env=env)
    fields = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    return fields.get('password')


def request(path, method="GET"):
    headers = {'User-Agent': 'Ornamentalist-build-check', 'Accept': 'application/vnd.github+json'}
    opener = urllib.request.build_opener(SafeRedirect())
    try:
        return opener.open(urllib.request.Request(BASE + path, headers=headers, method=method), timeout=30).read()
    except urllib.error.HTTPError as error:
        if error.code not in [401, 403, 404]:
            raise SystemExit(f'GitHub returned HTTP {error.code}') from None
    token = credential()
    if not token:
        raise SystemExit('GitHub API authentication is unavailable. Open the Actions page in your browser.')
    headers['Authorization'] = 'Bearer ' + token
    try:
        return opener.open(urllib.request.Request(BASE + path, headers=headers, method=method), timeout=30).read()
    except urllib.error.HTTPError as error:
        raise SystemExit(f'GitHub returned HTTP {error.code}; no credential was printed.') from None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['status', 'logs', 'screenshots', 'artifacts'])
    parser.add_argument('--run', type=int)
    args = parser.parse_args()
    if args.action == 'status':
        if args.run:
            jobs = json.loads(request(f'/actions/runs/{args.run}/jobs'))['jobs']
            print(json.dumps([{'name': j['name'], 'status': j['status'], 'conclusion': j['conclusion'],
                               'steps': [{k: s.get(k) for k in ['name', 'status', 'conclusion', 'started_at', 'completed_at']} for s in j['steps']]} for j in jobs], indent=2))
            return
        runs = json.loads(request('/actions/runs?per_page=5'))['workflow_runs']
        print(json.dumps([{key: run.get(key) for key in ['id', 'head_sha', 'status', 'conclusion', 'html_url', 'created_at']} for run in runs], indent=2))
    elif args.action == 'artifacts':
        if args.run is None:
            parser.error('--run is required for artifacts')
        artifacts = json.loads(request(f'/actions/runs/{args.run}/artifacts'))['artifacts']
        print(json.dumps([{'name': a['name'], 'expired': a['expired'],
                           'url': f"https://github.com/{REPOSITORY}/actions/runs/{args.run}/artifacts/{a['id']}"}
                          for a in artifacts], indent=2))
    elif args.action == 'screenshots':
        if args.run is None:
            parser.error('--run is required for screenshots')
        artifacts = json.loads(request(f'/actions/runs/{args.run}/artifacts'))['artifacts']
        artifact = next((a for a in artifacts if a['name'] == 'studio-ui-screenshots'), None)
        if artifact is None:
            raise SystemExit('Screenshot artifact is not available yet.')
        output = Path(__file__).resolve().parents[1] / 'dist' / 'ui-preview' / str(args.run)
        output.mkdir(parents=True, exist_ok=True)
        archive = zipfile.ZipFile(io.BytesIO(request(f"/actions/artifacts/{artifact['id']}/zip")))
        for entry in archive.infolist():
            target = (output / entry.filename).resolve()
            if not target.is_relative_to(output.resolve()):
                raise SystemExit('Unsafe artifact path')
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(entry))
        print(f'Screenshots extracted to {output}')
        for path in sorted(output.rglob('*.png')):
            print(path.relative_to(output))
    else:
        if args.run is None:
            parser.error('--run is required for logs')
        archive = zipfile.ZipFile(io.BytesIO(request(f'/actions/runs/{args.run}/logs')))
        for name in archive.namelist():
            if name.endswith('.txt') and not name.startswith('0_'):
                data = archive.read(name).decode('utf-8', errors='replace')
                lines = data.splitlines()
                indexes = {j for i, line in enumerate(lines) if any(word in line.lower() for word in ['error:', 'failed', 'test suite', 'executed ', 'warning:', '##[error]', 'testnormallaunch', 'testoversizedindex', 'skipped']) for j in range(max(0, i-2), min(len(lines), i+4))}
                if indexes:
                    print(name)
                    print('\n'.join(lines[i] for i in sorted(indexes))[:24000])


if __name__ == '__main__':
    main()

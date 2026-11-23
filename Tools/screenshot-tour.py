#!/usr/bin/env python3
"""Capture native Debug screens with fictional fixtures; build a searchable light/dark gallery."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.bensanzone.zood'
SCENES = ['onboarding', 'map', 'map-many-friends', 'friend', 'friend-long-name', 'friend-updated', 'friend-unsupported', 'add-friend', 'requests', 'requests-empty',
          'safety-number', 'timed-share', 'friend-nickname', 'account', 'settings', 'settings-support', 'notices',
          'blocked-users', 'blocked-empty', 'delete-account']


def run(*args, env=None, check=True, timeout=60):
    return subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=check, timeout=timeout).stdout.strip()


def sim(*args, **kwargs):
    return run('xcrun', 'simctl', *args, **kwargs)


def gallery(out, captures):
    data = json.dumps(captures).replace('</', '<\\/')
    page = '''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width"><title>Family Locator UI tour</title>
<style>body{font:16px system-ui;margin:24px;background:#15181d;color:#eee}input,button,a{font:inherit}
a{color:#80bfff}input{padding:10px;width:min(90%,440px)}#grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:20px}figure{margin:16px 0}img{width:100%;max-width:420px;border-radius:16px}figcaption{padding:8px}button{padding:10px;margin:8px}#single{text-align:center}#single img{max-height:78vh;width:auto;max-width:95%}</style>
<h1>Family Locator UI tour</h1><p>Fictional demo data • native iOS screens • Debug only</p>
<p><a href="index.html">Gallery</a> · <a href="viewer.html">One screen at a time</a></p>
<input id="search" aria-label="Filter screenshots" placeholder="Filter by screen, theme, or text size">
<div id="grid"></div><div id="single" hidden><button id="prev">← Previous</button><button id="next">Next →</button><h2 id="label"></h2><img id="screen" alt=""></div>
<script>const shots=CAPTURES;let filtered=shots,index=0;const viewing=location.pathname.endsWith('viewer.html');
const grid=document.querySelector('#grid'),single=document.querySelector('#single');
function render(){grid.replaceChildren();grid.hidden=viewing;single.hidden=!viewing;
if(viewing){const s=filtered[index];document.querySelector('#label').textContent=s?s.title:'No matching screens';document.querySelector('#screen').src=s?s.file:'';document.querySelector('#screen').alt=s?s.title:'';return;}
filtered.forEach(s=>{const f=document.createElement('figure'),a=document.createElement('a'),im=document.createElement('img'),c=document.createElement('figcaption');a.href='viewer.html#'+shots.indexOf(s);im.src=s.file;im.alt=s.title;im.loading='lazy';c.textContent=s.title;a.append(im);f.append(a,c);grid.append(f);});}
function step(n){if(filtered.length){index=(index+n+filtered.length)%filtered.length;render();}}
document.querySelector('#prev').onclick=()=>step(-1);document.querySelector('#next').onclick=()=>step(1);
document.onkeydown=e=>{if(e.target.tagName==='INPUT')return;if(e.key==='ArrowLeft')step(-1);if(e.key==='ArrowRight')step(1);};
document.querySelector('#search').oninput=e=>{filtered=shots.filter(s=>s.title.toLowerCase().includes(e.target.value.toLowerCase()));index=0;render();};
index=Math.min(Math.max(0,Number(location.hash.slice(1))||0),shots.length-1);render();</script></html>'''.replace('CAPTURES', data)
    (out / 'index.html').write_text(page)
    (out / 'viewer.html').write_text(page)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('out', nargs='?', default='/private/tmp/zood-ui-tour')
    parser.add_argument('--device', help='Optional simulator UUID; otherwise a dedicated tour simulator is created/reused')
    parser.add_argument('--derived-data', default='/private/tmp/zood-tour-derived')
    parser.add_argument('--scenes', default=','.join(SCENES))
    parser.add_argument('--variants', default='light,dark,large-text')
    parser.add_argument('--no-build', action='store_true')
    parser.add_argument('--append', action='store_true', help='Retain existing captures while updating selected scenes/variants')
    args = parser.parse_args()
    scenes = args.scenes.split(',')
    variants = args.variants.split(',')
    if set(scenes) - set(SCENES) or set(variants) - {'light', 'dark', 'large-text'}:
        parser.error('Unknown scene or variant')
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    captures, failures = [], []
    if args.append and (out / 'manifest.json').exists():
        allowed = {f'{variant}/{scene}.png' for variant in ['light', 'dark', 'large-text'] for scene in SCENES}
        captures = [c for c in json.loads((out / 'manifest.json').read_text())['captures']
                    if c['file'] in allowed and (out / c['file']).is_file()]
    consecutive_failures = 0
    device = args.device
    if not device:
        devices = json.loads(sim('list', 'devices', 'available', '-j'))['devices']
        device = next((d['udid'] for group in devices.values() for d in group
                       if d['name'] == 'Family Locator Screenshot Tour'), None)
        if not device:
            runtimes = json.loads(sim('list', 'runtimes', '-j'))['runtimes']
            runtime = max((r for r in runtimes if r['isAvailable'] and '.iOS-' in r['identifier']),
                          key=lambda r: tuple(map(int, r['version'].split('.'))))
            types = json.loads(sim('list', 'devicetypes', '-j'))['devicetypes']
            phones = [d for d in types if d['name'].startswith('iPhone')]
            phone = next((d for d in reversed(phones) if 'Pro' in d['name'] and 'Max' not in d['name']), phones[-1])
            device = sim('create', 'Family Locator Screenshot Tour', phone['identifier'], runtime['identifier'])
    # This development Mac has 8 GB of RAM, so only one simulator may run at a time.
    # Shut down every other booted simulator, then reuse the tour simulator if it's already running.
    booted = json.loads(sim('list', 'devices', 'booted', '-j'))['devices']
    for other in (d['udid'] for group in booted.values() for d in group):
        if other != device:
            sim('shutdown', other, check=False)
    sim('boot', device, check=False)  # Fails harmlessly when it is already booted.
    # Some runtimes report a migration error while still completing boot. Installation below is authoritative.
    try:
        sim('bootstatus', device, '-b', check=False, timeout=30)
    except subprocess.TimeoutExpired:
        print('Boot status timed out; trying installation on the booted simulator.', flush=True)
    derived = Path(args.derived_data).resolve()
    if not args.no_build:
        with (out / 'build.log').open('w') as log:
            subprocess.run(['xcodebuild', '-project', str(ROOT / 'Zood iOS.xcodeproj'), '-scheme', 'Zood iOS',
                            '-configuration', 'Debug', '-sdk', 'iphonesimulator', '-destination', f'id={device}',
                            '-derivedDataPath', str(derived), 'CODE_SIGNING_ALLOWED=NO', 'build'],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
    app = derived / 'Build/Products/Debug-iphonesimulator/Zood iOS.app'
    sim('install', device, str(app))
    container = Path(sim('get_app_container', device, BUNDLE, 'data'))
    ready = container / 'Documents/tour-ready.txt'
    previous_appearance = sim('ui', device, 'appearance', check=False)
    sim('terminate', device, BUNDLE, check=False)
    ready.unlink(missing_ok=True)
    request_file = container / 'Documents/tour-request.json'
    request_file.parent.mkdir(parents=True, exist_ok=True)
    request_file.unlink(missing_ok=True)
    sim('launch', device, BUNDLE, env=dict(os.environ, SIMCTL_CHILD_ZOOD_SCREENSHOT_TOUR='map'))
    try:
        sim('status_bar', device, 'override', '--time', '9:41', '--dataNetwork', 'wifi',
            '--wifiMode', 'active', '--wifiBars', '3', '--batteryState', 'charged', '--batteryLevel', '100')
        for variant in variants:
            if consecutive_failures >= 3:
                break
            sim('ui', device, 'appearance', 'dark' if variant == 'dark' else 'light')
            for scene in scenes:
                try:
                    ready.unlink(missing_ok=True)
                    token = str(uuid.uuid4())
                    request_file.write_text(json.dumps({'scene': scene, 'token': token, 'largeText': variant == 'large-text'}))
                    deadline = time.monotonic() + 25
                    while time.monotonic() < deadline:
                        if ready.exists() and ready.read_text() == token:
                            break
                        time.sleep(0.2)
                    else:
                        raise RuntimeError('Tour did not signal readiness; refusing to capture a non-tour screen')
                    file = Path(variant) / f'{scene}.png'
                    (out / variant).mkdir(exist_ok=True)
                    sim('io', device, 'screenshot', str(out / file))
                    captures = [c for c in captures if c['file'] != file.as_posix()]
                    captures.append({'title': f'{scene} · {variant}', 'file': file.as_posix()})
                    consecutive_failures = 0
                    print(f'Captured {scene} ({variant})', flush=True)
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired, RuntimeError) as error:
                    failures.append({'scene': scene, 'variant': variant, 'error': str(error)})
                    consecutive_failures += 1
                    print(f'Failed {scene} ({variant}): {error}', flush=True)
                    if consecutive_failures >= 3:
                        break
    finally:
        try:
            sim('terminate', device, BUNDLE, check=False)
            sim('status_bar', device, 'clear', check=False)
            if previous_appearance in ['light', 'dark']:
                sim('ui', device, 'appearance', previous_appearance, check=False)
        except subprocess.TimeoutExpired:
            failures.append({'error': 'Simulator timed out during cleanup'})
        finally:
            sim('shutdown', device, check=False)
    gallery(out, captures)
    (out / 'manifest.json').write_text(json.dumps({'device': device, 'captures': captures, 'failures': failures}, indent=2))
    with zipfile.ZipFile(out / 'family-locator-ui-tour.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in ['index.html', 'viewer.html', 'manifest.json']:
            archive.write(out / name, name)
        for capture in captures:
            archive.write(out / capture['file'], capture['file'])
    print(f'{len(captures)} captures, {len(failures)} failures: {out / "index.html"}', flush=True)
    return 1 if failures else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(error.stderr or str(error), file=sys.stderr)
        sys.exit(1)

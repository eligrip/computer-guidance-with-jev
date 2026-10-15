#!/usr/bin/env python3
"""Opt-in live contract check. Sends synthetic data only; never captures a screen."""

import argparse
import base64
import json
import os
from pathlib import Path
import struct
import time
import urllib.error
import urllib.request
import zlib


def synthetic_png():
    width, height = 640, 480
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            row.extend((35, 110, 235) if 320 <= x < 520 and 180 <= y < 260 else (245, 245, 245))
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))

    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b'')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true', help='Make three paid requests to TypeSafe using synthetic fixtures.')
    args = parser.parse_args()
    if not args.live:
        parser.error('Pass --live to run the synthetic API checks.')
    key = os.environ.get('TYPESAFE_API_KEY', '')
    env_file = Path(__file__).resolve().parents[1] / '.env.local'
    if not key and env_file.is_file():
        for line in env_file.read_text().splitlines():
            if line.startswith('TYPESAFE_API_KEY='):
                key = line.partition('=')[2].strip().strip('\"\'')
    if not key:
        raise SystemExit('Set TYPESAFE_API_KEY or run the project key setup helper.')

    def send(body):
        request = urllib.request.Request(
            'https://api.typesafe.ai/v1/systemone',
            data=json.dumps({'model': 'jev-1.14.0', **body}).encode(),
            headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + key,
                     'TypeSafe-Danger-Zone-Images': 'true'}, method='POST')
        started = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            raise SystemExit(f'TypeSafe returned HTTP {error.code}; response body omitted.') from None
        except urllib.error.URLError:
            raise SystemExit('Could not reach TypeSafe; no credentials were logged.') from None
        print(f"Model: {result.get('model', 'unknown')}; elapsed: {time.monotonic() - started:.2f}s")
        return result['answers']

    image_ref = '2d8189c5-a9f6-42c5-bca0-a2790630959d'
    state = {'screen': image_ref}
    assets = {image_ref: {'type': 'image', 'format': 'png', 'data_base64': base64.b64encode(synthetic_png()).decode()}}
    answers = send({'state': state, 'assets': assets, 'questions': {
        'visible': {'type': 'noul', 'instructions': 'Is there a blue rectangle in `screen`?'},
        'target': {'type': 'box', 'instructions': 'The blue rectangle in `screen`.'}
    }})
    box = answers['target']['box']
    confidence = answers['target']['confidence']
    assert 0 <= box['left'] < box['right'] <= 1 and 0 <= box['top'] < box['bottom'] <= 1
    assert 0 <= confidence <= 1
    assert answers['visible']['noul'] > 0.5, 'Visible target was not detected.'
    expected = {'left': .5, 'right': .8125, 'top': .375, 'bottom': 260 / 480}
    intersection = max(0, min(box['right'], expected['right']) - max(box['left'], expected['left'])) * max(0, min(box['bottom'], expected['bottom']) - max(box['top'], expected['top']))
    area = (box['right'] - box['left']) * (box['bottom'] - box['top'])
    expected_area = (expected['right'] - expected['left']) * (expected['bottom'] - expected['top'])
    overlap = intersection / (area + expected_area - intersection)
    print(f'Positive Box: valid; presence={answers["visible"]["noul"]:.3f}; confidence={confidence:.3f}; IoU={overlap:.3f}')
    assert overlap > .5, 'Box did not overlap the synthetic target sufficiently.'
    absent = send({'state': state, 'assets': assets, 'questions': {
        'visible': {'type': 'noul', 'instructions': 'Is there a red circle in `screen`?'}
    }})
    assert absent['visible']['noul'] < .5, 'Absent target was reported present.'
    print('Absent-target presence check: passed')
    goal = send({'state': {'transcript': 'Sarah sent me a picture. I want to save the picture to my computer.'}, 'questions': {
        'goal': {'type': 'choice', 'instructions': 'Pick the exact transcript span expressing what the user wants to accomplish.', 'criteria': {
            'span_0': 'Sarah sent me a picture.',
            'span_1': 'I want to save the picture to my computer.',
            'none': 'No span expresses an intent.'
        }}
    }})
    assert goal['goal']['choice'] == 'span_1', 'Goal selection did not choose the intent span.'
    print('Verbatim goal selection: passed')


if __name__ == '__main__':
    main()

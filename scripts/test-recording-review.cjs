#!/usr/bin/env node
// Synthetic DOM checks for the self-contained offline replay page; no browser,
// network, real recording, or private user files are accessed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../Sources/JevAssist/RecordingReviewPage.swift'), 'utf8');
const script = source.split('<script>')[1].split('</script>')[0];
const elements = new Map();
function element(id) {
  if (!elements.has(id)) elements.set(id, {
    id, style: {}, listeners: {}, textContent: '', hidden: false, disabled: false, value: '0',
    addEventListener(type, callback) { this.listeners[type] = callback; },
    set innerHTML(_) { throw new Error('Replay evidence must never become HTML'); },
    set src(value) {
      assert.match(value, /^frames\/[a-f0-9]{64}\.jpg$/);
      this.imagePath = value;
    }
  });
  return elements.get(id);
}
const context = vm.createContext({ document: { getElementById: element }, setTimeout: () => 1, clearTimeout() {} });
vm.runInContext(script, context);

async function load(events, trailing = '') {
  const text = events.map(e => JSON.stringify({schemaVersion: 1, elapsedMS: 0, ...e})).join('\n') + trailing;
  await element('file').listeners.change({target: {files: [{size: text.length, text: async () => text}]}});
}
function scrub(index) { element('scrub').value = String(index); element('scrub').listeners.input(); }

(async () => {
  const literal = '<img src=x onerror="bad()">';
  const frame = {kind: 'frame', frameID: 'fixture', imagePath: `frames/${'a'.repeat(64)}.jpg`,
    screenBounds: {x: -400, y: 30, width: 800, height: 500}, imageContentRect: {x: 0, y: .1, width: 1, height: .8}};
  await load([
    {kind: 'context', transcript: literal, goal: 'Synthetic goal'}, frame,
    {kind: 'highlight', frameID: 'fixture', reason: 'accepted', targetRect: {x: -160, y: 130, width: 240, height: 100}},
    {kind: 'decision', frameID: 'fixture', disposition: 'suppressed', reason: 'box_latched', latencyMS: 120,
      confidence: .8, presence: .9, box: {left: .1, right: .2, top: .3, bottom: .5}},
    {kind: 'highlight', reason: 'screen_changed'}
  ], '\n{unfinished');
  assert.equal(element('transcript').textContent, literal);
  assert.match(element('status').textContent, /1 incomplete/);
  scrub(1);
  assert.equal(element('held').hidden, false);
  assert.ok(Math.abs(parseFloat(element('held').style.left) - 30) < 1e-8);
  assert.ok(Math.abs(parseFloat(element('held').style.top) - 26) < 1e-8);
  scrub(2);
  assert.equal(element('candidate').hidden, false);
  assert.equal(element('held').hidden, false);
  assert.match(element('reason').textContent, /suppressed/);
  scrub(3);
  assert.equal(element('held').hidden, true);
  assert.equal(element('candidate').hidden, true);
  await load([{...frame, imagePath: 'https://invalid.example/private-image'}]);
  assert.equal(element('screen').hidden, true);
  await load([{...frame, imagePath: '../../unrelated-file.jpg'}]);
  assert.equal(element('screen').hidden, true);
  await load([frame, {kind: 'decision', frameID: 'dropped-frame', disposition: 'suppressed',
    box: {left: .1, right: .2, top: .3, bottom: .5}}]);
  scrub(1);
  assert.equal(element('screen').hidden, true, 'Dropped evidence must not reuse an unrelated earlier screenshot');
  assert.equal(element('candidate').hidden, true);
  console.log('Offline recording review checks passed: text safety, local-only images, replay mapping, suppression, clear, partial log.');
})().catch(error => { console.error(error); process.exitCode = 1; });

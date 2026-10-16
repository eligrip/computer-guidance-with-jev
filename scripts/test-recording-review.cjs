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

  const ensemble = {method: 'weighted_agreement', selected_indices: [0, 1], iou_threshold: .5, samples: [
    {box: {left: .1, right: .2, top: .3, bottom: .5}, confidence: .81, presence: .91},
    {box: {left: .14, right: .24, top: .3, bottom: .5}, confidence: .79, presence: .9},
    {box: {left: .7, right: .9, top: .7, bottom: .9}, confidence: .99, presence: .95}
  ]};
  const consensusDecision = {kind: 'decision', frameID: 'fixture', disposition: 'displayed', reason: 'accepted', ensemble,
    box: {left: .135, right: .235, top: .3, bottom: .5}};
  await load([frame, consensusDecision]);
  scrub(1);
  for (let i = 0; i < 3; i++) assert.equal(element('sample'+i).hidden, false, `Original sample ${i} must be visible`);
  assert.equal(element('sample0').style.borderStyle, 'solid');
  assert.equal(element('sample2').style.borderStyle, 'dotted');
  assert.match(element('sampleRow0').textContent, /selected\nConfidence 81.0% · presence 91.0%/);
  assert.match(element('sampleRow2').textContent, /excluded\nConfidence 99.0% · presence 95.0%/);
  assert.match(element('ensembleSummary').textContent, /weighted agreement\nSelected: 1, 2 · IoU threshold 0.50/);
  assert.ok(Math.abs(parseFloat(element('candidate').style.left) - 13.5) < 1e-8,
    'The final recorded box must not be recomputed from its samples by the viewer');
  assert.ok(Math.abs(parseFloat(element('sample2').style.left) - 70) < 1e-8, 'Excluded outlier retains original geometry');
  element('screen').listeners.error();
  for (const id of ['screen', 'held', 'candidate', 'sample0', 'sample1', 'sample2']) assert.equal(element(id).hidden, true);

  await load([frame, {...consensusDecision, frameID: 'dropped-frame'}]);
  scrub(1);
  for (const id of ['screen', 'candidate', 'sample0', 'sample1', 'sample2']) assert.equal(element(id).hidden, true,
    'Consensus evidence cannot be drawn over an unrelated earlier screenshot');
  assert.equal(element('ensembleCard').hidden, false, 'Sample probabilities remain inspectable when the image was dropped');
  assert.match(element('ensembleSummary').textContent, /screenshot unavailable/);

  await load([frame, {...consensusDecision, box: null, disposition: 'suppressed', reason: 'no_agreement',
    ensemble: {...ensemble, method: 'no_agreement', selected_indices: []}}]);
  scrub(1);
  assert.equal(element('candidate').hidden, true);
  assert.match(element('ensembleSummary').textContent, /Selected: none/);
  for (let i = 0; i < 3; i++) {
    assert.equal(element('sample'+i).hidden, false);
    assert.match(element('sampleRow'+i).textContent, /excluded/);
  }

  await load([frame, {...consensusDecision, box: null, ensemble: {...ensemble, selected_indices: [], samples: [
    ensemble.samples[0], {box: null, confidence: .1, presence: .2},
    {box: {left: -1, right: .2, top: .3, bottom: .5}, confidence: 'NaN', presence: .3}
  ]}}]);
  scrub(1);
  assert.equal(element('sample1').hidden, true);
  assert.equal(element('sample2').hidden, true);
  assert.match(element('sampleRow1').textContent, /presence 20.0%\nNo box/);
  assert.match(element('sampleRow2').textContent, /Confidence unavailable.*\nInvalid box/);
  await load([frame, {...consensusDecision, ensemble: undefined}]);
  scrub(1);
  assert.equal(element('ensembleCard').hidden, true, 'Single-call events clear earlier ensemble evidence');
  for (let i = 0; i < 3; i++) assert.equal(element('sample'+i).hidden, true);
  console.log('Offline recording review checks passed: local-only replay, sample/consensus evidence, exclusion, missing frames, and single-call compatibility.');
})().catch(error => { console.error(error); process.exitCode = 1; });

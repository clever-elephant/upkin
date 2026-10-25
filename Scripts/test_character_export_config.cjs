#!/usr/bin/env node
// Exercises discovery without launching a browser or modifying baked artwork.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { discoverSources, sourceHTML, mergeManifest, durationFor } = require('./export_character_frames.cjs');
(async () => {
  const sources = discoverSources();
  assert.equal(durationFor('grok', '32'), 8);
  assert.equal(durationFor('grok', '34'), 1);
  assert.equal(sources.grok.states['33'].loop, false);
  for (const source of Object.values(sources)) {
    const html = await sourceHTML(source.id);
    if (source.assetMarker) assert(!html.includes(source.assetMarker));
    if (source.runtime) assert(!html.includes(source.runtime.marker));
  }
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'character-source-'));
  try {
    const directory = path.join(temporary, 'Fourth');
    await fs.mkdir(directory);
    const states = JSON.parse(JSON.stringify(sources.grok.states));
    states['34'] = { seconds: 5, loop: true, staticFrame: 15, loopStartFrame: 15 };
    const config = { id: 'fourth', sourceHTML: 'scene.html', attributionDirectory: '.',
      assetMarker: '/* FOURTH_ASSETS */', states };
    await fs.writeFile(path.join(directory, 'export.json'), JSON.stringify(config));
    await fs.writeFile(path.join(directory, 'scene.html'), '<script>/* FOURTH_ASSETS */</script>');
    await fs.writeFile(path.join(directory, 'shape.svg'), '<svg/>');
    const found = discoverSources(temporary);
    assert.deepEqual(Object.keys(found), ['fourth']);
    assert((await sourceHTML('Fourth', found)).includes('"shape":"<svg/>"'));
    const existing = { name: 'Fourth', defaultFor: 'codex', sortOrder: 40, states: { '02': { frames: 1 } } };
    const merged = mergeManifest(existing, { '30': { frames: 60 } });
    assert.equal(merged.name, existing.name);
    assert.deepEqual(merged.defaultFor, existing.defaultFor);
    assert.equal(merged.sortOrder, existing.sortOrder);
    assert.deepEqual(Object.keys(merged.states), ['30', '02']);
    config.states['34'].loopStartFrame = 999;
    await fs.writeFile(path.join(directory, 'export.json'), JSON.stringify(config));
    assert.throws(() => discoverSources(temporary));
    console.log('PASS source discovery, fourth adapter, injection, metadata preservation, invalid loop boundary');
  } finally { await fs.rm(temporary, { recursive: true, force: true }); }
})().catch(error => { console.error(error); process.exitCode = 1; });

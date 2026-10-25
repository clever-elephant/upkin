#!/usr/bin/env node
// Tests the same deterministic source/clock used by the PNG exporter.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { chromium } = require('playwright');
const { sourceHTML, deterministicClock, durationFor } = require('./export_character_frames.cjs');
const root = path.resolve(__dirname, '..');
const selected = process.argv[2] || 'all';
assert(['all', 'grok'].includes(selected));
(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined, headless: true });
  const results = [];
  try {
    for (const pack of ['grok']) {
      const html = await sourceHTML('GrokBall');
      for (const id of ['02', '30', '32', '35', '11']) {
        const duration = durationFor(pack, id);
        const page = await browser.newPage({ viewport: { width: 36, height: 22 }, deviceScaleFactor: 2 });
        const errors = [];
        page.on('pageerror', e => errors.push(e.message));
        await page.addInitScript(deterministicClock);
        await page.goto('data:text/html;base64,' + Buffer.from(html).toString('base64'));
        await page.evaluate(id => setBallState(id, false, 0), id);
        const output = await page.evaluate(({ pack, id, duration }) => {
          const faceIds = new Map();
          const bodyPoses = new Set();
          const faces = [];
          const opens = [];
          const selectors = { '02': '.eyes-blink', '11': '.eyes-blink', '30': '.eyes-blink', '32': '.eyes-code', '35': '.eyes-blink' };
          for (let tick = 0; tick <= Math.round(duration * 3 * 60); tick++) {
            advanceFrame(tick * 1000 / 60);
            if (tick % 4) continue;
            let face, body, open;
            if (pack === 'grok') {
              const pose = ball._lastPose;
              face = JSON.stringify([pose.left.ring, pose.right.ring]);
              body = JSON.stringify(pose.body);
              open = [pose.left.open, pose.right.open];
            } else {
              const node = document.querySelector(selectors[id]);
              const style = getComputedStyle(node);
              face = id === '02' || id === '11' ? 'neutral' : style.transform + ':' + style.opacity;
              open = [style.transform];
              body = JSON.stringify([...document.querySelectorAll('svg g')]
                .filter(node => !node.closest('.eyes-blink,.eyes-anim,.eyes-code,.eyes-rect,.eyes-smile'))
                .map(node => { const s = getComputedStyle(node); return [s.transform, s.opacity]; }));
            }
            if (!faceIds.has(face)) faceIds.set(face, faceIds.size);
            faces.push(faceIds.get(face));
            opens.push(open);
            bodyPoses.add(body);
          }
          const svg = document.querySelector('svg');
          const before = pack === 'grok' ? ball._emoStart : JSON.stringify(document.getAnimations().map(a => a.currentTime));
          setBallState(id, false, 0);
          const after = pack === 'grok' ? ball._emoStart : JSON.stringify(document.getAnimations().map(a => a.currentTime));
          const sameStateKeepsPhase = before === after;
          const sameStateKeepsSVG = document.querySelector('svg') === svg;
          // A true waiting state interrupts within a round, not at its next boundary.
          if (id === '32') {
            advanceFrame(duration * 3 * 1000 + 2300);
            setBallState('35', false, 0);
          }
          return { faces, opens, bodyPoses: bodyPoses.size,
            sameStateKeepsSVG, sameStateKeepsPhase,
            waitingInterrupts: id !== '32' || currentState === '35' };
        }, { pack, id, duration });
        assert.deepEqual(errors, [], `${pack}/${id}: source errors`);
        assert(output.sameStateKeepsPhase, `${pack}/${id}: same state must preserve the action phase`);
        assert(output.waitingInterrupts, `${pack}/${id}: waiting must interrupt within a round`);
        assert(output.sameStateKeepsSVG, `${pack}/${id}: same state must not rebuild the source`);
        assert(output.bodyPoses > 5, `${pack}/${id}: holding a face must not freeze the body`);
        const alternating = id === '32' || (pack === 'grok' && id === '30');
        const changedAt = [];
        for (let i = 1; i < output.faces.length; i++) {
          if (output.faces[i] !== output.faces[i - 1]) changedAt.push(i);
        }
        if (alternating) {
          assert.equal(new Set(output.faces).size, 2, `${pack}/${id}: exactly two paired faces`);
          assert.equal(changedAt.length, 6, `${pack}/${id}: six full rounds have six boundary changes`);
          assert(changedAt.every((frame, i) => frame === (i + 1) * 60), `${pack}/${id}: no within-round changes or seam extras`);
          for (let i = 120; i < output.faces.length; i++) assert.equal(output.faces[i], output.faces[i % 120], 'A/B must close across repeated baked loops');
        } else assert.equal(changedAt.length, 0, `${pack}/${id}: neutral/thinking/waiting face must hold`);
        if (pack === 'grok') assert(output.opens.every(([l, r]) => Math.abs(l - r) < 1e-8), 'Both eyes blink together');
        const manifest = JSON.parse(await fs.readFile(path.join(root, 'Resources/CharacterFrames', pack, 'manifest.json'), 'utf8'));
        assert.equal(manifest.states[id].frames, Math.round(duration * 15), `${pack}/${id}: bake full declared periods`);
        assert.equal(manifest.states[id].fps, 15);
        results.push({ pack, id, seconds: duration * 3, faceChanges: changedAt.length, bodyPoses: output.bodyPoses, bakedFrames: manifest.states[id].frames });
        console.log(`PASS ${pack}/${id}: ${changedAt.length} paired changes across 3 full asset loops; body remains active; same-state source reused`);
        await page.close();
      }
    }
    const out = process.env.CHARACTER_CADENCE_QA;
    if (out) { await fs.mkdir(out, { recursive: true }); await fs.writeFile(path.join(out, `source-cadence-${selected}.json`), JSON.stringify(results, null, 2) + '\n'); }
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });

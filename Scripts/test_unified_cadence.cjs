#!/usr/bin/env node
// Cross-role contract and three complete source loops, including the baked seam.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { chromium } = require('playwright');
const { sourceHTML, deterministicClock, durationFor, discoverSources, sourceFrame } = require('./export_character_frames.cjs');
const root = path.resolve(__dirname, '..');
const packs = discoverSources();
(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined, headless: true });
  try {
    for (const [pack, config] of Object.entries(packs)) {
      const folder = config.folder;
      const manifest = JSON.parse(await fs.readFile(path.join(root, 'Resources/CharacterFrames', pack, 'manifest.json'), 'utf8'));
      for (const id of ['02', '30', '32', '35', '11', '33', '34']) {
        const duration = durationFor(pack, id);
        const state = manifest.states[id];
        assert.equal(state.frames, duration * 15, `${pack}/${id}: shared duration`);
        assert.equal(state.fps, 15);
        const intro = state.loopStartFrame ?? 0;
        assert.equal(state.loop, config.states[id].loop);
        assert.equal(intro, config.states[id].loopStartFrame ?? 0);
        const page = await browser.newPage({ viewport: { width: 36, height: 22 } });
        const errors = [];
        page.on('pageerror', error => errors.push(error.message));
        await page.addInitScript(deterministicClock);
        await page.goto('data:text/html;base64,' + Buffer.from(await sourceHTML(folder)).toString('base64'));
        await page.evaluate(id => setBallState(id, false, 0), id);
        const frame = await sourceFrame(page, config);
        const samples = await frame.evaluate(({ duration, loop }) => {
          // Round subpixel noise, not visible motion; compare only drawing elements, not debug labels.
          const rounded = value => String(value).replace(/-?\d*\.?\d+(?:e[+-]?\d+)?/gi, n => String(Math.round(Number(n) * 1000) / 1000));
          const snapshot = () => JSON.stringify([...document.querySelectorAll('svg *')]
            .filter(node => !node.closest('style,script,text'))
            .map(node => {
              const style = getComputedStyle(node);
              return [node.tagName, ...['transform', 'd', 'opacity', 'y1', 'y2', 'height', 'y', 'rx', 'ry', 'stroke-dashoffset'].map(a => rounded(node.getAttribute(a) ?? '')),
                rounded(style.transform), rounded(style.opacity)];
            }));
          const output = [];
          const ticks = Math.round(duration * (loop ? 3 : 1) * 60);
          for (let tick = 0; tick <= ticks; tick++) {
            advanceFrame(tick * 1000 / 60);
            if (tick % 4 === 0) output.push(snapshot());
          }
          return output;
        }, { duration, loop: state.loop });
        assert.deepEqual(errors, [], `${pack}/${id}: source errors`);
        assert(new Set(samples).size > 5, `${pack}/${id}: body remains animated`);
        if (state.loop) {
          const count = state.frames - intro;
          // Inspect every sample over two repeated seams, allowing only numerical rounding noise.
          const different = [];
          for (let n = intro + count; n < samples.length; n++) if (samples[n] !== samples[intro + (n - intro) % count]) different.push(n);
          if (different.length) {
            const n = different[0], a = JSON.parse(samples[n]), b = JSON.parse(samples[intro + (n - intro) % count]);
            const element = a.findIndex((value, index) => JSON.stringify(value) !== JSON.stringify(b[index]));
            console.error('First divergent drawing element:', n, element, a[element], b[element]);
          }
          assert.equal(different.length, 0, `${pack}/${id}: source loop diverges at frames ${different.slice(0, 8)}`);
        }
        console.log(`PASS ${pack}/${id}: ${duration}s / ${state.frames} frames; ${state.loop ? '3 complete source loops match' : 'complete one-shot'}`);
        await page.close();
      }
    }
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });

#!/usr/bin/env node
// Clawd's pixel gestures: stable faces, cycling operators, and no viewport clipping.
const assert = require('node:assert/strict');
const { chromium } = require('playwright');
const fs = require('node:fs/promises');
const path = require('node:path');
const { sourceHTML, deterministicClock, discoverSources } = require('./export_character_frames.cjs');
(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined, headless: true });
  try {
    const config = discoverSources().clawd;
    const html = await sourceHTML('clawd');
    assert(!html.includes('keyboard') && !html.includes('tap-a'), 'Work must not use keyboard/tapping assets');
    for (const [id, state] of Object.entries(config.states)) {
      const page = await browser.newPage({ viewport: { width: 36, height: 22 } });
      await page.addInitScript(deterministicClock);
      await page.goto('data:text/html;base64,' + Buffer.from(html).toString('base64'));
      await page.evaluate(id => setBallState(id, false), id);
      const result = await page.evaluate(({ id, state }) => {
        const faces = [], operators = [], clips = [];
        const timing = getComputedStyle(document.querySelector('#crab')).animationTimingFunction;
        if (timing !== (id === '33' || id === '34' ? 'ease-in-out' : 'linear')) throw new Error('Continuous loops; eased event animations');
        const torso = document.querySelector('#torso');
        if (torso.getAttribute('width') !== '11' || torso.getAttribute('height') !== '7') throw new Error('11x7 rectangular silhouette');
        for (const name of ['armL-up', 'armR-up']) {
          const claw = document.querySelector('#' + name);
          if (claw.children.length !== 1 || claw.firstElementChild.getAttribute('width') !== '2' || claw.firstElementChild.getAttribute('height') !== '2') throw new Error('Raised claws must preserve the base 2x2 shape');
        }
        const badgeBounds = document.querySelector('#error-mark').getBBox();
        if (badgeBounds.x !== 16 || badgeBounds.y !== 0 || badgeBounds.width !== 5 || badgeBounds.height !== 5) throw new Error('Error uses a fixed 5x5 upper-right pixel badge');
        for (const [name, rows] of [
          ['multiply', ['10001', '01010', '00100', '01010', '10001']],
          ['divide', ['00100', '00000', '11111', '00000', '00100']],
        ]) {
          const symbol = document.querySelector(`#math-${name} path`);
          rows.forEach((row, y) => [...row].forEach((pixel, x) => {
            if (symbol.isPointInFill(new DOMPoint(16 + x + 0.5, y + 0.5)) !== (pixel === '1'))
              throw new Error(`${name}: use the handwritten multiplication cross / division bar and dots`);
          }));
        }
        const eyes = [...document.querySelectorAll('#eyes-open rect')];
        if (Number(eyes[1].getAttribute('x')) - Number(eyes[0].getAttribute('x')) !== 6) throw new Error('6-unit eye spacing');
        const visible = node => {
          for (let n = node; n instanceof SVGElement; n = n.parentElement) {
            if (Number(getComputedStyle(n).opacity) === 0) return false;
          }
          return true;
        };
        const ticks = Math.round(state.seconds * 15) * (state.loop ? 3 : 1);
        for (let i = 0; i <= ticks; i++) {
          advanceFrame(i * 1000 / 15);
          const face = [...document.querySelectorAll('.face')].filter(visible)
            .map(n => n.id + ':' + getComputedStyle(n).transform).join(',');
          faces.push(face);
          const badge = document.querySelector('#error-mark');
          if (visible(badge) !== (id === '34')) throw new Error('Red X only appears during error');
          if (getComputedStyle(badge).fill !== 'rgb(201, 79, 67)') throw new Error('Error badge must stay red');
          if (id === '34' && getComputedStyle(badge).opacity !== '1') throw new Error('Error badge must not blink');
          operators.push([...document.querySelectorAll('.math')].filter(visible).map(n => n.id));
          for (const node of document.querySelectorAll('svg rect, svg path')) {
            if (!visible(node)) continue;
            const r = node.getBoundingClientRect();
            if (r.left < -0.01 || r.right > 32.01 || r.top < -0.01 || r.bottom > 22.01) clips.push([i, node.parentElement.id, r.x, r.y, r.right, r.bottom]);
          }
        }
        const before = document.getAnimations().map(a => a.currentTime);
        setBallState(id, false);
        const keepsPhase = JSON.stringify(before) === JSON.stringify(document.getAnimations().map(a => a.currentTime));
        setBallState('35', false);
        return { faces, operators, clips, keepsPhase, interrupts: document.body.dataset.s === '35' };
      }, { id, state });
      assert.equal(result.clips.length, 0, `${id}: clipped pixels ${JSON.stringify(result.clips.slice(0, 3))}`);
      assert(result.keepsPhase && result.interrupts, `${id}: preserve refresh phase and interrupt immediately`);
      const changes = result.faces.flatMap((face, i, all) => i && face !== all[i - 1] ? [i] : []);
      if (id === '30') {
        assert.deepEqual(changes, [60, 120, 180, 240, 300, 360], `${id}: paired face changes only at 4s boundaries`);
      } else if (id !== '02' && id !== '33') {
        assert.equal(changes.length, 0, `${id}: face holds throughout the gesture`);
      }
      if (id === '32') {
        assert.equal(state.seconds, 4, 'One complete operator cycle per 4s');
        assert(!html.includes('id="block"'), 'Work no longer carries a block');
        result.operators.forEach((operators, i) => assert.deepEqual(operators,
          [['math-plus', 'math-minus', 'math-multiply', 'math-divide'][Math.floor(i / 15) % 4]],
          `Work frame ${i}: exactly one operator, changing once per second across seams`));
      } else assert(result.operators.every(operators => operators.length === 0), `${id}: work operators stay hidden`);
      if (id === '02') assert.equal(changes.length, 6, 'One synchronized blink per 4s, no double blinks');
      if (id === '33') assert.deepEqual(changes, [8], 'Happy eyes enter once and hold after the flourish');
      if (['02', '30', '32', '35', '11'].includes(id)) {
        const directory = path.resolve(__dirname, '../Resources/CharacterFrames/clawd', id);
        const frames = await Promise.all(Array.from({ length: Math.round(state.seconds * 15) }, (_, n) => fs.readFile(path.join(directory, `${n}.png`))));
        let run = 1;
        // Include a second pass to catch a pause that crosses the baked seam.
        for (let n = 1; n < frames.length * 2; n++) {
          run = frames[n % frames.length].equals(frames[(n - 1) % frames.length]) ? run + 1 : 1;
          assert(run <= 3, `${id}: no baked still-frame hold longer than 200ms`);
        }
      }
      console.log(`PASS clawd/${id}: stable face, bounded pixel gestures, refresh/interrupt; ${id === '32' ? '4 ordered operators' : 'no work operators'}`);
      await page.close();
    }
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });

#!/usr/bin/env node
// Render README artwork from vector sources, never upscale menu-bar PNGs.
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
const { chromium } = require('playwright');
const { discoverSources, sourceHTML, sourceFrame, deterministicClock } = require('./export_character_frames.cjs');
const root = path.resolve(__dirname, '..');

async function main() {
  const sources = discoverSources();
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined, headless: true });
  try {
    for (const character of ['chatgpt', 'clawd', 'grok']) {
      const config = sources[character];
      for (const state of ['30', '32', '35', '33']) {
        const page = await browser.newPage({ viewport: { width: 36, height: 22 }, deviceScaleFactor: 12, colorScheme: 'light' });
        const errors = [];
        page.on('pageerror', error => errors.push(error.message));
        await page.addInitScript(deterministicClock);
        await page.goto('data:text/html;base64,' + Buffer.from(await sourceHTML(character)).toString('base64'));
        await page.evaluate(id => setBallState(id, false, 0), state);
        await sourceFrame(page, config);
        const directory = path.join(root, '.codex-qa/readme-frames', character, state);
        await fs.mkdir(directory, { recursive: true });
        const count = Math.round(config.states[state].seconds * 15);
        for (let frame = 0; frame < count; frame++) {
          for (let tick = frame === 0 ? 0 : (frame - 1) * 4 + 1; tick <= frame * 4; tick++) {
            for (const document of page.frames()) await document.evaluate(time => window.advanceFrame(time), tick * 1000 / 60);
          }
          const png = await page.screenshot({ omitBackground: true, animations: 'allow' });
          assert.equal(png.readUInt32BE(16), 432);
          assert.equal(png.readUInt32BE(20), 264);
          await fs.writeFile(path.join(directory, `${frame}.png`), png);
        }
        assert.deepEqual(errors, [], `${character}/${state}`);
        console.log(`${character}/${state}: ${count} frames at 432×264`);
        await page.close();
      }
    }
  } finally { await browser.close(); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });

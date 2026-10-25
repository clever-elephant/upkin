#!/usr/bin/env node
// Development-only bake; the app consumes PNGs without running a browser.
// NODE_PATH=/path/to/existing/node_modules node Scripts/export_character_frames.cjs
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const syncFS = require('node:fs');
const root = path.resolve(__dirname, '..');
const output = path.join(root, 'Resources/CharacterFrames');
const fps = 15;
const ids = ['02', '30', '32', '35', '33', '34', '11'];
// Source adapters are development inputs; PNG-only packs need no export config.
function discoverSources(resources = path.join(root, 'Resources')) {
  const sources = {};
  for (const entry of syncFS.readdirSync(resources, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const directory = path.join(resources, entry.name);
    const file = path.join(directory, 'export.json');
    if (!syncFS.existsSync(file)) continue;
    const config = JSON.parse(syncFS.readFileSync(file, 'utf8'));
    assert(/^[a-z0-9][a-z0-9_-]{0,79}$/.test(config.id), `Invalid source ID: ${file}`);
    assert(!sources[config.id], `Duplicate source ID: ${config.id}`);
    assert.equal(typeof config.sourceHTML, 'string');
    assert.equal(typeof config.attributionDirectory, 'string');
    assert.deepEqual(Object.keys(config.states).sort(), [...ids].sort());
    for (const [id, state] of Object.entries(config.states)) {
      const frames = Math.round(state.seconds * fps);
      assert(Number.isFinite(state.seconds) && frames >= 1 && frames <= 150, `${config.id}/${id}: duration`);
      assert(Math.abs(frames - state.seconds * fps) < 0.00001, `${config.id}/${id}: frame boundary`);
      assert.equal(typeof state.loop, 'boolean');
      assert(Number.isInteger(state.staticFrame) && state.staticFrame >= 0 && state.staticFrame < frames);
      if (state.loopStartFrame !== undefined) assert(state.loop && Number.isInteger(state.loopStartFrame) && state.loopStartFrame > 0 && state.loopStartFrame < frames);
    }
    sources[config.id] = { ...config, directory, folder: entry.name };
  }
  return sources;
}
function durationFor(pack, id) { return discoverSources()[pack].states[id].seconds; }
function mergeManifest(existing, states) {
  return { ...existing, version: 1, width: 72, height: 44, states: { ...existing?.states, ...states } };
}
async function sourceFrame(page, config) {
  if (!config.frameSelector) return page.mainFrame();
  await page.frameLocator(config.frameSelector).locator('svg').waitFor({ state: 'attached' });
  return (await page.locator(config.frameSelector).elementHandle()).contentFrame();
}

// Applied to every document, including srcdoc iframes, before artwork runs.
function deterministicClock() {
  let time = 1000, seed = 7, next = 1;
  let raf = new Map(), timers = new Map();
  Object.defineProperty(performance, 'now', { value: () => time });
  Date.now = () => 1700000000000 + time;
  Math.random = () => ((seed = (1664525 * seed + 1013904223) >>> 0) / 4294967296);
  window.requestAnimationFrame = fn => { const id = next++; raf.set(id, fn); return id; };
  window.cancelAnimationFrame = id => raf.delete(id);
  window.setTimeout = (fn, delay = 0) => { const id = next++; timers.set(id, { fn, at: time + delay }); return id; };
  window.clearTimeout = id => timers.delete(id);
  window.setInterval = (fn, delay = 0) => { const id = next++; timers.set(id, { fn, at: time + delay, repeat: delay }); return id; };
  window.clearInterval = window.clearTimeout;
  window.advanceFrame = value => {
    time = 1000 + value;
    for (const [id, timer] of [...timers]) if (timer.at <= time) {
      timers.delete(id);
      if (timer.repeat) timers.set(id, { ...timer, at: time + timer.repeat });
      timer.fn();
    }
    const callbacks = [...raf.values()]; raf.clear();
    callbacks.forEach(fn => fn(time));
    // Sample the right side of CSS step boundaries consistently (0.1 microsecond).
    // Screenshots must not advance the sampled animations.
    document.getAnimations().forEach(animation => { animation.pause(); animation.currentTime = value + 0.0001; });
  };
}

async function sourceHTML(folder, sources = discoverSources()) {
  const config = Object.values(sources).find(source => source.folder === folder || source.id === folder);
  assert(config, `Unknown source: ${folder}`);
  let html = await fs.readFile(path.resolve(config.directory, config.sourceHTML), 'utf8');
  if (config.runtime) {
    assert(html.includes(config.runtime.marker), `Missing runtime marker: ${folder}`);
    html = html.replace(config.runtime.marker, await fs.readFile(path.resolve(config.directory, config.runtime.file), 'utf8'));
  }
  if (config.assetMarker) {
    assert(html.includes(config.assetMarker), `Missing asset marker: ${folder}`);
    const assets = {};
    for (const file of await fs.readdir(config.directory)) {
      if (file.endsWith('.svg')) assets[file.slice(0, -4)] = await fs.readFile(path.join(config.directory, file), 'utf8');
    }
    html = html.replace(config.assetMarker, `const assets = ${JSON.stringify(assets).replace(/<\//g, '<\\/')};`);
  }
  return html;
}

async function main() {
  const packs = discoverSources();
  const { chromium } = require('playwright');
  const selectedPack = process.argv[2];
  const selectedIDs = process.argv.slice(3);
  assert(!selectedPack || Object.hasOwn(packs, selectedPack), 'Unknown character pack');
  assert(selectedIDs.every(id => ids.includes(id)), 'Unknown state ID');

  const browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH || undefined, headless: true,
  });
  const results = {};
  try {
    for (const [name, config] of Object.entries(packs)) {
      const folder = config.folder;
      if (selectedPack && selectedPack !== name) continue;
      const packOutput = path.join(output, name);
      let existing = {};
      try { existing = JSON.parse(await fs.readFile(path.join(packOutput, 'manifest.json'), 'utf8')); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      const manifest = mergeManifest(existing, {});
      const html = await sourceHTML(folder);
      await fs.mkdir(packOutput, { recursive: true });
      for (const id of selectedIDs.length ? selectedIDs : ids) {
        const { seconds, ...playback } = config.states[id];
        const frames = Math.round(seconds * fps);
        const page = await browser.newPage({ viewport: { width: 36, height: 22 }, deviceScaleFactor: 2, colorScheme: 'light' });
        const errors = [];
        page.on('pageerror', error => errors.push(error.message));
        await page.addInitScript(deterministicClock);
        await page.goto('data:text/html;base64,' + Buffer.from(html).toString('base64'));
        await page.evaluate(id => setBallState(id, false, 0), id);
        await sourceFrame(page, config);
        const directory = path.join(packOutput, id);
        await fs.mkdir(directory, { recursive: true });
        // Remove only old numbered output frames when an export duration changes.
        for (const file of await fs.readdir(directory)) if (/^\d+\.png$/.test(file)) await fs.unlink(path.join(directory, file));
        const hashes = new Set();
        for (let frame = 0; frame < frames; frame++) {
          // Integrate spring-based JS at60Hz, sample at15Hz.
          for (let tick = frame === 0 ? 0 : (frame - 1) * 4 + 1; tick <= frame * 4; tick++) {
            for (const document of page.frames()) await document.evaluate(time => window.advanceFrame(time), tick * 1000 / 60);
          }
          const png = await page.screenshot({ omitBackground: true, animations: 'allow' });
          assert.equal(png.readUInt32BE(16), 72); assert.equal(png.readUInt32BE(20), 44);
          hashes.add(crypto.createHash('sha256').update(png).digest('hex'));
          await fs.writeFile(path.join(directory, `${frame}.png`), png);
        }
        assert.equal(errors.length, 0, `${name}/${id}: ${errors.join('; ')}`);
        assert(hashes.size > 1, `${name}/${id} has no animation`);
        manifest.states[id] = { frames, fps, ...playback };
        results[`${name}/${id}`] = { frames, uniqueFrames: hashes.size };
        console.log(`PASS ${name}/${id}: ${frames} frames, ${hashes.size} distinct`);
        await page.close();
      }
      await fs.writeFile(path.join(packOutput, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
      const sourceFolder = path.resolve(config.directory, config.attributionDirectory);
      await fs.copyFile(path.join(sourceFolder, 'LICENSE'), path.join(packOutput, 'LICENSE'));
      const source = await fs.readFile(path.join(sourceFolder, 'SOURCE.txt'), 'utf8');
      await fs.writeFile(path.join(packOutput, 'SOURCE.txt'), source + '\nOffline PNG derivatives exported by Scripts/export_character_frames.cjs from the local menu-bar adapter.\n72x44 pixels are 2x resolution for the existing 36x22pt viewport, not historical runner frames.\n15 FPS, seeded RNG, fixed 60Hz JS integration; CSS sampled at fixed times. All loops start at phase zero on the shared 4-second main beat.\nPlayback durations and optional intro-to-loop boundaries are declared by this source adapter export.json and copied into manifest.json.\nThe original scripts above remain development inputs only; no browser runtime is needed to play these PNGs.\n');
    }
    const validationFile = path.join(output, 'export-validation.json');
    let prior = {};
    try { prior = JSON.parse(await fs.readFile(validationFile, 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    for (const [pack, states] of Object.entries(results)) prior[pack] = { ...prior[pack], ...states };
    await fs.writeFile(validationFile, JSON.stringify(prior, null, 2) + '\n');
  } finally { await browser.close(); }
}

module.exports = { sourceHTML, deterministicClock, durationFor, discoverSources, mergeManifest, sourceFrame };
if (require.main === module) main().catch(error => { console.error(error); process.exitCode = 1; });

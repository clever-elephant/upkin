// Development-only: unchanged finite effects match upstream; loop cadence is intentional.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '..');
const cycles = { '02': [0], '30': [8, 16], '32': [7, 16], '35': [10], '11': [14] };

(async () => {
  const runtime = await fs.readFile(path.join(root, 'ThirdParty/GrokBall/grok-ball.js'), 'utf8');
  const html = (await fs.readFile(path.join(root, 'Resources/GrokBall/index.html'), 'utf8'))
    .replace('/* GROK_BALL_RUNTIME */', runtime);
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined, headless: true });
  const results = [];
  async function pageFor(document) {
    const page = await browser.newPage({ viewport: { width: 36, height: 22 } });
    await page.addInitScript(() => {
      window.captureTime = 1000;
      Object.defineProperty(performance, 'now', { value: () => window.captureTime });
      let seed = 7;
      Math.random = () => ((seed = (1664525 * seed + 1013904223) >>> 0) / 4294967296);
      window.requestAnimationFrame = () => 1;
      window.cancelAnimationFrame = () => {};
      window.scheduled = [];
      window.nextTimer = 1;
      window.setTimeout = (fn, delay) => {
        const id = window.nextTimer++;
        window.scheduled.push({ id, at: window.captureTime + delay, fn });
        return id;
      };
      window.clearTimeout = id => { window.scheduled = window.scheduled.filter(t => t.id !== id); };
      window.tickAt = time => {
        window.captureTime = time;
        const due = window.scheduled.filter(t => t.at <= time);
        window.scheduled = window.scheduled.filter(t => t.at > time);
        for (const timer of due) timer.fn();
      };
    });
    await page.goto('data:text/html;base64,' + Buffer.from(document).toString('base64'));
    return page;
  }
  try {
    // Keep full upstream-equivalence coverage for both unchanged one-shot states.
    for (const id of ['33', '34']) {
      const outputs = [];
      for (const adapted of [false, true]) {
        const reference = `<meta charset="utf-8"><div id="ball" style="width:22px;height:22px"></div><script>${runtime}</script><script>
          const ball = GrokBall.create('#ball');
        </script>`;
        const page = await pageFor(adapted ? html : reference);
        outputs.push(await page.evaluate(({ id, adapted }) => {
          const duration = id === '33' ? 2.2 : 1;
          if (adapted) setBallState(id, false, duration);
          else { ball.setActive(true); ball.setEmotion(id); setTimeout(() => ball.setActive(false), duration * 1000); }
          const output = [];
          for (let frame = 0; frame <= 1800; frame++) {
            window.tickAt(1000 + frame * 1000 / 60);
            if (ball._active) ball._tick(window.captureTime);
            output.push(ball.ball.svg.outerHTML);
          }
          return output;
        }, { id, adapted }));
        await page.close();
      }
      assert.deepEqual(outputs[1], outputs[0], `Upstream finite effect changed: ${id}`);
      results.push({ id, identical: true, frames: 1801, seconds: 30, fps: 60 });
      console.log(`PASS ${id}: 1801 SVG frames identical to upstream across30s @60Hz`);
    }
    for (const [id, faces] of Object.entries(cycles)) {
      const page = await pageFor(html);
      const frames = await page.evaluate(id => {
        setBallState(id, false);
        const initialStart = cycleStart;
        const output = [];
        for (let frame = 0; frame <= 960; frame++) {
          window.tickAt(1000 + frame * 1000 / 60);
          if (frame === 120) setBallState(id, false); // An identical refresh must not reset phase.
          if (cycleStart !== initialStart) throw new Error('Identical state refresh reset the cycle');
          ball._tick(window.captureTime);
          if (frame % 4) continue;
          const body = ball.ball.svg.querySelector(':scope > g:not([pointer-events])');
          const eyes = [...body.querySelectorAll(':scope > path')].slice(1);
          output.push({ frame: frame / 4, expr: ball._exprIdx,
            rings: JSON.stringify([ball._lastPose.left.ring, ball._lastPose.right.ring]),
            eyes: eyes.map(eye => eye.getAttribute('d') + eye.getAttribute('transform')).join('|'),
            body: body.getAttribute('transform'), svg: frame % 240 === 0 ? ball.ball.svg.outerHTML : null });
        }
        return output;
      }, id);
      for (let cycle = 0; cycle < 4; cycle++) {
        const samples = frames.slice(cycle * 60, (cycle + 1) * 60);
        assert(samples.every(frame => frame.expr === faces[cycle % faces.length]), `${id}: unexpected mid-cycle face`);
        assert.equal(new Set(samples.map(frame => frame.rings)).size, 1, `${id}: eye rings changed inside cycle`);
        assert.equal(new Set(samples.map(frame => frame.eyes)).size, 1, `${id}: complete facial pose changed inside cycle`);
        assert(new Set(samples.map(frame => frame.body)).size > 15, `${id}: body stopped animating`);
      }
      assert.equal(frames[0].body, frames[120].body, `${id}: body8s seam changed`);
      assert.equal(frames[0].svg, frames[120].svg, `${id}: whole8s source loop does not close`);
      assert.equal(frames[0].svg, frames[240].svg, `${id}: second8s source loop does not close`);
      results.push({ id, periodSeconds: 4, exportedSeconds: faces.length * 4,
        faces, stableFacialPoseWithinCycle: true, continuousBody: true, checkedSeconds: 16, fps: 15 });
      console.log(`PASS ${id}: four complete4s cycles, stable full face, continuous body, two closed8s seams`);
      await page.close();
    }
    const qa = path.join(root, '.codex-qa/grok-cadence-20261024');
    await fs.mkdir(qa, { recursive: true });
    await fs.writeFile(path.join(qa, 'reference-result.json'), JSON.stringify(results, null, 2) + '\n');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });

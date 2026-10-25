#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/.codex-qa/core-animation-20261024}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/native-performance.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
cd "$ROOT"
if ! grep -q 'CAKeyframeAnimation' Sources/Upkin/GrokBallView.swift; then
    echo 'Expected shipping Core Animation renderer, not the old timer renderer' >&2; exit 1
fi
swift build -c release --product Upkin
BIN="$(swift build -c release --show-bin-path)"
cat > "$TEMP/probe.swift" <<'SWIFT'
import AppKit
import UpkinCore
import CoreImage.CIFilterBuiltins

@MainActor final class Probe {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let characterView = GrokBallView(character: "grok")
    private let runnerImage = NSImage(systemSymbolName: "terminal", accessibilityDescription: "fixture fallback")!
    private var snapshot: CodexUsageSnapshot?
    private var menuBarAnimationKey = ""
    private var menuBarRenderKey = ""
    private let popover = StatusPopoverController(refresh: {}, openConversation: { _ in })
    private let output = URL(fileURLWithPath: CommandLine.arguments[1])
    private let pixelsOnly = ProcessInfo.processInfo.environment["NATIVE_BENCH_PIXELS_ONLY"] == "1"
    private let seconds = Double(ProcessInfo.processInfo.environment["NATIVE_BENCH_SECONDS"] ?? "18") ?? 18
    // SHIPPING_BACKDROP
    // SHIPPING_UPDATE_IMAGE

    private func emit(_ stage: String) throws {
        let button = self.statusItem.button!
        let screen = button.window!.convertToScreen(button.convert(button.bounds, to: nil))
        let top = NSScreen.screens.first!.frame.maxY - screen.maxY
        let animations = (self.characterView.animationLayer.animationKeys() ?? []).compactMap { key -> [String: Any]? in
            guard let value = self.characterView.animationLayer.animation(forKey: key) as? CAKeyframeAnimation else { return nil }
            return ["key": key, "duration": value.duration, "values": value.values?.count ?? 0,
                    "calculationMode": value.calculationMode.rawValue]
        }
        let visible = button.window!.isVisible && button.window!.occlusionState.contains(.visible)
        let info: [String: Any] = ["stage": stage, "visible": visible, "realStatusItem": true,
            "windowNumber": button.window!.windowNumber, "buttonWidth": button.bounds.width,
            "backingScale": button.window!.backingScaleFactor,
            "screenRect": [Int(floor(screen.minX)), Int(floor(top)), Int(ceil(screen.width)), Int(ceil(screen.height))],
            "roleLocalX": self.characterView.frame.minX, "roleWidth": self.characterView.frame.width,
            "loadedFrames": self.characterView.loadedFrameCount, "animations": animations]
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
            .write(to: self.output.appendingPathComponent("stage.json"), options: .atomic)
        if !stage.hasPrefix("pixels-") {
            try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
                .write(to: self.output.appendingPathComponent("renderer-\(stage).json"), options: .atomic)
        }
    }

    private func stage(_ name: String, pixels: Bool = false, minimumSeconds: Double = 8) async throws {
        precondition(self.statusItem.button!.window != nil, "Must use a real NSStatusItem")
        try self.emit(name)
        try await Task.sleep(for: .seconds(self.pixelsOnly ? 1 : max(minimumSeconds, self.seconds)))
        if pixels {
            let ack = self.output.appendingPathComponent("pixels-\(name).done")
            try? FileManager.default.removeItem(at: ack)
            try self.emit("pixels-" + name)
            for _ in 0..<300 {
                if FileManager.default.fileExists(atPath: ack.path) { break }
                try self.emit("pixels-" + name)
                try await Task.sleep(for: .milliseconds(100))
            }
            precondition(FileManager.default.fileExists(atPath: ack.path), "Screen capture controller did not finish")
        }
    }

    private func configure(_ character: String, _ emotion: GrokBallEmotion, reduced: Bool = false) {
        self.characterView.setCharacter(character)
        precondition(self.characterView.show(emotion, reduceMotion: reduced))
        self.characterView.isHidden = false
        self.menuBarAnimationKey = character + emotion.rawValue + String(reduced)
        self.updateMenuBarImage()
    }

    func run() async throws {
        defer {
            self.popover.popover.close()
            self.characterView.stop()
            NSStatusBar.system.removeStatusItem(self.statusItem)
        }
        try await Task.sleep(for: .milliseconds(500))
        self.configure("grok", .idle, reduced: true)
        try await self.stage("baseline-static", pixels: true)
        for character in CharacterFrames.catalog.packs.map(\.id) {
            if !self.pixelsOnly {
                self.configure(character, .idle)
                try await self.stage("idle-" + character)
            }
            self.configure(character, .working)
            try await self.stage("working-" + character, pixels: true)
        }
        self.configure("grok", .working, reduced: true)
        try await self.stage("reduced", pixels: true)
        if self.pixelsOnly { try self.emit("done"); return }
        let now = Date().timeIntervalSince1970
        let conversations = (0..<12).map { index in
            Conversation(id: "local-performance-\(index)",
                provider: index % 3 == 0 ? nil : index % 3 == 1 ? .grok : .claude,
                title: "Local fixture \(index + 1)", phase: .working, updatedAt: now, startedAt: now - 90)
        }
        self.popover.update(snapshot: nil, session: CodexSessionActivitySnapshot(
            activeThreadCount: 12, loadedThreadCount: 12, conversations: conversations),
            agents: AgentActivitySnapshot(), error: nil, refreshing: false)
        self.popover.toggle(relativeTo: self.statusItem.button!)
        precondition(self.popover.popover.isShown)
        try await self.stage("list-12-visible-animation")
        self.popover.popover.close()
        for total in [30, 60] {
            try self.emit("transition-cycles-\(total / 30)")
            for _ in 0..<30 {
                self.popover.toggle(relativeTo: self.statusItem.button!)
                precondition(self.popover.popover.isShown)
                try await Task.sleep(for: .milliseconds(80))
                self.popover.popover.close()
                try await Task.sleep(for: .milliseconds(80))
            }
            precondition(!self.popover.popover.isShown && self.popover.durationTimer == nil)
            // Identical state for both batches and baseline; distinguish first-use retention from growth.
            self.configure("grok", .idle, reduced: true)
            try await self.stage("after-\(total)-close-cycles", minimumSeconds: 18)
        }
        try self.emit("done")
    }
}

@main @MainActor struct Check {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Serial native performance benchmark")
        Task { @MainActor in
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do { try await Probe().run(); NSApp.terminate(nil) }
            catch { print(error); exit(1) }
        }
        NSApp.run()
    }
}
SWIFT
# Reuse the actual shipping status-button integration, including its source-out
# backdrop and architecture-specific static fallback. Never duplicate that wiring.
python3 - "$ROOT" "$TEMP/probe.swift" "$OUT" <<'PY'
import hashlib,json,pathlib,re,sys
root,temp,out=map(pathlib.Path,sys.argv[1:])
source=(root/'Sources/Upkin/main.swift').read_text()
backdrop=re.search(r'    private let characterBackdrop: CALayer = \{.*?\n    \}\(\)',source,re.S)
start=source.index('    private func updateMenuBarImage() {')
end=source.index('\n    private let runnerImage',start)
assert backdrop and '.attach(to: button)' in source[start:end], 'Shipping CA status-button wiring is missing'
probe=temp.read_text().replace('    // SHIPPING_BACKDROP',backdrop.group()).replace('    // SHIPPING_UPDATE_IMAGE',source[start:end])
temp.write_text(probe)
inputs=['Sources/Upkin/main.swift','Sources/Upkin/GrokBallView.swift',
        'Sources/Upkin/MenuBarQuotaImage.swift','Sources/Upkin/StatusPopoverController.swift',
        'Sources/Upkin/ConversationIcons.swift','Sources/Upkin/CharacterPreviewController.swift',
        'Sources/Upkin/ConversationLauncher.swift','Sources/Upkin/CompletionNotificationController.swift']
(out/'source-sha256.json').write_text(json.dumps({p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in inputs},indent=2))
(out/'compiled-fixture.swift').write_text(probe)
PY
CORE_OBJECTS=()
for FILE in "$ROOT"/Sources/UpkinCore/*.swift; do
    CORE_OBJECTS+=("$BIN/UpkinCore.build/$(basename "$FILE").o")
done
swiftc -O -parse-as-library -swift-version 6 -I "$BIN/Modules" "$TEMP/probe.swift" \
    "$ROOT/Sources/Upkin/GrokBallView.swift" "$ROOT/Sources/Upkin/ConversationIcons.swift" \
    "$ROOT/Sources/Upkin/MenuBarQuotaImage.swift" "$ROOT/Sources/Upkin/StatusPopoverController.swift" \
    "$ROOT/Sources/Upkin/CharacterPreviewController.swift" "$ROOT/Sources/Upkin/ConversationLauncher.swift" "$ROOT/Sources/Upkin/CompletionNotificationController.swift" \
    "${CORE_OBJECTS[@]}" -o "$TEMP/check"
if [[ "${NATIVE_BENCH_COMPILE_ONLY:-0}" == "1" ]]; then
    echo "PASS: performance fixture compiled from shipping CA/status-item/popover sources; no UI started"
    exit 0
fi
python3 - "$TEMP/check" "$OUT" <<'PY'
import json,math,os,pathlib,statistics,struct,subprocess,sys,time,zlib
binary,folder=sys.argv[1:]; root=pathlib.Path(folder)
pixels_only=os.environ.get('NATIVE_BENCH_PIXELS_ONLY')=='1'
quota_reference=None; quota_mask=None; quota_gaps=None
(root/'stage.json').unlink(missing_ok=True)

def cpu_seconds(clock):
    days,_,clock=clock.rpartition('-')
    fields=list(map(float,clock.split(':')))
    return (int(days)*86400 if days else 0)+sum(value*60**i for i,value in enumerate(reversed(fields)))

def processes():
    result={}
    for line in subprocess.check_output(['ps','-axo','pid=,time=,rss=,comm='],text=True).splitlines():
        fields=line.split(None,3)
        if len(fields)==4:
            pid,clock,rss,command=fields
            result[int(pid)]={'cpu':cpu_seconds(clock),'rss_mib':int(rss)/1024,'command':command}
    return result

def rgba(path):
    # Decode macOS screencapture's ordinary RGB/RGBA PNG without extra dependencies.
    data=path.read_bytes(); assert data[:8]==b'\x89PNG\r\n\x1a\n'
    pos=8; compressed=b''
    while pos<len(data):
        size=struct.unpack('>I',data[pos:pos+4])[0]; kind=data[pos+4:pos+8]; value=data[pos+8:pos+8+size];pos+=size+12
        if kind==b'IHDR': width,height,depth,color,_,_,interlace=struct.unpack('>IIBBBBB',value)
        if kind==b'IDAT':compressed+=value
    assert depth==8 and color in (2,6) and interlace==0,(depth,color,interlace)
    channels=3 if color==2 else 4; stride=width*channels; raw=zlib.decompress(compressed); previous=bytearray(stride); rows=[];pos=0
    for _ in range(height):
        filter_type=raw[pos]; row=bytearray(raw[pos+1:pos+1+stride]);pos+=stride+1
        for x in range(stride):
            a=row[x-channels] if x>=channels else 0;b=previous[x];c=previous[x-channels] if x>=channels else 0
            prediction=a+b-c; candidates=(abs(prediction-a),abs(prediction-b),abs(prediction-c))
            paeth=(a,b,c)[candidates.index(min(candidates))]
            row[x]=(row[x]+(0,a,b,(a+b)//2,paeth)[filter_type])&255
        rows.append(bytes(row));previous=row
    return width,height,channels,rows

def contrast(image,x,y,gaps):
    _,_,channels,rows=image
    luminance=lambda row: sum(rows[row][x*channels:x*channels+3])/3
    return luminance(y)-statistics.median(luminance(y+offset) for offset in gaps)

def glyph_mask(image,left,right,scale):
    gaps=[round(offset*scale) for offset in (-4,-3,3,4)]
    margin=max(map(abs,gaps)); height=image[1]
    candidates=[(x,y,contrast(image,x,y,gaps)) for y in range(margin,height-margin) for x in range(left,right)]
    threshold=max(20,max(abs(value) for _,_,value in candidates)*.65)
    mask=[(x,y,value) for x,y,value in candidates if abs(value)>=threshold]
    assert len(mask)>=6,'Static baseline has no detectable quota glyph'
    return mask,gaps

def glyph_match(image,mask,gaps):
    # Fixed baseline stroke coordinates/signs: a stable blank quota does not pass.
    return sum(contrast(image,x,y,gaps)*(1 if expected>0 else -1)>=max(12,abs(expected)*.45)
               for x,y,expected in mask)/len(mask)

def erased_glyph(image,mask,gaps):
    width,height,channels,source=image; rows=[bytearray(row) for row in source]
    for x,y,_ in mask:
        for channel in range(3):
            rows[y][x*channels+channel]=round(statistics.median(source[y+offset][x*channels+channel] for offset in gaps))
    return width,height,channels,rows

def point_crop(image,stage,offset,width):
    # A fixed point-grid makes1x/2x screenshots comparable without imaging libraries.
    source_width,source_height,channels,source=image
    scale_x=source_width/stage['screenRect'][2];scale_y=source_height/stage['screenRect'][3]
    rows=[]
    for y in range(22):
        sy=min(source_height-1,int((y+.5)*scale_y));row=bytearray()
        for x in range(width):
            sx=max(0,min(source_width-1,int((stage['roleLocalX']+offset+x+.5)*scale_x)))
            row.extend(source[sy][sx*channels:sx*channels+3])
        rows.append(bytes(row))
    return width,22,3,rows

def geometry(stage):
    return tuple(stage['screenRect']),stage['roleLocalX'],stage.get('backingScale'),stage['windowNumber']

def capture(stage):
    global quota_reference,quota_mask,quota_gaps
    name=stage['stage'][7:];directory=root/'screen'/name;directory.mkdir(parents=True,exist_ok=True)
    roles=[];quotas=[];geometries=[]
    for index in range(12):
        file=directory/f'{index:02}.png'
        for attempt in range(3):
            before=json.loads((root/'stage.json').read_text())
            if before['stage']!=stage['stage']:raise RuntimeError('Stage changed before screen capture: '+name)
            rect=','.join(map(str,before['screenRect']))
            subprocess.run(['/usr/sbin/screencapture','-x','-t','png','-R',rect,str(file)],check=True,capture_output=True)
            time.sleep(.11) # Allow the100ms Swift geometry refresh to report mid-shot screen moves.
            after=json.loads((root/'stage.json').read_text())
            stable=after['stage']==before['stage'] and geometry(after)==geometry(before)
            geometries.append({'capture':index,'attempt':attempt,'before':before,'after':after,'stable':stable})
            (directory/'capture-geometry.json').write_text(json.dumps(geometries,indent=2))
            if after['stage']!=stage['stage']:raise RuntimeError('Stage changed during screen capture: '+name)
            if stable:break
        else:raise RuntimeError('Status item moved during three capture attempts: '+name)
        image=rgba(file)
        roles.append(b''.join(point_crop(image,before,0,32)[3]))
        quotas.append(point_crop(image,before,32,34))
        time.sleep(.10)
    quota=[b''.join(image[3]) for image in quotas]
    negative_control=None
    if quota_reference is None:
        quota_reference=quota[0]
        quota_mask,quota_gaps=glyph_mask(quotas[0],0,34,1)
        negative_control=glyph_match(erased_glyph(quotas[0],quota_mask,quota_gaps),quota_mask,quota_gaps)
        assert negative_control<.85,'Negative control must reject erased quota glyphs'
    matches=[glyph_match(image,quota_mask,quota_gaps) for image in quotas]
    quota_change=max(sum(abs(a-b) for a,b in zip(quota_reference,value))/len(value) for value in quota)
    groups={}
    for value,entry in zip(roles,[entry for entry in geometries if entry['stable']]):
        groups.setdefault(geometry(entry['before']),[]).append(value)
    motion_groups=[{'screen_rect':list(key[0]),'backing_scale':key[2],'captures':len(values),'unique_role_pixels':len(set(values))} for key,values in groups.items()]
    unique=max((group['unique_role_pixels'] for group in motion_groups if group['captures']>=3),default=0)
    differences=[sum(abs(a-b) for a,b in zip(roles[i-1],roles[i]))/len(roles[i]) for i in range(1,len(roles))]
    result={'captures':len(roles),'unique_role_pixels':unique,'mean_consecutive_pixel_change':round(statistics.mean(differences),4),
            'max_consecutive_pixel_change':round(max(differences),4),'motion_groups':motion_groups,
            'screen_rects':[entry['before']['screenRect'] for entry in geometries if entry['stable']],
            'comparison_grid':'Nearest-neighbor point-grid RGB: role32x22,quota34x22; geometry refreshed before/after every shot',
            'quota_max_mean_pixel_change_from_static_baseline':round(quota_change,4),
            'quota_glyph_mask_pixels':len(quota_mask),'quota_min_glyph_match_fraction':round(min(matches),4),
            'quota_erased_negative_control_match_fraction':negative_control,
            'scope':'Actual composited menu-bar screen pixels, not CALayer model contents or NSView.cacheDisplay'}
    (directory/'pixel-validation.json').write_text(json.dumps(result,indent=2))
    (root/f'pixels-{name}.done').write_text('captured')
    return result

def pixel_failures(pixels):
    failures=[]
    for name,pixel in pixels.items():
        if 'working-' in name and pixel['unique_role_pixels']<3:failures.append(name+' is static/blank on actual screen')
        if pixel['quota_min_glyph_match_fraction']<.85:failures.append(name+' expected baseline quota glyphs disappeared/lost contrast')
    return failures

baseline={} if pixels_only else processes(); websocket_baseline={pid for pid,value in baseline.items() if 'WebKit.' in value['command']}
window_server=next((pid for pid,value in baseline.items() if value['command'].endswith('/WindowServer')),None)
p=subprocess.Popen([binary,folder],stdout=(root/'performance-fixture.log').open('w'),stderr=subprocess.STDOUT)
rows=[];footprints={};starts={};previous=None;new_webkit=set();pixels={};stages={}
try:
    while p.poll() is None:
        time.sleep(1)
        if p.poll() is not None:break
        now=time.monotonic()
        if pixels_only:
            if (root/'stage.json').exists():
                stage=json.loads((root/'stage.json').read_text());name=stage['stage']
                if name.startswith('pixels-') and name not in pixels:pixels[name]=capture(stage)
            continue
        table=processes()
        if p.pid not in table:continue
        stage=json.loads((root/'stage.json').read_text()) if (root/'stage.json').exists() else {'stage':'warmup','visible':False}
        name=stage['stage'];starts.setdefault(name,now);stages[name]=stage
        new_webkit.update(pid for pid,value in table.items() if 'WebKit.' in value['command'] and pid not in websocket_baseline)
        if previous:
            elapsed=now-previous['time']
            row={'stage':name,'time':now,'visible':stage['visible'],'cpu':max(0,(table[p.pid]['cpu']-previous['cpu'])/elapsed*100),
                 'rss_mib':table[p.pid]['rss_mib']}
            if window_server in table and previous.get('window_server') is not None:
                row['window_server_cpu']=max(0,(table[window_server]['cpu']-previous['window_server'])/elapsed*100)
            rows.append(row)
        previous={'time':now,'cpu':table[p.pid]['cpu'],'window_server':table.get(window_server,{}).get('cpu')}
        if name.startswith('pixels-'):
            if name not in pixels:pixels[name]=capture(stage)
            continue
        if name in ('warmup','done') or name.startswith('transition-'):continue
        footprint_delay=14 if name.startswith('after-') else 6
        if name not in footprints and now-starts[name]>footprint_delay:
            path=root/f'footprint-{name}.json'
            result=subprocess.run(['footprint','-p',str(p.pid),'--noCategories','-j',str(path)],capture_output=True,text=True)
            (root/f'footprint-{name}.txt').write_text(result.stdout+result.stderr)
            if result.returncode or not path.exists():raise RuntimeError('footprint failed for '+name)
            footprints[name]=json.loads(path.read_text())['processes'][0]['footprint']/1048576
    if p.wait()!=0:raise RuntimeError((root/'performance-fixture.log').read_text())
except BaseException:
    if p.poll() is None:p.terminate();p.wait(timeout=10)
    raise
finally:
    if not pixels_only:(root/'performance-raw.json').write_text(json.dumps(rows,indent=2))

if pixels_only:
    result={'mode':'pixels-only','context':'Actual NSStatusItem screen pixel revalidation only; no CPU/footprint measurement or popover-cycle test.',
            'pixels':pixels,'failures':pixel_failures(pixels)}
    (root/'pixels-only.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
    if result['failures']:raise RuntimeError('; '.join(result['failures']))
    sys.exit(0)

summary={}
for name,stage in stages.items():
    if name in ('warmup','done') or name.startswith(('pixels-','transition-')):continue
    duration=max(18 if name.startswith('after-') else 8,float(os.environ.get('NATIVE_BENCH_SECONDS','18')))
    valid=[r for r in rows if r['stage']==name and 3<=r['time']-starts[name]<duration-1 and r['visible']]
    if not valid or name not in footprints:raise RuntimeError('Missing visible steady-state samples/footprint: '+name)
    summary[name]={'cpu_mean':round(statistics.mean(r['cpu'] for r in valid),3),'cpu_peak':round(max(r['cpu'] for r in valid),3),
                   'footprint_mib':round(footprints[name],2),'rss_mean_mib':round(statistics.mean(r['rss_mib'] for r in valid),2),'samples':len(valid)}
    ws=[r['window_server_cpu'] for r in valid if 'window_server_cpu' in r]
    if ws:summary[name]['global_window_server_cpu_mean']=round(statistics.mean(ws),3)
result={'context':'Shipping CA renderer + exact extracted shipping status-button wiring + shipping NSPopover. Actual NSStatusItem; no real account/RPC/network calls. CPU100%=one logical core. Screen capture stages excluded from CPU summaries.',
        'window_server_note':'Global process across all displays/apps; contains unrelated desktop/cursor noise, not attributable to this tool. Compare static baseline only as context.',
        'pid':p.pid,'summary':summary,'pixels':pixels,'new_webkit_pids_during_test':sorted(new_webkit),
        'post_close_footprint_delta_mib':round(footprints['after-30-close-cycles']-footprints['baseline-static'],2),
        'second_30_cycles_footprint_delta_mib':round(footprints['after-60-close-cycles']-footprints['after-30-close-cycles'],2),
        'retention_note':'Two finite batches show short-run retention/platform behavior, not a long-duration leak verdict.'}
(root/'performance.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
failures=pixel_failures(pixels)
if failures:raise RuntimeError('; '.join(failures))
PY

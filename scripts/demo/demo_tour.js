// VideoScan demo tour — drives the RUNNING app through Accessibility, slowly.
//
//   osascript -l JavaScript ~/dev/VideoScan/scripts/demo/demo_tour.js [pace] [--say]
//
//   pace   seconds to linger on each stop (default 6)
//   --say  narrate each stop with the system voice
//
// TAKE OVER at any moment: move the mouse, or press ⌘ (e.g. ⌘.).
// The tour stops at once and leaves the app where it is.
//
// It only clicks tabs, opens the Show menu, and runs Walk Tree → Show on map.
// It never edits, deletes or starts a job. The Show ▸ "Events & Copies as
// Folders" toggle is put back the way it was found.
//
// Needs: System Settings ▸ Privacy & Security ▸ Accessibility → the app you
// run it from (Terminal, iTerm…) switched on.

ObjC.import('AppKit');

const args = $.NSProcessInfo.processInfo.arguments.js.map(a => ObjC.unwrap(a));
const userArgs = args.slice(args.findIndex(a => /demo_tour\.js$/.test(a)) + 1);
const PACE = parseFloat(userArgs.find(a => /^[0-9.]+$/.test(a)) || '6');
const SAY = userArgs.includes('--say');
const ONLY = (() => { const i = userArgs.indexOf('--only'); return i >= 0 ? userArgs[i + 1] : null; })();

const SE = Application('System Events');
const ME = Application.currentApplication();
ME.includeStandardAdditions = true;

class TakeOver extends Error {}

// ── take-over watch ────────────────────────────────────────────────────
let anchor = null;
function mouse() { const p = $.NSEvent.mouseLocation; return [p.x, p.y]; }
function rearm() { anchor = mouse(); }   // after our own clicks, re-baseline
function checkTakeOver() {
    const flags = Number($.NSEvent.modifierFlags);
    if (flags & 0x100000) throw new TakeOver('⌘ pressed');
    const [x, y] = mouse();
    const d = anchor ? Math.hypot(x - anchor[0], y - anchor[1]) : 0;
    if (d > 40) throw new TakeOver('mouse moved ' + Math.round(d) + ' px: ' + anchor.map(Math.round) + ' → ' + [x, y].map(Math.round));
}
function wait(seconds) {
    const end = Date.now() + seconds * 1000;
    while (Date.now() < end) { checkTakeOver(); delay(0.05); }
}
// Narration is pre-recorded in Hallie's Kokoro voice (af_heart) in ./voice/<key>.wav.
// Runtime files (narration wavs, the one-tour lock) live in the ignored .scratch/demo;
// scripts/demo/render_voice.py makes the wavs.
const RUNTIME = ME.doShellScript('echo $HOME') + '/dev/VideoScan/.scratch/demo/';
const VOICE_DIR = RUNTIME + 'voice/';
function say(key, text) {
    console.log('▶ ' + text);
    if (SAY) { ME.doShellScript("/usr/bin/afplay '" + VOICE_DIR + key + ".wav' >/dev/null 2>&1 &"); }
}

// ── accessibility helpers ──────────────────────────────────────────────
const proc = () => SE.processes.byName('VideoScan');
const SKIP = new Set(['AXTable', 'AXOutline', 'AXRow', 'AXCell', 'AXColumn', 'AXScrollBar', 'AXStaticText', 'AXImage']);

function attr(e, name) { try { return e.attributes[name].value(); } catch (x) { return null; } }

// Depth-limited walk that never descends into tables (the catalog has 100k rows).
function find(root, pred, depth = 0) {
    if (depth > 14) return null;
    let kids = [];
    try { kids = root.uiElements(); } catch (x) { return null; }
    for (const k of kids) {
        if (pred(k)) return k;
        let role = null; try { role = k.role(); } catch (x) {}
        if (role && SKIP.has(role)) continue;
        const hit = find(k, pred, depth + 1);
        if (hit) return hit;
    }
    return null;
}
const byId = id => e => attr(e, 'AXIdentifier') === id;

function waitFor(id, seconds, root) {
    const end = Date.now() + seconds * 1000;
    while (Date.now() < end) {
        checkTakeOver();
        const roots = root ? [root] : proc().windows();
        for (const r of roots) { const el = find(r, byId(id)); if (el) return el; }
        delay(0.25);
    }
    return null;
}
// Wait for a window whose title matches `re`, then for `id` inside it only
// (searching the main window too is slow: thousands of elements).
function waitInWindow(re, id, seconds) {
    const end = Date.now() + seconds * 1000;
    while (Date.now() < end) {
        checkTakeOver();
        let w = null;
        try { w = proc().windows().find(x => { try { return re.test(x.name()); } catch (e) { return false; } }); } catch (e) {}
        if (w) { const el = find(w, byId(id)); if (el) return el; }
        delay(0.25);
    }
    return null;
}
function press(el) { el.actions['AXPress'].perform(); rearm(); }
function pressId(id, seconds = 5) {
    const el = waitFor(id, seconds);
    if (!el) { console.log('  (skipped: ' + id + ' not on screen)'); return false; }
    press(el); return true;
}
function tab(label, key, line) {
    say(key, line);
    if (pressId('tab.' + label)) wait(PACE);
}

// ── the Show ▸ folders toggle (put back as found) ─────────────────────
function showMenuItem(title) {
    const win = proc().windows[0];
    const btn = find(win, e => {
        let r = null, t = null; try { r = e.role(); t = e.title() || e.description(); } catch (x) {}
        let h = ''; try { h = e.help() || ''; } catch (x) {}
        // Two menus are titled "Show" (volumes and files); the files one says so in its help.
        return r === 'AXMenuButton' && t === 'Show' && /which files/.test(h);
    });
    if (!btn) return null;
    press(btn); delay(0.6);
    let item = null;
    try { item = btn.menus[0].menuItems.byName(title); item.name(); } catch (x) { item = null; }
    return item;
}
function isChecked(item) { const m = attr(item, 'AXMenuItemMarkChar'); return !!m; }
function closeMenu() { SE.keyCode(53); rearm(); }  // Escape

function folders() {
    say('folders', 'The catalog as folders: events and copies, grouped');
    const item = showMenuItem('Events & Copies as Folders');
    if (!item) { console.log('  (skipped: Show menu not found)'); closeMenu(); return; }
    const wasOn = isChecked(item);
    if (wasOn) { closeMenu(); wait(PACE * 1.5); return; }
    item.actions['AXPress'].perform(); rearm();
    try { wait(PACE * 1.5); }
    finally {
        const again = showMenuItem('Events & Copies as Folders');   // put it back off
        if (again && isChecked(again)) { again.actions['AXPress'].perform(); rearm(); }
        else closeMenu();
    }
}

// ── Family Tree → Walk → Show on map ───────────────────────────────────
function walkAndMap() {
    say('walk', 'Walking the family tree');
    // The sheet may already be up (left open); otherwise open it.
    const already = find(proc().windows[0], byId('ft.walk.start'));
    console.log('  walk sheet ' + (already ? 'already open' : 'opening'));
    if (!already && !pressId('ft.walkTree')) return;
    const sheetRoot = () => proc().windows[0];
    if (!pressId('ft.walk.start', 20)) return;
    // Let the replay run; it shows the generations filling in.
    const end = Date.now() + 90 * 1000;
    let map = null;
    while (Date.now() < end) {
        checkTakeOver();
        map = find(sheetRoot(), byId('ft.walk.showOnMap'));
        let on = false; try { on = map && map.enabled(); } catch (x) {}
        if (on) break;
        delay(0.5);
    }
    if (!map) { console.log('  (skipped: no Show on map)'); return; }
    wait(PACE);
    say('map', 'And where they were born, on the map');
    press(map);
    wait(PACE * 3);
    pressId('ft.walk.done', 3);
}

// ── Observations ▸ Frames: SigLIP 2 search by picture ─────────────────
const QUERY = 'a boy playing baseball';
function frameSearch() {
    say('search', "Now a search by picture: baseball, from what the machine saw in the frames");
    let opened = false;
    try {
        const item = proc().menuBars[0].menuBarItems.byName('Catalog');
        item.click(); delay(0.5);
        item.menus[0].menuItems.byName('Content Analysis…').click(); rearm();
        const b = waitInWindow(/^Content Analysis$/, 'analyze.observations', 20);
        if (b) { press(b); opened = true; }
    } catch (x) { console.log('  (menu: ' + x + ')'); SE.keyCode(53); }
    rearm();
    if (!opened) { console.log('  (skipped: Catalog ▸ Content Analysis… ▸ Observations… not found)'); return; }
    // The window's own identifier covers its children, so find controls by role:
    // the top-level radio group (Words | Frames) and the first text field (search).
    let ow = null;
    const end = Date.now() + 15000;
    while (!ow && Date.now() < end) {
        checkTakeOver();
        try { ow = proc().windows().find(x => { try { return /^Observations/.test(x.name()); } catch (e) { return false; } }); } catch (e) {}
        if (!ow) delay(0.25);
    }
    if (!ow) { console.log('  (skipped: Observations window did not open)'); return; }
    wait(1.5);
    const roleIs = r => e => { try { return e.role() === r; } catch (x) { return false; } };
    const shallow = (pred) => {   // the header only: depth ≤ 2, never into the tiers
        for (const a of ow.uiElements()) { if (pred(a)) return a;
            let kids = []; try { kids = a.uiElements(); } catch (x) {}
            for (const b of kids) if (pred(b)) return b; }
        return null; };
    try { const g = shallow(roleIs('AXRadioGroup')); g.radioButtons[1].click(); rearm(); } catch (x) { console.log('  (Frames switch: ' + x + ')'); }
    wait(1.5);
    let field = null;
    try { field = shallow(roleIs('AXTextField')); } catch (x) { field = null; }
    if (!field) { console.log('  (skipped: search field not found)'); return; }
    try { field.focused = true; } catch (x) {}
    field.value = QUERY; delay(0.3);
    try { field.focused = true; } catch (x) {}
    SE.keyCode(36); rearm();                      // Return → submit
    wait(8);                                      // first query loads the model (3–6 s)
    say('found', 'No filenames, no tags: just what the model saw');
    wait(PACE * 2);
}

// ── the tour ───────────────────────────────────────────────────────────
function tour() {
    const app = Application('VideoScan');
    if (!app.running()) { console.log('VideoScan is not running — launch it first.'); return; }
    // One tour at a time: an atomic mkdir lock; a lock left by a dead tour is taken over.
    const LOCK = RUNTIME + '.tour.lock';
    ME.doShellScript("/bin/mkdir -p '" + RUNTIME + "'");
    const got = ME.doShellScript(
        "if /bin/mkdir '" + LOCK + "' 2>/dev/null; then echo ok; " +
        "elif ! /bin/ps -p \"$(/bin/cat '" + LOCK + "/pid' 2>/dev/null || echo 0)\" >/dev/null 2>&1; then echo stale; " +
        "else echo busy; fi");
    if (got === 'busy') { console.log('Another demo tour is already running — not starting a second one.'); return; }
    const myPid = ME.doShellScript('echo $PPID');
    ME.doShellScript("/bin/mkdir -p '" + LOCK + "' && echo " + myPid + " > '" + LOCK + "/pid'");
    try { tourBody(app); }
    finally { ME.doShellScript("/bin/rm -rf '" + LOCK + "'"); }
}

function tourBody(app) {
    app.activate(); delay(1.0);
    console.log('Demo tour: ' + PACE + ' s per stop. Move the mouse or press ⌘ to take over.');
    console.log('Hands off the mouse — starting in 3 s.');
    delay(3);
    rearm();
    try {
        if (!ONLY) { say('intro', 'Claude would like to give a demo for Dan'); wait(4.5); }
        if (ONLY) { ({ folders, walk: walkAndMap, search: frameSearch })[ONLY](); return; }
        tab('People', 'people',      'People: who the machine has found in the footage');
        tab('Catalog', 'catalog',     'The catalog: every family media file on every drive');
        folders();
        tab('Storage', 'storage',     'Storage: every drive, its role and its health');
        tab('Triage', 'triage',      'Triage: what still needs a look');
        tab('Archive', 'archive',     'The archive: the keepers, filed by decade');
        tab('Family Tree', 'tree', 'The family tree');
        frameSearch();   // Walk Tree → map is shown by hand (its AX press does not open the sheet)
        say('end', "That's the demo. Claude is done. Rick, you can take over now."); delay(5);
    } catch (e) {
        if (e instanceof TakeOver) { console.log('\n■ Stopped (' + e.message + '). You have it.'); return; }
        throw e;
    }
}
// JXA calls a global `run` itself; so the entry point is `run` and nothing else calls it.
function run() { tour(); }

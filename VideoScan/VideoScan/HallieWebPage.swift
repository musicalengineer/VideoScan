// HallieWebPage.swift
// The one page the family sees on the MBP, the iPad, a phone. Plain HTML +
// vanilla JS, big type (Rick's accessibility priority), dictation in and
// spoken answers out via Safari's built-in speech APIs. Nothing external is
// loaded — no CDN, no fonts, no tracking — so it works on a LAN with no
// internet at all.

import Foundation

enum HallieWebPage {
    static func html(archivistName: String) -> String {
        let name = archivistName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="apple-mobile-web-app-title" content="\(name)">
        <meta name="theme-color" content="#f5efe4">
        <title>\(name)</title>
        <style>
          :root { --bg:#f5efe4; --ink:#2b2520; --muted:#7a6f63; --her:#fff8ea; --you:#e7eef7; --line:#d9cfbf; --accent:#8a5a2b; }
          @media (prefers-color-scheme: dark) { :root { --bg:#1d1a17; --ink:#f1e9dc; --muted:#a79a8a; --her:#2a2521; --you:#22303d; --line:#3a332c; --accent:#d9a064; } }
          * { box-sizing:border-box; }
          body { margin:0; background:var(--bg); color:var(--ink); font:20px/1.45 -apple-system, "Helvetica Neue", sans-serif; display:flex; flex-direction:column; height:100dvh; }
          header { padding:12px 16px; border-bottom:1px solid var(--line); display:flex; align-items:center; gap:12px; }
          header h1 { font:600 22px Georgia, serif; margin:0; flex:1; }
          header button { font-size:16px; background:none; border:1px solid var(--line); color:var(--ink); border-radius:10px; padding:6px 10px; }
          nav { display:flex; border-bottom:1px solid var(--line); }
          nav button { flex:1; font-size:18px; padding:10px; background:none; border:none; color:var(--muted); border-bottom:3px solid transparent; }
          nav button.on { color:var(--ink); border-bottom-color:var(--accent); font-weight:600; }
          #browse { flex:1; overflow-y:auto; padding:10px 14px; display:none; -webkit-overflow-scrolling:touch; }
          #browse h2 { font:600 22px Georgia, serif; margin:18px 0 6px; color:var(--accent); }
          #browse h3 { font:600 17px -apple-system, sans-serif; margin:12px 0 4px; color:var(--muted); }
          .bitem { display:flex; gap:10px; align-items:center; padding:10px 6px; border-bottom:1px solid var(--line); flex-wrap:wrap; }
          .bitem img.poster { width:120px; height:68px; object-fit:cover; border-radius:8px; background:var(--line); flex:none; }
          .bitem .poster.empty { width:120px; height:68px; border-radius:8px; background:var(--line); flex:none; }
          .bitem video { flex-basis:100%; }
          .bitem .t { flex:1; min-width:0; }
          .bitem .t b { display:block; font-weight:600; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
          .bitem .t span { font-size:14px; color:var(--muted); }
          .bitem button { font-size:17px; padding:8px 12px; border-radius:12px; border:1px solid var(--accent); color:var(--accent); background:none; }
          .bitem .mac { font-size:14px; color:var(--muted); }
          #bsearch { width:100%; font-size:18px; padding:10px 12px; border-radius:12px; border:1px solid var(--line); background:var(--her); color:var(--ink); margin:6px 0 4px; }
          body.browsing #log, body.browsing form { display:none; }
          body.browsing #browse { display:block; }
          #log { flex:1; overflow-y:auto; padding:14px 14px 0; -webkit-overflow-scrolling:touch; }
          .msg { max-width:92%; margin:0 0 12px; padding:12px 14px; border-radius:16px; white-space:pre-wrap; word-wrap:break-word; }
          .her { background:var(--her); border:1px solid var(--line); border-top-left-radius:4px; }
          .you { background:var(--you); margin-left:auto; border-top-right-radius:4px; }
          .basis { font-size:14px; color:var(--muted); margin-top:6px; display:none; }
          .msg.open .basis { display:block; }
          .chips { display:flex; flex-wrap:wrap; gap:8px; margin-top:10px; }
          .attach { margin-top:10px; padding:10px 12px; border-radius:12px; background:rgba(127,127,127,0.08); }
          .attach-title { font-weight:600; font-size:17px; margin-bottom:4px; }
          .attach-root { font-weight:600; margin-bottom:6px; }
          .attach-gen { margin:4px 0; }
          .attach-label { display:inline-block; font-size:13px; text-transform:uppercase; letter-spacing:0.04em; opacity:0.7; margin-bottom:2px; }
          .attach ul { margin:0 0 0 18px; padding:0; }
          .attach-tree ul { margin-left:18px; }
          .attach-img { max-width:100%; max-height:320px; border-radius:10px; display:block; }
          .attach-crest { max-width:160px; max-height:160px; display:block; }
          .chips button { font-size:17px; padding:8px 12px; border-radius:12px; border:1px solid var(--accent); color:var(--accent); background:none; }
          .cite { display:flex; gap:10px; align-items:center; margin-top:8px; font-size:17px; }
          .cite button { font-size:16px; padding:6px 10px; border-radius:10px; border:1px solid var(--line); background:none; color:var(--ink); }
          .cite .no { color:var(--muted); font-size:15px; }
          video { width:100%; max-height:50vh; margin-top:8px; border-radius:10px; background:#000; }
          form { display:flex; gap:8px; padding:10px 12px calc(10px + env(safe-area-inset-bottom)); border-top:1px solid var(--line); background:var(--bg); }
          input { flex:1; font-size:20px; padding:12px 14px; border-radius:14px; border:1px solid var(--line); background:var(--her); color:var(--ink); }
          form button { font-size:20px; padding:0 16px; border-radius:14px; border:none; background:var(--accent); color:#fff; }
          form button.mic { background:none; border:1px solid var(--line); color:var(--ink); }
          form button.mic.on { border-color:#c0392b; color:#c0392b; }
          .thinking { color:var(--muted); font-style:italic; }
          .tiny { font-size:14px; color:var(--muted); }
        </style>
        </head>
        <body>
        <header>
          <h1>\(name)</h1>
          <button id="speakToggle" title="Read answers aloud">🔈 Read aloud</button>
          <select id="voicePick" title="Which voice reads aloud" style="display:none;font-size:15px;max-width:150px;border:1px solid var(--line);border-radius:10px;background:none;color:var(--ink);padding:5px"></select>
          <button id="whoBtn" title="Who is talking">👤</button>
        </header>
        <nav><button id="tabAsk" class="on">Ask</button><button id="tabBrowse">Browse the archive</button></nav>
        <div id="log"></div>
        <div id="browse"><input id="bsearch" placeholder="Find in the archive (a name, a year, a word)…"><div id="blist" class="tiny">Loading the archive…</div></div>
        <form id="ask">
          <button type="button" class="mic" id="mic" title="Dictate">🎤</button>
          <input id="text" autocomplete="off" autocapitalize="sentences" placeholder="Ask \(name)…">
          <button type="submit">Ask</button>
        </form>
        <script>
        (function () {
          var log = document.getElementById('log');
          var input = document.getElementById('text');
          var form = document.getElementById('ask');
          var mic = document.getElementById('mic');
          var speakToggle = document.getElementById('speakToggle');
          var store = function (k, v) { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { return null; } };
          var session = store('hallie.session') || (function () { var s = Math.random().toString(36).slice(2) + Date.now().toString(36); store('hallie.session', s); return s; })();
          var who = store('hallie.who') || '';
          var key = store('hallie.key') || '';
          var speak = store('hallie.speak') === 'on';
          speakToggle.textContent = speak ? '🔊 Reading aloud' : '🔈 Read aloud';

          function askWho() {
            var v = prompt('Who is talking to \(name)? (your first and last name, as the family tree knows you)', who || '');
            if (v && v.trim()) { who = v.trim(); store('hallie.who', who); }
          }
          function askKey() {
            var v = prompt('Family passphrase (set in VideoScan → Hallie settings on the Mac)', '');
            if (v !== null) { key = v.trim(); store('hallie.key', key); }
          }
          document.getElementById('whoBtn').onclick = askWho;
          speakToggle.onclick = function () { speak = !speak; store('hallie.speak', speak ? 'on' : 'off'); speakToggle.textContent = speak ? '🔊 Reading aloud' : '🔈 Read aloud'; if (!speak && window.speechSynthesis) speechSynthesis.cancel(); voicePick.style.display = speak && voicePick.options.length ? '' : 'none'; };

          function add(role, text) {
            var d = document.createElement('div');
            d.className = 'msg ' + role;
            d.textContent = text;
            log.appendChild(d);
            log.scrollTop = log.scrollHeight;
            return d;
          }
          // ---- Reading aloud (Rick 2026-08-22: "slow it down and make it
          // sound more natural"): a slower rate, one sentence per utterance
          // with a breath between (iOS also clips very long utterances),
          // and the best installed voice — premium/enhanced Siri voices
          // first when the iPad has them (Settings → Accessibility → Spoken
          // Content → Voices downloads them), remembered per device.
          var voicePick = document.getElementById('voicePick');
          var preferred = ['Ava', 'Zoe', 'Allison', 'Samantha', 'Nicky', 'Joelle', 'Susan', 'Karen', 'Moira', 'Tessa'];
          function voices() { return (window.speechSynthesis ? speechSynthesis.getVoices() : []).filter(function (v) { return /^en/i.test(v.lang); }); }
          function rankVoice(v) {
            var n = v.name.toLowerCase(), score = 0;
            if (/premium|enhanced/.test(n)) score += 20;
            var i = preferred.findIndex(function (p) { return n.indexOf(p.toLowerCase()) >= 0; });
            if (i >= 0) score += 10 - i;
            if (/en-us/i.test(v.lang)) score += 2;
            if (/compact|eloquence|fred|albert|bad news|bells|boing|bubbles|cellos|organ|trinoids|whisper|wobble|zarvox|junior|ralph|kathy/.test(n)) score -= 30;
            return score;
          }
          function fillVoices() {
            var vs = voices().sort(function (a, b) { return rankVoice(b) - rankVoice(a); });
            if (!vs.length) return;
            voicePick.innerHTML = '';
            vs.slice(0, 12).forEach(function (v) { var o = document.createElement('option'); o.value = v.name; o.textContent = v.name.replace(/\\s*\\(.*\\)$/, '') + (/premium|enhanced/i.test(v.name) ? ' ★' : ''); voicePick.appendChild(o); });
            var saved = store('hallie.voice');
            if (saved && vs.some(function (v) { return v.name === saved; })) voicePick.value = saved; else { voicePick.value = vs[0].name; store('hallie.voice', vs[0].name); }
            voicePick.style.display = speak ? '' : 'none';
          }
          if (window.speechSynthesis) { fillVoices(); speechSynthesis.onvoiceschanged = fillVoices; }
          voicePick.onchange = function () { store('hallie.voice', voicePick.value); sayAloud('Hello — this is how I sound.'); };
          function chosenVoice() { var name = store('hallie.voice'); return voices().find(function (v) { return v.name === name; }) || null; }
          function sentences(text) {
            return (text || '').replace(/\\[c\\d+\\]/g, '').split(/(?<=[.!?…])\\s+/).map(function (s) { return s.trim(); }).filter(Boolean);
          }
          function sayAloud(text) {
            if (!speak || !window.speechSynthesis) return;
            speechSynthesis.cancel();
            var v = chosenVoice();
            sentences(text).forEach(function (sentence) {
              var u = new SpeechSynthesisUtterance(sentence);
              u.rate = 0.82; u.pitch = 0.95; u.lang = (v && v.lang) || 'en-US';
              if (v) u.voice = v;
              speechSynthesis.speak(u);
            });
          }
          function render(r) {
            var d = add('her', r.prose || '');
            if (r.basis) {
              var b = document.createElement('div'); b.className = 'basis'; b.textContent = r.basis; d.appendChild(b);
              d.addEventListener('click', function (e) { if (e.target === d) d.classList.toggle('open'); });
            }
            if (r.citations && r.citations.length) {
              r.citations.forEach(function (c, i) {
                var row = document.createElement('div'); row.className = 'cite';
                var label = document.createElement('span'); label.textContent = (i + 1) + '. ' + c.filename; row.appendChild(label);
                if (c.playable) {
                  var b = document.createElement('button'); b.textContent = '▶︎ Play';
                  b.onclick = function () { playInline(d, c); };
                  row.appendChild(b);
                } else {
                  var no = document.createElement('span'); no.className = 'no'; no.textContent = 'plays on the Mac only'; row.appendChild(no);
                }
                d.appendChild(row);
              });
            }
            (r.attachments || []).forEach(function (a) { d.appendChild(renderAttachment(a)); });
            var chips = (r.chips || []);
            if (chips.length) {
              var wrap = document.createElement('div'); wrap.className = 'chips';
              chips.forEach(function (ch) {
                var b = document.createElement('button'); b.textContent = ch.label;
                b.onclick = function () { if (ch.select) send({ select: ch.select }); else if (ch.ask) { input.value = ch.ask; form.requestSubmit(); } };
                wrap.appendChild(b);
              });
              d.appendChild(wrap);
            }
            if (r.play && r.play.length) { playInline(d, r.play[0]); }
            log.scrollTop = log.scrollHeight;
            sayAloud(r.prose || '');
          }
          function personLine(p) {
            var s = p.name; if (p.years) s += ' (' + p.years + ')'; if (p.place) s += ' — ' + p.place; return s;
          }
          function imageWith(url, alt) {
            var img = document.createElement('img'); img.className = 'attach-img'; img.alt = alt || '';
            img.src = url + (key ? ('?key=' + encodeURIComponent(key)) : ''); return img;
          }
          function renderAttachment(a) {
            var box = document.createElement('div'); box.className = 'attach';
            if (a.kind === 'photo') {
              box.appendChild(imageWith(a.url, 'Photo of ' + a.name));
              var cap = document.createElement('div'); cap.className = 'tiny'; cap.textContent = a.caption || a.name; box.appendChild(cap);
            } else if (a.kind === 'crest') {
              var ci = imageWith(a.url, a.surname + ' crest'); ci.className = 'attach-crest'; box.appendChild(ci);
              var cc = document.createElement('div'); cc.className = 'tiny'; cc.textContent = 'The ' + a.surname + ' crest'; box.appendChild(cc);
            } else if (a.kind === 'lineage') {
              var t = document.createElement('div'); t.className = 'attach-title'; t.textContent = a.title; box.appendChild(t);
              var r0 = document.createElement('div'); r0.className = 'attach-root'; r0.textContent = personLine(a.root); box.appendChild(r0);
              (a.generations || []).forEach(function (g) {
                var row = document.createElement('div'); row.className = 'attach-gen';
                var lab = document.createElement('span'); lab.className = 'attach-label'; lab.textContent = g.label; row.appendChild(lab);
                var ul = document.createElement('ul');
                (g.people || []).forEach(function (p) { var li = document.createElement('li'); li.textContent = personLine(p); ul.appendChild(li); });
                row.appendChild(ul); box.appendChild(row);
              });
              if (a.reachedAll === false) { var n = document.createElement('div'); n.className = 'tiny'; n.textContent = 'The tree stops here.'; box.appendChild(n); }
            } else if (a.kind === 'tree') {
              var tt = document.createElement('div'); tt.className = 'attach-title'; tt.textContent = a.title; box.appendChild(tt);
              function renderNode(n) {
                var li = document.createElement('li');
                var s = personLine(n.person);
                if (n.spouses && n.spouses.length) s += '  ⚭ ' + n.spouses.map(function (x) { return x.name; }).join(', ');
                li.textContent = s;
                if (n.children && n.children.length) { var ul2 = document.createElement('ul'); n.children.forEach(function (c) { ul2.appendChild(renderNode(c)); }); li.appendChild(ul2); }
                return li;
              }
              var ulr = document.createElement('ul'); ulr.className = 'attach-tree'; (a.roots || []).forEach(function (n) { ulr.appendChild(renderNode(n)); }); box.appendChild(ulr);
            } else if (a.kind === 'photoRequest') {
              var pr = document.createElement('div'); pr.className = 'tiny';
              pr.textContent = 'Do you have a photo of ' + a.name + '? On the Mac, put it in: ' + a.folder; box.appendChild(pr);
            }
            return box;
          }
          function playInline(container, c) {
            var old = container.querySelector('video'); if (old) old.remove();
            var oldNote = container.querySelector('.preparing'); if (oldNote) oldNote.remove();
            var src = c.url + (key ? ('?key=' + encodeURIComponent(key)) : '');
            function start() {
              var v = document.createElement('video');
              v.controls = true; v.playsInline = true; v.src = src;
              container.appendChild(v);
              v.play().catch(function () {});
              log.scrollTop = log.scrollHeight;
            }
            if (c.native) { start(); return; }
            // A tape Safari can't decode: the Mac prepares an access copy once.
            var note = document.createElement('div'); note.className = 'tiny preparing';
            note.textContent = 'Preparing this one for the iPad…'; container.appendChild(note);
            var ticks = 0;
            function poll() {
              fetch(c.url + '/status' + (key ? ('?key=' + encodeURIComponent(key)) : ''), { headers: { 'X-Hallie-Key': key } })
                .then(function (r) { return r.json(); })
                .then(function (s) {
                  if (s.state === 'ready') { note.remove(); start(); return; }
                  if (s.state === 'failed' || s.state === 'unavailable') { note.textContent = "I couldn't prepare that one for the iPad" + (s.reason ? ' — ' + s.reason : '') + '.'; return; }
                  ticks += 1;
                  note.textContent = 'Preparing this one for the iPad… ' + (s.seconds ? s.seconds + 's' : '') + (ticks > 60 ? ' (a long tape takes a few minutes)' : '');
                  setTimeout(poll, 2000);
                })
                .catch(function () { setTimeout(poll, 4000); });
            }
            // Kick the encode, then poll.
            fetch(src, { headers: { 'X-Hallie-Key': key, 'Range': 'bytes=0-0' } }).then(function (r) {
              if (r.status === 200 || r.status === 206) { note.remove(); start(); } else { poll(); }
            }).catch(poll);
          }
          // ---- Browse: the Archive Timeline, decades → years → items.
          var browse = document.getElementById('browse'), blist = document.getElementById('blist'), bsearch = document.getElementById('bsearch');
          var timelineData = null;
          function setTab(name) {
            document.body.classList.toggle('browsing', name === 'browse');
            document.getElementById('tabAsk').classList.toggle('on', name !== 'browse');
            document.getElementById('tabBrowse').classList.toggle('on', name === 'browse');
            store('hallie.tab', name);
            if (name === 'browse' && !timelineData) loadTimeline();
          }
          document.getElementById('tabAsk').onclick = function () { setTab('ask'); };
          document.getElementById('tabBrowse').onclick = function () { setTab('browse'); };
          function loadTimeline() {
            blist.textContent = 'Loading the archive…';
            fetch('/api/timeline', { headers: { 'X-Hallie-Key': key } })
              .then(function (r) { if (r.status === 401) { askKey(); throw new Error('passphrase'); } return r.json(); })
              .then(function (t) { timelineData = t; renderTimeline(); })
              .catch(function (e) { blist.textContent = "I couldn't load the archive just now (" + e + ')'; });
          }
          function matches(it, q) {
            if (!q) return true;
            var hay = (it.title + ' ' + it.filename + ' ' + (it.year || '') + ' ' + it.people).toLowerCase();
            return q.split(/\\s+/).every(function (w) { return hay.indexOf(w) >= 0; });
          }
          function browseRow(it) {
            var row = document.createElement('div'); row.className = 'bitem';
            if (it.poster) {
              var img = document.createElement('img'); img.className = 'poster'; img.loading = 'lazy'; img.alt = '';
              var tries = 0;
              img.onerror = function () { if (tries++ < 6) setTimeout(function () { img.src = it.poster + '?k=' + tries + (key ? '&key=' + encodeURIComponent(key) : ''); }, 2500 * tries); else img.replaceWith(placeholder()); };
              img.src = it.poster + (key ? ('?key=' + encodeURIComponent(key)) : '');
              row.appendChild(img);
            } else { row.appendChild(placeholder()); }
            var t = document.createElement('div'); t.className = 't';
            var b = document.createElement('b'); b.textContent = it.title || it.filename; t.appendChild(b);
            var sp = document.createElement('span');
            sp.textContent = [it.year ? String(it.year) : '', it.duration, it.people, it.verified ? 'verified copy' : ''].filter(Boolean).join(' · ');
            t.appendChild(sp); row.appendChild(t);
            if (it.playable) {
              var pb = document.createElement('button'); pb.textContent = '▶︎ Play';
              pb.onclick = function () { playInline(row, it); };
              row.appendChild(pb);
            } else {
              var m = document.createElement('span'); m.className = 'mac'; m.textContent = it.kind === 'photo' ? 'photo' : 'plays on the Mac only'; row.appendChild(m);
            }
            return row;
          }
          function placeholder() { var d = document.createElement('div'); d.className = 'poster empty'; return d; }
          function renderTimeline() {
            var t = timelineData; if (!t) return;
            blist.textContent = '';
            if (!t.available) { blist.textContent = 'Browsing isn\\u2019t switched on for this page.'; return; }
            var q = (bsearch.value || '').trim().toLowerCase();
            var shown = 0;
            t.decades.forEach(function (d) {
              var rows = [];
              d.years.forEach(function (y) {
                var its = y.items.filter(function (it) { return matches(it, q); });
                if (!its.length) return;
                var h3 = document.createElement('h3'); h3.textContent = y.year; rows.push(h3);
                its.forEach(function (it) { rows.push(browseRow(it)); shown += 1; });
              });
              if (!rows.length) return;
              var h2 = document.createElement('h2'); h2.textContent = 'The ' + d.label; blist.appendChild(h2);
              rows.forEach(function (r) { blist.appendChild(r); });
            });
            var und = t.undated.filter(function (it) { return matches(it, q); });
            if (und.length) { var h2u = document.createElement('h2'); h2u.textContent = 'Undated'; blist.appendChild(h2u); und.forEach(function (it) { blist.appendChild(browseRow(it)); shown += 1; }); }
            if (!shown) { var none = document.createElement('div'); none.className = 'tiny'; none.textContent = q ? 'Nothing in the archive matches \\u201c' + q + '\\u201d yet.' : 'The archive is empty so far \\u2014 the story starts with the first promote.'; blist.appendChild(none); }
          }
          bsearch.oninput = renderTimeline;
          if (store('hallie.tab') === 'browse') setTab('browse');

          var busy = false;
          function send(payload) {
            if (busy) return;
            if (!who) { askWho(); if (!who) return; }
            payload.session = session; payload.who = who;
            busy = true;
            var t = add('her thinking', '…');
            fetch('/api/ask', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Hallie-Key': key }, body: JSON.stringify(payload) })
              .then(function (res) {
                if (res.status === 401) { t.remove(); busy = false; askKey(); if (key) send(payload); return null; }
                if (res.status === 403) { t.remove(); busy = false; add('her', 'I only answer on the home network.'); return null; }
                return res.json();
              })
              .then(function (r) { if (!r) return; t.remove(); render(r); })
              .catch(function (e) { t.remove(); add('her', "I couldn't reach the Mac just now (" + e + ')'); })
              .finally(function () { busy = false; input.focus(); });
          }
          form.onsubmit = function (e) {
            e.preventDefault();
            var text = input.value.trim(); if (!text) return;
            add('you', text); input.value = '';
            send({ text: text });
          };
          var SR = window.SpeechRecognition || window.webkitSpeechRecognition;
          if (!SR) { mic.style.display = 'none'; }
          else {
            var rec = null;
            mic.onclick = function () {
              if (rec) { rec.stop(); return; }
              rec = new SR(); rec.lang = 'en-US'; rec.interimResults = true;
              rec.onresult = function (ev) { var s = ''; for (var i = 0; i < ev.results.length; i++) s += ev.results[i][0].transcript; input.value = s; };
              rec.onend = function () { mic.classList.remove('on'); rec = null; if (input.value.trim()) form.requestSubmit(); };
              rec.onerror = function () { mic.classList.remove('on'); rec = null; };
              mic.classList.add('on'); rec.start();
            };
          }
          add('her', 'Hello — I\\u2019m \(name), the family archivist. Ask me about the videos or the family, or say \\u201clet me tell you about\\u2026\\u201d and I\\u2019ll remember it.');
          if (!who) setTimeout(askWho, 300);
        })();
        </script>
        </body>
        </html>
        """
    }
}

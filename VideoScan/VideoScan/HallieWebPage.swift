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
          #log { flex:1; overflow-y:auto; padding:14px 14px 0; -webkit-overflow-scrolling:touch; }
          .msg { max-width:92%; margin:0 0 12px; padding:12px 14px; border-radius:16px; white-space:pre-wrap; word-wrap:break-word; }
          .her { background:var(--her); border:1px solid var(--line); border-top-left-radius:4px; }
          .you { background:var(--you); margin-left:auto; border-top-right-radius:4px; }
          .basis { font-size:14px; color:var(--muted); margin-top:6px; display:none; }
          .msg.open .basis { display:block; }
          .chips { display:flex; flex-wrap:wrap; gap:8px; margin-top:10px; }
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
          <button id="whoBtn" title="Who is talking">👤</button>
        </header>
        <div id="log"></div>
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
          speakToggle.onclick = function () { speak = !speak; store('hallie.speak', speak ? 'on' : 'off'); speakToggle.textContent = speak ? '🔊 Reading aloud' : '🔈 Read aloud'; if (!speak && window.speechSynthesis) speechSynthesis.cancel(); };

          function add(role, text) {
            var d = document.createElement('div');
            d.className = 'msg ' + role;
            d.textContent = text;
            log.appendChild(d);
            log.scrollTop = log.scrollHeight;
            return d;
          }
          function sayAloud(text) {
            if (!speak || !window.speechSynthesis) return;
            speechSynthesis.cancel();
            var u = new SpeechSynthesisUtterance(text);
            u.rate = 0.95; u.lang = 'en-US';
            speechSynthesis.speak(u);
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
          function playInline(container, c) {
            var old = container.querySelector('video'); if (old) old.remove();
            var v = document.createElement('video');
            v.controls = true; v.playsInline = true; v.src = c.url + (key ? ('?key=' + encodeURIComponent(key)) : '');
            container.appendChild(v);
            v.play().catch(function () {});
            log.scrollTop = log.scrollHeight;
          }
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

// Selway's code editor page logic (tabs, save versions, minimap, palette),
// kept out of editor.html so its Content-Security-Policy can forbid inline script.
// Tested without a browser by Tests/EditorPage/selway-editor.test.js.
(function () {
  "use strict";

  function bridge(type, payload) {
    try {
      var msg = { type: type };
      if (payload) { for (var k in payload) { msg[k] = payload[k]; } }
      window.webkit.messageHandlers.bridge.postMessage(msg);
    } catch (e) { /* not in WKWebView */ }
  }

  window.addEventListener("error", function (e) {
    var info = (e && e.target && e.target.src)
      ? ("RESOURCE_FAIL " + e.target.src)
      : ((e.message || "") + " " + (e.filename || "") + ":" + (e.lineno || 0));
    bridge("jserror", { msg: info });
  }, true);

  ace.config.set("basePath", ".");
  ace.config.set("modePath", ".");
  ace.config.set("themePath", ".");
  ace.config.set("workerPath", ".");

  var editor = ace.edit("editor");
  var modelist = ace.require("ace/ext/modelist");

  editor.setOptions({
    enableBasicAutocompletion: true,
    enableLiveAutocompletion: true,
    enableSnippets: true,
    showPrintMargin: false,
    fontSize: 14,
    useWorker: false,
    wrap: false,
    tabSize: 4,
    useSoftTabs: true,
    scrollPastEnd: 0.5,
    highlightActiveLine: true,
    displayIndentGuides: true,
    behavioursEnabled: true
  });
  editor.setTheme("ace/theme/monokai");
  // Nothing to type into until Swift opens a document (see closeDoc).
  editor.setReadOnly(true);

  // Built-in Ace settings panel (covers tab size, soft tabs, wrap, font, etc.)
  try { ace.require("ace/ext/settings_menu").init(editor); } catch (e) {}

  // ── Multiple documents (tabs) ───────────────────────────────────────────
  var sessions = {};   // id -> EditSession
  var suppress = {};   // id -> bool (ignore change events during load)
  var versions = {};   // id -> edit counter, so Swift can tell if typing happened during a save
  var currentId = null;
  var placeholder = null;   // shown, read-only, when no document is open

  function emptySession() {
    if (!placeholder) { placeholder = ace.createEditSession("", "ace/mode/text"); }
    return placeholder;
  }

  function makeSession(text, filename) {
    var mode;
    try { mode = modelist.getModeForPath(filename || "").mode; } catch (e) { mode = "ace/mode/text"; }
    var s = ace.createEditSession(text || "", mode);
    // Swift hands over LF-only text and restores the file's own line endings on save.
    s.setNewLineMode("unix");
    s.setUseSoftTabs(true);
    s.setTabSize(4);
    return s;
  }

  window.Selway = {
    openDoc: function (id, text, filename, theme, wrap, keymap, fontSize) {
      var s = makeSession(text, filename);
      sessions[id] = s;
      suppress[id] = true;
      versions[id] = 0;
      s.setUseWrapMode(!!wrap);
      s.on("change", (function (docId, session) {
        return function () {
          // A closed document (or one reopened under the same id) reports nothing.
          if (sessions[docId] !== session || suppress[docId]) { return; }
          versions[docId] = (versions[docId] || 0) + 1;
          bridge("changed", { id: docId });
        };
      })(id, s));
      this.switchDoc(id);
      if (theme) { editor.setTheme(theme); }
      editor.setKeyboardHandler(keymap || null);
      if (fontSize) { editor.setFontSize(fontSize); }
      s.getUndoManager().reset();
      setTimeout(function () { suppress[id] = false; editor.focus(); }, 0);
    },
    switchDoc: function (id) {
      if (!sessions[id]) { return; }
      currentId = id;
      editor.setSession(sessions[id]);
      editor.setReadOnly(false);
      editor.focus();
    },
    // Closing the shown document never leaves its text on screen: with no document
    // behind it, typing there could never be saved. Until Swift shows another tab
    // (or closes the window), an empty read-only page is shown instead.
    closeDoc: function (id) {
      if (sessions[id]) { delete sessions[id]; delete suppress[id]; delete versions[id]; }
      if (currentId === id) {
        currentId = null;
        editor.setSession(emptySession());
        editor.setReadOnly(true);
      }
    },
    // null (never "") for an unknown id, so a failed lookup can't be saved as an empty file.
    getDocContent: function (id) {
      if (!sessions[id]) { return null; }
      return { text: sessions[id].getValue(), version: versions[id] || 0 };
    },
    // Called after a save of `version`; edits made since then keep the tab modified.
    savedVersion: function (id, version) {
      if (sessions[id] && versions[id] !== version) { bridge("changed", { id: id }); }
    },
    // Reload from disk: replace the text without reporting it as an edit.
    replaceDoc: function (id, text) {
      var s = sessions[id];
      if (!s) { return; }
      suppress[id] = true;
      try { s.setValue(text); s.getUndoManager().reset(); }
      finally { suppress[id] = false; }
      versions[id] = 0;
      if (id === currentId) { mmRenderContent(); }
    },
    getModeId: function () { try { return editor.session.getMode().$id; } catch (e) { return "ERR:" + e; } },
    docCount: function () { var n = 0; for (var k in sessions) { n++; } return n; },
    setTheme: function (t) { editor.setTheme(t); mmRenderContent(); },
    setMinimap: function (on) {
      mmOn = !!on;
      document.body.classList.toggle("mm-off", !mmOn);
      editor.resize(true);
      if (mmOn) { mmRenderContent(); } else { mmClear(); }
    },
    toggleMinimap: function () { this.setMinimap(!mmOn); bridge("minimap", { on: mmOn }); },
    setWrapAll: function (b) { for (var k in sessions) { sessions[k].setUseWrapMode(!!b); } },
    setKeymap: function (k) { editor.setKeyboardHandler(k || null); },
    setFontSize: function (n) { editor.setFontSize(n); },
    find: function () { editor.execCommand("find"); },
    replace: function () { editor.execCommand("replace"); },
    gotoLine: function () { editor.execCommand("gotoline"); },
    settings: function () { try { editor.showSettingsMenu(); } catch (e) {} },
    palette: function () { showPalette(); },
    focus: function () { editor.focus(); }
  };

  // ── Commands wired to the Swift side ────────────────────────────────────
  // None of these edit text, so they're marked readOnly: Ace skips commands without
  // it while the editor is read-only (no document open), and ⌘S, ⌘O and ⌘W must
  // still work then.
  editor.commands.addCommand({
    name: "Save File", readOnly: true, bindKey: { mac: "Cmd-S", win: "Ctrl-S" },
    // Always answered: with no document open Swift says there's nothing to save.
    exec: function () { bridge("save", currentId ? { id: currentId } : null); }
  });
  editor.commands.addCommand({
    name: "Open File…", readOnly: true, bindKey: { mac: "Cmd-O", win: "Ctrl-O" },
    exec: function () { bridge("open"); }
  });
  editor.commands.addCommand({
    name: "Close Tab", readOnly: true, bindKey: { mac: "Cmd-W", win: "Ctrl-W" },
    exec: function () { if (currentId) { bridge("closeTab", { id: currentId }); } }
  });
  editor.commands.addCommand({
    name: "Command Palette", readOnly: true, bindKey: { mac: "Cmd-Shift-P", win: "Ctrl-Shift-P" },
    exec: function () { showPalette(); }
  });
  editor.commands.addCommand({
    name: "Settings…", readOnly: true, bindKey: { mac: "Cmd-,", win: "Ctrl-," },
    exec: function () { try { editor.showSettingsMenu(); } catch (e) {} }
  });
  editor.commands.addCommand({
    name: "Toggle Minimap", readOnly: true, bindKey: { mac: "Cmd-Shift-M", win: "Ctrl-Shift-M" },
    exec: function () { window.Selway.toggleMinimap(); }
  });

  // ── Minimap (canvas code overview) ──────────────────────────────────────
  var mmWrap    = document.getElementById("minimap");
  var mmCanvas  = document.getElementById("mm");
  var mmCtx     = mmCanvas.getContext("2d");
  var mmBuf     = document.createElement("canvas");   // cached code shape
  var mmBufCtx  = mmBuf.getContext("2d");
  var mmOn      = true;
  var mmDrag    = false;
  var mmDark    = true;
  var mmLineH   = 3;
  var mmBg      = "#272822";
  var mmTimer   = null;
  var mmDPR     = window.devicePixelRatio || 1;

  function mmIsDark() {
    try {
      var el = document.querySelector(".ace_editor");
      var m = getComputedStyle(el).backgroundColor.match(/\d+/g);
      if (!m) { return true; }
      return (0.299 * +m[0] + 0.587 * +m[1] + 0.114 * +m[2]) < 128;
    } catch (e) { return true; }
  }
  function mmPalette(dark) {
    return dark ? {
      def:"rgba(171,178,191,0.80)", comment:"rgba(110,118,129,0.65)",
      string:"rgba(152,195,121,0.90)", keyword:"rgba(198,120,221,0.92)",
      number:"rgba(209,154,102,0.92)", func:"rgba(97,175,239,0.92)"
    } : {
      def:"rgba(60,63,68,0.80)", comment:"rgba(160,160,160,0.70)",
      string:"rgba(80,161,79,0.90)", keyword:"rgba(166,38,164,0.92)",
      number:"rgba(196,118,0,0.92)", func:"rgba(64,120,242,0.92)"
    };
  }
  function mmColorFor(type, C) {
    if (!type) { return C.def; }
    if (type.indexOf("comment") >= 0) { return C.comment; }
    if (type.indexOf("string")  >= 0) { return C.string; }
    if (type.indexOf("keyword") >= 0 || type.indexOf("storage") >= 0) { return C.keyword; }
    if (type.indexOf("constant") >= 0 || type.indexOf("numeric") >= 0) { return C.number; }
    if (type.indexOf("support") >= 0 || type.indexOf("function") >= 0 || type.indexOf("entity") >= 0) { return C.func; }
    return C.def;
  }
  function mmSize() {
    var w = mmWrap.clientWidth  || 88;
    var h = mmWrap.clientHeight || 1;
    mmCanvas.width = mmBuf.width  = Math.max(1, Math.floor(w * mmDPR));
    mmCanvas.height = mmBuf.height = Math.max(1, Math.floor(h * mmDPR));
  }
  function mmClear() {
    mmCtx.clearRect(0, 0, mmCanvas.width, mmCanvas.height);
  }
  function mmRenderContent() {
    if (!mmOn) { return; }
    mmSize();
    var session = editor.session;
    var n = Math.max(1, session.getLength());
    var w = mmBuf.width, h = mmBuf.height;
    mmDark = mmIsDark();
    var C = mmPalette(mmDark);
    try {
      var aceEl = document.querySelector(".ace_editor");
      var bg = aceEl ? getComputedStyle(aceEl).backgroundColor : "";
      if (!bg || bg === "rgba(0, 0, 0, 0)" || bg === "transparent") {
        bg = mmDark ? "#272822" : "#ffffff";
      }
      mmBg = bg;
      mmWrap.style.background = bg;
    } catch (e) { mmBg = mmDark ? "#272822" : "#ffffff"; }
    mmBufCtx.clearRect(0, 0, w, h);
    mmLineH = Math.min(3 * mmDPR, h / n);
    var charW = 0.95 * mmDPR;
    var padX  = 3 * mmDPR;
    var rh    = Math.max(mmLineH * 0.8, 0.6);
    var step  = n > 20000 ? Math.ceil(n / 20000) : 1;
    for (var row = 0; row < n; row += step) {
      var y = row * mmLineH;
      if (y > h) { break; }
      var tokens = null;
      try { tokens = session.getTokens(row); } catch (e) {}
      var x = padX;
      if (tokens && tokens.length) {
        for (var t = 0; t < tokens.length && x < w; t++) {
          var val = tokens[t].value, col = mmColorFor(tokens[t].type, C);
          mmBufCtx.fillStyle = col;
          for (var i = 0; i < val.length; i++) {
            var ch = val[i];
            if (ch === " ") { x += charW; continue; }
            if (ch === "\t") { x += charW * 2; continue; }
            mmBufCtx.fillRect(x, y, charW * 0.9, rh);
            x += charW;
            if (x > w) { break; }
          }
        }
      } else {
        var line = session.getLine(row) || "";
        if (line.length) {
          mmBufCtx.fillStyle = C.def;
          mmBufCtx.fillRect(padX, y, Math.min(line.length * charW, w - padX), rh);
        }
      }
    }
    mmPaint();
  }
  function mmPaint() {
    if (!mmOn) { return; }
    var w = mmCanvas.width, h = mmCanvas.height;
    mmCtx.clearRect(0, 0, w, h);
    mmCtx.fillStyle = mmBg;
    mmCtx.fillRect(0, 0, w, h);
    mmCtx.drawImage(mmBuf, 0, 0);
    var first = editor.getFirstVisibleRow();
    var last  = editor.getLastVisibleRow();
    var y0 = first * mmLineH;
    var y1 = (last + 1) * mmLineH;
    mmCtx.fillStyle   = mmDark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.07)";
    mmCtx.fillRect(0, y0, w, Math.max(y1 - y0, 2));
    mmCtx.strokeStyle = mmDark ? "rgba(255,255,255,0.22)" : "rgba(0,0,0,0.18)";
    mmCtx.lineWidth   = mmDPR;
    mmCtx.strokeRect(0.5 * mmDPR, y0 + 0.5 * mmDPR, w - mmDPR, Math.max(y1 - y0, 2) - mmDPR);
  }
  function mmScheduleContent() {
    if (mmTimer) { return; }
    mmTimer = setTimeout(function () { mmTimer = null; mmRenderContent(); }, 90);
  }
  function mmScrollToClientY(clientY) {
    var rect = mmCanvas.getBoundingClientRect();
    var y = (clientY - rect.top) * mmDPR;
    var row = Math.max(0, Math.floor(y / mmLineH));
    editor.scrollToLine(row, true, false);
  }

  mmCanvas.addEventListener("mousedown", function (e) {
    mmDrag = true; mmScrollToClientY(e.clientY); e.preventDefault();
  });
  window.addEventListener("mousemove", function (e) { if (mmDrag) { mmScrollToClientY(e.clientY); } });
  window.addEventListener("mouseup", function () { mmDrag = false; });
  window.addEventListener("resize", function () { mmRenderContent(); });

  editor.renderer.on("afterRender", mmPaint);
  editor.on("change", mmScheduleContent);
  editor.on("changeSession", function () { mmRenderContent(); });
  // Themes load asynchronously in Ace — re-render the minimap once the theme
  // (and thus the real background color) is actually applied.
  editor.renderer.on("themeLoaded", function () { mmScheduleContent(); });

  // ── Command palette ─────────────────────────────────────────────────────
  var pEl   = document.getElementById("selway-palette");
  var pIn   = document.getElementById("selway-palette-input");
  var pList = document.getElementById("selway-palette-list");
  var pItems = [];
  var pSel = 0;

  function allCommands() {
    var out = [], bn = editor.commands.byName;
    for (var n in bn) { if (bn[n] && bn[n].exec && bn[n].name) { out.push(bn[n].name); } }
    out.sort();
    return out;
  }
  function fuzzy(q, s) {
    q = q.toLowerCase(); s = s.toLowerCase();
    var i = 0;
    for (var j = 0; j < s.length && i < q.length; j++) { if (s[j] === q[i]) { i++; } }
    return i === q.length;
  }
  function renderSel() {
    var lis = pList.children;
    for (var i = 0; i < lis.length; i++) { lis[i].className = (i === pSel) ? "sel" : ""; }
    if (lis[pSel]) { lis[pSel].scrollIntoView({ block: "nearest" }); }
  }
  function renderPalette() {
    var q = pIn.value.trim();
    var cmds = allCommands();
    pItems = q ? cmds.filter(function (c) { return fuzzy(q, c); }) : cmds;
    pSel = 0;
    pList.innerHTML = "";
    pItems.slice(0, 250).forEach(function (c, idx) {
      var li = document.createElement("li");
      li.textContent = c;
      li.addEventListener("mousedown", function (e) { e.preventDefault(); pSel = idx; runPalette(); });
      pList.appendChild(li);
    });
    renderSel();
  }
  function runPalette() {
    var name = pItems[pSel];
    hidePalette();
    if (name) { editor.execCommand(name); }
  }
  function showPalette() {
    pEl.style.display = "flex";
    pIn.value = "";
    renderPalette();
    setTimeout(function () { pIn.focus(); }, 0);
  }
  function hidePalette() { pEl.style.display = "none"; editor.focus(); }

  pIn.addEventListener("input", renderPalette);
  pIn.addEventListener("keydown", function (e) {
    if (e.key === "ArrowDown")      { pSel = Math.min(pSel + 1, pItems.length - 1); renderSel(); e.preventDefault(); }
    else if (e.key === "ArrowUp")   { pSel = Math.max(pSel - 1, 0); renderSel(); e.preventDefault(); }
    else if (e.key === "Enter")     { runPalette(); e.preventDefault(); }
    else if (e.key === "Escape")    { hidePalette(); e.preventDefault(); }
  });
  pEl.addEventListener("mousedown", function (e) { if (e.target === pEl) { hidePalette(); } });

  bridge("ready");
})();

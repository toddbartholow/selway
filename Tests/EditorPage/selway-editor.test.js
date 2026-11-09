// Tests the code editor page's document model (Selway/AceEditor/selway-editor.js)
// in Node, with Ace, the DOM and WebKit's message bridge stubbed out.
//   node Tests/EditorPage/selway-editor.test.js
// Run by `swift test` (EditorPageTests.swift) when node is on PATH.
"use strict";
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const source = fs.readFileSync(
  path.join(__dirname, "..", "..", "Selway", "AceEditor", "selway-editor.js"), "utf8");

/** Anything: every property is another stub, every call returns a stub. */
function stub() {
  const target = function () {};
  const proxy = new Proxy(target, {
    get(t, key) {
      if (key === Symbol.toPrimitive) { return () => 0; }
      if (key === "then") { return undefined; }
      if (!(key in t)) { t[key] = stub(); }
      return t[key];
    },
    apply() { return proxy; },
  });
  return proxy;
}

/** An object with real members where they matter and stubs everywhere else. */
function partial(real) {
  return new Proxy(real, {
    get(t, key) {
      if (!(key in t)) { t[key] = stub(); }
      return t[key];
    },
  });
}

function Session(text) {
  this.value = text;
  this.listeners = {};
}
Session.prototype.on = function (event, f) { (this.listeners[event] = this.listeners[event] || []).push(f); };
Session.prototype.getValue = function () { return this.value; };
Session.prototype.setValue = function (text) {
  this.value = text;
  (this.listeners.change || []).forEach((f) => f());
};
/** A user edit: same as setValue as far as change events go. */
Session.prototype.type = function (more) { this.setValue(this.value + more); };
Session.prototype.getUndoManager = function () { return { reset() {} }; };
Session.prototype.getLength = function () { return this.value.split("\n").length; };
Session.prototype.getTokens = function () { return []; };
Session.prototype.getLine = function (i) { return this.value.split("\n")[i] || ""; };
["setNewLineMode", "setUseSoftTabs", "setTabSize", "setUseWrapMode"].forEach((m) => {
  Session.prototype[m] = function () {};
});

function loadPage() {
  const messages = [];
  const timers = [];
  const sessions = [];
  const commands = {};
  const editor = partial({
    session: null,
    readOnly: false,
    setSession(s) { this.session = s; },
    setReadOnly(on) { this.readOnly = !!on; },
    on() {},
    renderer: partial({ on() {} }),
    commands: partial({ addCommand(c) { commands[c.name] = c; }, byName: {} }),
  });
  const context = {
    ace: {
      config: { set() {} },
      edit: () => editor,
      require: () => partial({ getModeForPath: () => ({ mode: "ace/mode/text" }), init() {} }),
      createEditSession(text) { const s = new Session(text); sessions.push(s); return s; },
    },
    document: stub(),
    getComputedStyle: stub(),
    setTimeout(f) { timers.push(f); return timers.length; },
    devicePixelRatio: 1,
    addEventListener() {},
    webkit: { messageHandlers: { bridge: { postMessage(m) { messages.push(JSON.parse(JSON.stringify(m))); } } } },
  };
  context.window = context;
  vm.createContext(context);
  vm.runInContext(source, context, { filename: "selway-editor.js" });
  const flush = () => { while (timers.length) { timers.shift()(); } };
  const json = (v) => JSON.parse(JSON.stringify(v));
  return { Selway: context.Selway, messages, sessions, flush, json, editor, commands };
}

const tests = {
  "announces ready once loaded"() {
    const { messages } = loadPage();
    assert.deepStrictEqual(messages, [{ type: "ready" }]);
  },

  "getDocContent is null (never empty text) for an unknown id"() {
    const { Selway } = loadPage();
    assert.strictEqual(Selway.getDocContent("missing"), null);
    assert.strictEqual(Selway.getDocContent(""), null);
    assert.strictEqual(Selway.getDocContent(undefined), null);
  },

  "opened document reports its text and version 0"() {
    const { Selway, json } = loadPage();
    Selway.openDoc("a", "hello", "x.txt", null, false, null, 14);
    assert.deepStrictEqual(json(Selway.getDocContent("a")), { text: "hello", version: 0 });
    Selway.openDoc("e", "", "empty.txt", null, false, null, 14);
    assert.deepStrictEqual(json(Selway.getDocContent("e")), { text: "", version: 0 });
  },

  "edits bump the version and report changed; loading doesn't"() {
    const { Selway, messages, sessions, flush, json } = loadPage();
    Selway.openDoc("a", "hello", "x.txt", null, false, null, 14);
    const s = sessions[0];
    s.setValue("hello");            // during load: suppressed
    assert.strictEqual(Selway.getDocContent("a").version, 0);
    flush();
    s.type("!");
    s.type("?");
    assert.deepStrictEqual(json(Selway.getDocContent("a")), { text: "hello!?", version: 2 });
    assert.deepStrictEqual(messages.slice(1), [{ type: "changed", id: "a" }, { type: "changed", id: "a" }]);
  },

  "savedVersion re-marks the tab only if typing happened during the save"() {
    const { Selway, messages, sessions, flush } = loadPage();
    Selway.openDoc("a", "x", "x.txt", null, false, null, 14);
    flush();
    sessions[0].type("1");
    const saved = Selway.getDocContent("a").version;   // Swift saves this version…
    const before = messages.length;
    Selway.savedVersion("a", saved);                   // …nothing typed since
    assert.strictEqual(messages.length, before);
    sessions[0].type("2");                         // typed while the save ran
    const afterEdit = messages.length;
    Selway.savedVersion("a", saved);
    assert.deepStrictEqual(messages.slice(afterEdit), [{ type: "changed", id: "a" }]);
    Selway.savedVersion("gone", 0);                    // unknown id: ignored
    assert.strictEqual(messages.length, afterEdit + 1);
  },

  "replaceDoc reloads without counting as an edit"() {
    const { Selway, messages, sessions, flush, json } = loadPage();
    Selway.openDoc("a", "mine", "x.txt", null, false, null, 14);
    flush();
    sessions[0].type("!");
    const before = messages.length;
    Selway.replaceDoc("a", "from disk");
    assert.deepStrictEqual(json(Selway.getDocContent("a")), { text: "from disk", version: 0 });
    assert.strictEqual(messages.length, before);
    sessions[0].type("+");
    assert.strictEqual(Selway.getDocContent("a").version, 1, "edits after a reload count again");
  },

  "versions are per document and closed documents are gone"() {
    const { Selway, sessions, flush } = loadPage();
    Selway.openDoc("a", "a", "a.txt", null, false, null, 14);
    Selway.openDoc("b", "b", "b.txt", null, false, null, 14);
    flush();
    sessions[1].type("1");
    assert.strictEqual(Selway.getDocContent("a").version, 0);
    assert.strictEqual(Selway.getDocContent("b").version, 1);
    assert.strictEqual(Selway.docCount(), 2);
    Selway.closeDoc("b");
    assert.strictEqual(Selway.getDocContent("b"), null);
    assert.strictEqual(Selway.docCount(), 1);
  },

  // ⌘W → Don't Save on the only tab used to leave its text on screen and editable,
  // with no document behind it: typing was never reported and ⌘S did nothing.
  "closing the shown document leaves nothing editable behind"() {
    const { Selway, messages, sessions, flush, editor, json } = loadPage();
    assert.strictEqual(editor.readOnly, true, "read-only until a document is open");
    Selway.openDoc("a", "secret edits", "a.txt", null, false, null, 14);
    flush();
    const closed = sessions[0];
    assert.strictEqual(editor.session, closed);
    assert.strictEqual(editor.readOnly, false);
    Selway.closeDoc("a");
    assert.notStrictEqual(editor.session, closed, "the closed document is no longer shown");
    assert.strictEqual(editor.session.getValue(), "");
    assert.strictEqual(editor.readOnly, true, "nothing to type into");
    const before = messages.length;
    closed.type("lost?");                         // a stray edit to the closed session
    assert.strictEqual(messages.length, before, "edits to a closed document aren't reported");
    assert.strictEqual(Selway.getDocContent("a"), null);

    Selway.openDoc("b", "b", "b.txt", null, false, null, 14);
    assert.strictEqual(editor.readOnly, false, "opening a document makes the editor editable again");
    assert.deepStrictEqual(json(Selway.getDocContent("b")), { text: "b", version: 0 });
  },

  "closing a background document keeps the shown one"() {
    const { Selway, sessions, editor } = loadPage();
    Selway.openDoc("a", "a", "a.txt", null, false, null, 14);
    Selway.openDoc("b", "b", "b.txt", null, false, null, 14);
    Selway.closeDoc("a");
    assert.strictEqual(editor.session, sessions[1]);
    assert.strictEqual(editor.readOnly, false);
  },

  "save and close shortcuts with no document open"() {
    const { Selway, messages, commands, flush } = loadPage();
    // Ace doesn't run commands without readOnly: true while the editor is read-only.
    for (const name of ["Save File", "Open File…", "Close Tab", "Command Palette", "Toggle Minimap"]) {
      assert.strictEqual(commands[name].readOnly, true, name + " works with no document open");
    }
    Selway.openDoc("a", "a", "a.txt", null, false, null, 14);
    flush();
    commands["Save File"].exec();
    assert.deepStrictEqual(messages[messages.length - 1], { type: "save", id: "a" });
    Selway.closeDoc("a");
    // ⌘S is still answered (Swift reports there is nothing to save) rather than ignored.
    commands["Save File"].exec();
    assert.deepStrictEqual(messages[messages.length - 1], { type: "save" });
    const before = messages.length;
    commands["Close Tab"].exec();
    assert.strictEqual(messages.length, before, "no tab to close");
  },
};

let failed = 0;
for (const [name, test] of Object.entries(tests)) {
  try {
    test();
    console.log("ok   " + name);
  } catch (e) {
    failed += 1;
    console.log("FAIL " + name + "\n     " + (e && e.stack || e));
  }
}
console.log(failed ? `${failed} failed` : `all ${Object.keys(tests).length} passed`);
process.exit(failed ? 1 : 0);

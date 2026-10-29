#!/usr/bin/env node
// Browser-level checks: drive the real server with a real browser engine.
//
// Everything below runs against the live harness (tests/harness) using headless
// Chrome over the DevTools Protocol. No dependencies — Node 22+ has a global
// WebSocket, which is all CDP needs.
//
// This is the layer the Swift suites can't reach: it proves the page actually
// loads, pairs, connects, switches view on rotation, and that touching the
// trackpad produces commands the Mac accepts.
//
// Usage: node tests/ui-check.js <httpBase> <pin> [--shots <dir>]

const { spawn } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const BASE = process.argv[2] || "http://127.0.0.1:18765";
const PIN = process.argv[3];
const shotsIndex = process.argv.indexOf("--shots");
const SHOTS = shotsIndex > 0 ? process.argv[shotsIndex + 1] : null;

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const CDP_PORT = 9222;
const IPHONE = { width: 390, height: 844 };     // iPhone 14/15 logical size

let passed = 0, failed = 0;
function check(label, ok, detail = "") {
  if (ok) { passed++; console.log(`  ✓ ${label}`); }
  else { failed++; console.log(`  ✗ ${label}${detail ? " — " + detail : ""}`); }
}
function group(name) { console.log(`\n${name}`); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ───────── CDP plumbing ─────────

class CDP {
  constructor(ws) { this.ws = ws; this.id = 0; this.pending = new Map(); }

  static async attach() {
    for (let i = 0; i < 50; i++) {
      try {
        const response = await fetch(`http://127.0.0.1:${CDP_PORT}/json/list`);
        const targets = await response.json();
        const page = targets.find((t) => t.type === "page");
        if (page) {
          const ws = new WebSocket(page.webSocketDebuggerUrl);
          await new Promise((resolve, reject) => {
            ws.onopen = resolve;
            ws.onerror = reject;
          });
          const cdp = new CDP(ws);
          ws.onmessage = (event) => cdp.onMessage(JSON.parse(event.data));
          return cdp;
        }
      } catch (e) { /* chrome still starting */ }
      await sleep(200);
    }
    throw new Error("could not attach to Chrome");
  }

  onMessage(message) {
    if (message.id && this.pending.has(message.id)) {
      const { resolve, reject } = this.pending.get(message.id);
      this.pending.delete(message.id);
      if (message.error) reject(new Error(JSON.stringify(message.error)));
      else resolve(message.result);
    }
  }

  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`${method} timed out`));
        }
      }, 15000);
    });
  }

  /// Evaluate JS in the page and return its value.
  async eval(expression) {
    const result = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.exception?.description || "eval threw");
    }
    return result.result.value;
  }

  async viewport(width, height) {
    await this.send("Emulation.setDeviceMetricsOverride", {
      width, height, deviceScaleFactor: 2, mobile: true,
    });
  }

  async navigate(url) {
    await this.send("Page.navigate", { url });
    // Wait for the document to finish and our script to run.
    for (let i = 0; i < 60; i++) {
      const state = await this.eval("document.readyState").catch(() => null);
      if (state === "complete") { await sleep(300); return; }
      await sleep(100);
    }
  }

  async screenshot(name) {
    if (!SHOTS) return;
    const { data } = await this.send("Page.captureScreenshot", { format: "png" });
    fs.mkdirSync(SHOTS, { recursive: true });
    fs.writeFileSync(path.join(SHOTS, `${name}.png`), Buffer.from(data, "base64"));
  }

  /// Dispatch a real touch sequence on an element, by its centre.
  async touchDrag(selector, dx, dy, steps = 10) {
    const box = await this.centreOf(selector);
    const point = (x, y) => [{ x: Math.round(x), y: Math.round(y), radiusX: 10, radiusY: 10, force: 1 }];
    await this.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: point(box.x, box.y) });
    for (let i = 1; i <= steps; i++) {
      await this.send("Input.dispatchTouchEvent", {
        type: "touchMove",
        touchPoints: point(box.x + (dx * i) / steps, box.y + (dy * i) / steps),
      });
      await sleep(16);
    }
    await this.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
  }

  async centreOf(selector) {
    const box = await this.eval(`(() => {
      const el = document.querySelector(${JSON.stringify(selector)});
      if (!el) return null;
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) return null;
      return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
    })()`);
    if (!box) throw new Error(`no visible element ${selector}`);
    return box;
  }

  /// Tap with a real touch sequence. Needed for the trackpad, which listens for
  /// touch events and calls preventDefault — so it deliberately never receives
  /// the synthesized click a tap would otherwise produce.
  async touchTap(selector) {
    const box = await this.centreOf(selector);
    const points = [{ x: Math.round(box.x), y: Math.round(box.y), radiusX: 10, radiusY: 10, force: 1 }];
    await this.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: points });
    await sleep(60);
    await this.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
  }

  /// Press and hold with a real touch sequence, then release. `ms` is how long
  /// the finger stays down, which is the whole point of the gesture.
  async touchHold(selector, ms) {
    const box = await this.centreOf(selector);
    const points = [{ x: Math.round(box.x), y: Math.round(box.y), radiusX: 10, radiusY: 10, force: 1 }];
    await this.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: points });
    await sleep(ms);
    await this.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
  }

  /// Tap a control. Buttons here listen for `click` or `pointerdown`, both of
  /// which a real finger produces via the browser's mouse-event compatibility
  /// path — so dispatching mouse events is what actually exercises them.
  /// Synthetic touch events alone do not generate a click.
  async tap(selector) {
    const box = await this.centreOf(selector);
    const common = { x: Math.round(box.x), y: Math.round(box.y), button: "left", clickCount: 1 };
    await this.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...common });
    await this.send("Input.dispatchMouseEvent", { type: "mousePressed", ...common });
    await sleep(40);
    await this.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...common });
  }
}

// ───────── the checks ─────────

(async () => {
  if (!PIN) {
    console.error("usage: node tests/ui-check.js <httpBase> <pin> [--shots dir]");
    process.exit(2);
  }

  const profile = fs.mkdtempSync("/tmp/remotemac-chrome-");
  const chrome = spawn(CHROME, [
    "--headless=new",
    `--remote-debugging-port=${CDP_PORT}`,
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-extensions",
    "--hide-scrollbars",
    "about:blank",
  ], { stdio: "ignore" });

  let cdp;
  try {
    cdp = await CDP.attach();
    await cdp.send("Page.enable");
    await cdp.send("Runtime.enable");
    await cdp.viewport(IPHONE.width, IPHONE.height);

    group("Page loads");
    await cdp.navigate(BASE + "/");
    check("document loaded", (await cdp.eval("document.readyState")) === "complete");
    check("title is remoteMac", (await cdp.eval("document.title")) === "remoteMac");
    check("logic.js executed", (await cdp.eval("typeof window.RemoteMacLogic")) === "object");
    check("stylesheet applied",
      (await cdp.eval("getComputedStyle(document.body).backgroundColor")) !== "rgba(0, 0, 0, 0)");
    const errors = await cdp.eval("window.__errors ? window.__errors.length : 0");
    check("no script errors recorded", errors === 0);

    group("Unpaired state");
    check("pairing screen is visible",
      (await cdp.eval("!document.getElementById('pair-screen').classList.contains('hidden')")) === true);
    check("PIN field is present",
      (await cdp.eval("!!document.getElementById('pair-pin')")) === true);
    await cdp.screenshot("01-pairing");

    group("Pairing through the real UI");
    // Type the PIN into the field and press the button, exactly as a user would.
    await cdp.eval(`(() => {
      const f = document.getElementById('pair-pin');
      f.value = ${JSON.stringify(PIN)};
      return true;
    })()`);
    await cdp.tap("#pair-submit");
    await sleep(1200);

    check("a token was stored",
      (await cdp.eval("!!localStorage.getItem('remotemac.token.v1')")) === true);
    check("token is 256 bits of hex",
      (await cdp.eval("(localStorage.getItem('remotemac.token.v1')||'').length")) === 64);
    check("pairing screen dismissed",
      (await cdp.eval("document.getElementById('pair-screen').classList.contains('hidden')")) === true);
    check("connection indicator is live",
      (await cdp.eval("document.getElementById('dot').classList.contains('on')")) === true);
    check("offline overlay is hidden",
      (await cdp.eval("document.getElementById('offline-screen').classList.contains('hidden')")) === true);

    group("Portrait defaults to the trackpad");
    const portraitView = await cdp.eval(
      "document.querySelector('.view.active') && document.querySelector('.view.active').id");
    check("trackpad is the active view", portraitView === "view-trackpad", `got ${portraitView}`);
    check("exactly one view is visible",
      (await cdp.eval("document.querySelectorAll('.view.active').length")) === 1);
    await cdp.screenshot("02-trackpad");

    group("Trackpad produces pointer commands");
    await cdp.eval("window.__sent = []; (function(){ const s = WebSocket.prototype.send; WebSocket.prototype.send = function(d){ try { window.__sent.push(JSON.parse(d)); } catch(e){} return s.call(this,d); }; })()");
    await cdp.touchDrag("#trackpad", 90, 60);
    await sleep(400);
    const moves = await cdp.eval("window.__sent.filter(m => m.t === 'pointer.move').length");
    check("dragging emits pointer.move", moves > 0, `${moves} messages`);
    const shaped = await cdp.eval(`(() => {
      const m = window.__sent.find(x => x.t === 'pointer.move');
      return m && m.v === 1 && typeof m.dx === 'number' && typeof m.dy === 'number';
    })()`);
    check("messages carry v:1 and numeric deltas", shaped === true);
    const withinBounds = await cdp.eval(
      "window.__sent.filter(m=>m.t==='pointer.move').every(m=>Math.abs(m.dx)<=200&&Math.abs(m.dy)<=200)");
    check("deltas stay inside the server's bounds", withinBounds === true);
    const noErrors = await cdp.eval("(window.__serverErrors||[]).length");
    check("server reported no protocol errors", noErrors === 0, String(noErrors));

    group("Tapping the trackpad clicks");
    await cdp.eval("window.__sent = []");
    await cdp.touchTap("#trackpad");
    await sleep(400);
    const clicks = await cdp.eval("window.__sent.filter(m => m.t === 'pointer.click').length");
    check("a tap emits pointer.click", clicks === 1, `${clicks} clicks`);

    group("View switching");
    await cdp.tap('#switcher .tab[data-view="shortcuts"]');
    await sleep(350);
    check("shortcuts view activates",
      (await cdp.eval("document.querySelector('.view.active').id")) === "view-shortcuts");
    const buttonCount = await cdp.eval("document.querySelectorAll('#deck-pages .deck-btn').length");
    check("the deck rendered buttons", buttonCount > 0, `${buttonCount} buttons`);
    await cdp.screenshot("03-shortcuts");

    group("Shortcuts run by id");
    await cdp.eval("window.__sent = []");
    await cdp.tap("#deck-pages .deck-btn");
    await sleep(400);
    const run = await cdp.eval("window.__sent.find(m => m.t === 'shortcut.run')");
    check("tapping a button sends shortcut.run", !!run);
    check("it carries only an id, never a target",
      !!run && typeof run.id === "string" && run.target === undefined && run.keyCode === undefined);

    group("Rotation switches to the keyboard");
    await cdp.viewport(IPHONE.height, IPHONE.width);     // landscape
    await sleep(600);
    const landscapeView = await cdp.eval("document.querySelector('.view.active').id");
    check("landscape shows the keyboard automatically",
      landscapeView === "view-keyboard", `got ${landscapeView}`);
    check("the text area is present",
      (await cdp.eval("!!document.getElementById('kb-input')")) === true);
    await cdp.screenshot("04-keyboard-landscape");

    group("Typing sends grapheme-correct text");
    await cdp.eval("window.__sent = []");
    // Drive the textarea the way the software keyboard does: set value, fire input.
    await cdp.eval(`(() => {
      const t = document.getElementById('kb-input');
      t.value = 'hi';
      t.dispatchEvent(new Event('input', { bubbles: true }));
      return true;
    })()`);
    await sleep(250);
    const typed = await cdp.eval("window.__sent.filter(m => m.t === 'text.insert').map(m => m.text)");
    check("typing emits text.insert", Array.isArray(typed) && typed.join("") === "hi",
      JSON.stringify(typed));

    // Now the emoji case: append one, then delete it. Exactly one backspace.
    await cdp.eval("window.__sent = []");
    await cdp.eval(`(() => {
      const t = document.getElementById('kb-input');
      t.value = 'hi👋';
      t.dispatchEvent(new Event('input', { bubbles: true }));
      return true;
    })()`);
    await sleep(200);
    await cdp.eval("window.__sent = []");
    await cdp.eval(`(() => {
      const t = document.getElementById('kb-input');
      t.value = 'hi';
      t.dispatchEvent(new Event('input', { bubbles: true }));
      return true;
    })()`);
    await sleep(250);
    const backspaces = await cdp.eval(
      "window.__sent.filter(m => m.t === 'key.press' && m.keyCode === 51).length");
    check("deleting an emoji sends exactly ONE backspace", backspaces === 1, `${backspaces} sent`);

    group("Return sends Enter, not a newline");
    await cdp.eval("window.__sent = []");
    // How iOS reports the software keyboard's Return key.
    await cdp.eval(`(() => {
      const t = document.getElementById('kb-input');
      t.focus();
      t.dispatchEvent(new InputEvent('beforeinput', {
        inputType: 'insertLineBreak', bubbles: true, cancelable: true }));
      return true;
    })()`);
    await sleep(300);
    const enterFromKeyboard = await cdp.eval("window.__sent.find(m => m.t === 'key.press')");
    check("the keyboard's Return sends key.press 36",
      !!enterFromKeyboard && enterFromKeyboard.keyCode === 36,
      JSON.stringify(enterFromKeyboard));
    check("and does NOT send a newline as text",
      (await cdp.eval("window.__sent.filter(m => m.t === 'text.insert').length")) === 0);
    check("the staging buffer stays clean",
      (await cdp.eval("document.getElementById('kb-input').value.includes('\\n')")) === false);

    // A newline arriving through the diff (e.g. pasted multi-line text) must
    // also become Enter rather than an inserted character.
    // Start from an empty buffer, or the diff legitimately emits backspaces
    // for whatever the previous check left behind.
    await cdp.tap("#kb-clear");
    await sleep(250);
    await cdp.eval("window.__sent = []");
    await cdp.eval(`(() => {
      const t = document.getElementById('kb-input');
      t.value = 'one\\ntwo';
      t.dispatchEvent(new Event('input', { bubbles: true }));
      return true;
    })()`);
    await sleep(350);
    const pasted = await cdp.eval("window.__sent.map(m => m.t + ':' + (m.text || m.keyCode))");
    check("pasted multi-line text becomes text, Enter, text",
      JSON.stringify(pasted) === JSON.stringify(["text.insert:one", "key.press:36", "text.insert:two"]),
      JSON.stringify(pasted));

    group("Enter clears the staging box");
    await cdp.tap("#kb-clear");
    await sleep(200);
    await cdp.eval(`(() => {
      const t = document.getElementById('kb-input');
      t.value = 'ls -la';
      t.dispatchEvent(new Event('input', { bubbles: true }));
      return true;
    })()`);
    await sleep(300);
    check("text is staged before Enter",
      (await cdp.eval("document.getElementById('kb-input').value")) === "ls -la");
    await cdp.eval("window.__sent = []");
    await cdp.eval(`(() => {
      document.getElementById('kb-input').dispatchEvent(new InputEvent('beforeinput', {
        inputType: 'insertLineBreak', bubbles: true, cancelable: true }));
      return true;
    })()`);
    await sleep(300);
    check("Enter is sent", (await cdp.eval(
      "window.__sent.some(m => m.t === 'key.press' && m.keyCode === 36)")) === true);
    check("the box is emptied afterwards",
      (await cdp.eval("document.getElementById('kb-input').value")) === "");
    // The diff baseline must move with it, or the next keystroke emits a
    // backspace for every character that was just cleared.
    await cdp.eval("window.__sent = []");
    await cdp.eval(`(() => {
      const t = document.getElementById('kb-input');
      t.value = 'x';
      t.dispatchEvent(new Event('input', { bubbles: true }));
      return true;
    })()`);
    await sleep(300);
    check("typing after Enter sends no stray backspaces",
      (await cdp.eval("window.__sent.filter(m => m.t === 'key.press' && m.keyCode === 51).length")) === 0);
    check("and sends just the new character",
      (await cdp.eval("JSON.stringify(window.__sent.filter(m => m.t === 'text.insert').map(m => m.text))")) === '["x"]');


    group("The keyboard can be dismissed");
    await cdp.eval("document.getElementById('kb-input').focus()");
    await sleep(200);
    check("textarea is focused", (await cdp.eval("document.activeElement.id")) === "kb-input");
    await cdp.tap("#kb-hide");
    await sleep(300);
    check("Hide blurs it, dismissing the software keyboard",
      (await cdp.eval("document.activeElement.id")) !== "kb-input");
    check("and the keyboard view is still showing",
      (await cdp.eval("document.querySelector('.view.active').id")) === "view-keyboard");

    group("Rotating back restores the portrait view");
    await cdp.viewport(IPHONE.width, IPHONE.height);
    await sleep(600);
    const restored = await cdp.eval("document.querySelector('.view.active').id");
    check("returns to the shortcuts view the user was on",
      restored === "view-shortcuts", `got ${restored}`);

    group("Special keys and modifiers");
    await cdp.tap('#switcher .tab[data-view="keyboard"]');
    await sleep(300);
    await cdp.eval("window.__sent = []");
    await cdp.tap('#kb-special .sp[data-key="36"]');     // return
    await sleep(250);
    const enter = await cdp.eval("window.__sent.find(m => m.t === 'key.press')");
    check("return key sends key.press 36", !!enter && enter.keyCode === 36);

    await cdp.eval("window.__sent = []");
    await cdp.tap('#kb-mods .modchip[data-mod="command"]');
    await sleep(150);
    check("the command chip latches",
      (await cdp.eval("document.querySelector('#kb-mods .modchip[data-mod=\\'command\\']').classList.contains('on')")) === true);
    await cdp.tap('#kb-special .sp[data-key="36"]');
    await sleep(250);
    const withMod = await cdp.eval("window.__sent.find(m => m.t === 'key.press')");
    check("a latched modifier rides along",
      !!withMod && Array.isArray(withMod.mods) && withMod.mods.includes("command"));

    group("Tap runs a shortcut, hold edits it");
    // The two intents used to be separated by a global Edit mode, so a tap
    // meant different things depending on a toggle elsewhere on screen. These
    // check the gesture decides instead.
    await cdp.tap('#switcher .tab[data-view="shortcuts"]');
    await sleep(350);
    check("the hint says what a tap will do",
      (await cdp.eval("document.getElementById('deck-hint').textContent")).includes("hold to edit"));

    await cdp.eval("window.__sent = []");
    await cdp.touchHold("#deck-pages .deck-btn", 120);     // short: a tap
    await sleep(350);
    check("a short press runs the shortcut",
      (await cdp.eval("window.__sent.filter(m => m.t === 'shortcut.run').length")) === 1);
    check("and opens no editor",
      (await cdp.eval("document.getElementById('modal-root').innerHTML === ''")) === true);

    await cdp.eval("window.__sent = []");
    await cdp.touchHold("#deck-pages .deck-btn", 750);     // long: an edit
    await sleep(400);
    check("a long press opens the editor",
      (await cdp.eval("!!document.querySelector('#ed-type')")) === true);
    check("and does NOT also run the shortcut",
      (await cdp.eval("window.__sent.filter(m => m.t === 'shortcut.run').length")) === 0,
      await cdp.eval("JSON.stringify(window.__sent.map(m => m.t))"));

    await cdp.tap("#ed-cancel");
    await sleep(300);
    check("cancelling the editor leaves the deck alone",
      (await cdp.eval("document.getElementById('modal-root').innerHTML === ''")) === true);

    group("The button editor and app picker");
    // This group exists because the editor had no coverage at all, which is how
    // an app picker that was always empty — and then produced decks the Mac
    // rejected — stayed broken without any suite noticing.
    await cdp.tap('#switcher .tab[data-view="shortcuts"]');
    await sleep(300);
    await cdp.tap("#deck-edit");
    await sleep(300);
    check("edit mode shows the add button",
      (await cdp.eval("!!document.querySelector('.deck-btn.add')")) === true);
    check("and the hint changes to match the mode",
      (await cdp.eval("document.getElementById('deck-hint').textContent")).includes("hold to reorder"));

    await cdp.tap(".deck-btn.add");
    await sleep(350);
    check("the editor sheet opened",
      (await cdp.eval("!!document.querySelector('#ed-type')")) === true);
    check("it defaults to a shortcut, with a live preview",
      (await cdp.eval("document.querySelector('#ed-preview').textContent")) === "⌘C");

    // Building a combo must update the preview through the shared key tables.
    await cdp.tap('#ed-specials button[data-key="36"]');
    await sleep(200);
    check("picking a special key updates the preview",
      (await cdp.eval("document.querySelector('#ed-preview').textContent")) === "⌘return");

    // Switching to the launch type is what requests the installed-app list.
    await cdp.eval("window.__sent = []");
    await cdp.tap('#ed-type button[data-type="launch"]');
    await sleep(1200);
    check("choosing App / link asks the Mac for installed apps",
      (await cdp.eval("window.__sent.some(m => m.t === 'apps.get')")) === true);

    const appRows = await cdp.eval("document.querySelectorAll('#ed-apps .app-row').length");
    check("the picker lists real installed apps", appRows > 0, `${appRows} rows`);

    const appIcons = await cdp.eval(
      "[...document.querySelectorAll('#ed-apps .app-row img')]" +
      ".filter(i => i.src.startsWith('data:image/png;base64,')).length");
    check("their icons are embedded PNGs", appIcons > 0, `${appIcons} icons`);

    // Every icon must fit the validator's cap, or saving the button fails.
    const worstIcon = await cdp.eval(
      "Math.max(0, ...[...document.querySelectorAll('#ed-apps .app-row img')].map(i => i.src.length))");
    check("no icon exceeds the 16 KB deck cap", worstIcon > 0 && worstIcon <= 16384,
      `largest ${worstIcon} bytes`);

    await cdp.screenshot("06-app-picker");

    // The round trip that was broken: pick an app, save, and have the Mac
    // accept the deck rather than answering with an error.
    // A rejection from the Mac surfaces as a toast, so that is what to assert:
    // the user-visible outcome, not an internal flag.
    await cdp.eval("window.__sent = []; document.getElementById('toast').textContent = ''");
    await cdp.tap("#ed-apps .app-row");
    await sleep(250);
    const pickedTarget = await cdp.eval("document.querySelector('#ed-target').value");
    check("picking an app fills in its path", pickedTarget.startsWith("/") &&
      pickedTarget.endsWith(".app"), pickedTarget);

    await cdp.tap("#ed-save");
    await sleep(800);
    check("the sheet closed on save",
      (await cdp.eval("document.getElementById('modal-root').innerHTML === ''")) === true);
    check("the deck was pushed to the Mac",
      (await cdp.eval("window.__sent.some(m => m.t === 'deck.save')")) === true);
    const complaint = await cdp.eval("document.getElementById('toast').textContent");
    check("and the Mac accepted it rather than complaining", complaint === "",
      `toast said: ${complaint}`);

    const savedButton = await cdp.eval(
      "JSON.parse(localStorage.getItem('remotemac.deck.v1')).folders" +
      ".flatMap(f => f.items).filter(i => i.type === 'launch' && i.icon" +
      " && i.icon.startsWith('data:image/png;base64,')).length");
    check("the saved button kept its app icon", savedButton > 0);

    await cdp.tap("#deck-edit");          // leave edit mode
    await sleep(250);

    group("Unpairing from settings");
    await cdp.tap("#settings-btn");
    await sleep(350);
    check("settings sheet opened",
      (await cdp.eval("!!document.querySelector('.modal-card')")) === true);
    await cdp.screenshot("05-settings");
    await cdp.tap("#st-unpair");
    await sleep(600);
    check("token cleared",
      (await cdp.eval("localStorage.getItem('remotemac.token.v1')")) === null);
    check("pairing screen returns",
      (await cdp.eval("!document.getElementById('pair-screen').classList.contains('hidden')")) === true);
  } catch (error) {
    failed++;
    console.log(`\n  ✗ harness error: ${error.message}`);
  } finally {
    try { if (cdp) cdp.ws.close(); } catch (e) {}
    chrome.kill("SIGTERM");
    await sleep(300);
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch (e) {}
  }

  console.log("\n" + "─".repeat(50));
  console.log(`${passed} passed, ${failed} failed`);
  if (SHOTS && passed > 0) console.log(`screenshots: ${SHOTS}`);
  process.exit(failed === 0 ? 0 : 1);
})();

// Client-side logic tests. Run with: node --test tests/
// Node's built-in test runner only — no dev dependencies, no package.json.

const test = require("node:test");
const assert = require("node:assert");
const L = require("../Web/logic.js");

test("graphemes counts user-perceived characters, not code units", () => {
  assert.deepStrictEqual(L.graphemes("abc"), ["a", "b", "c"]);
  assert.strictEqual(L.graphemes("").length, 0);

  // The whole reason this module exists: "👋".length is 2.
  assert.strictEqual("👋".length, 2);
  assert.strictEqual(L.graphemes("👋").length, 1);

  // A ZWJ family emoji is 11 UTF-16 units but one grapheme.
  assert.strictEqual("👨‍👩‍👧‍👦".length, 11);
  assert.strictEqual(L.graphemes("👨‍👩‍👧‍👦").length, 1);

  assert.strictEqual(L.graphemes("👋🏽").length, 1, "skin tone modifier binds");
  assert.strictEqual(L.graphemes("é").length, 1, "combining accent binds");
});

test("textDelta: appending sends no backspaces", () => {
  assert.deepStrictEqual(L.textDelta("", "hello"), { backspaces: 0, insert: "hello" });
  assert.deepStrictEqual(L.textDelta("hel", "hello"), { backspaces: 0, insert: "lo" });
});

test("textDelta: deleting one emoji sends exactly ONE backspace", () => {
  // The classic failure. Diffing by UTF-16 length gives backspaces: 2,
  // which deletes the emoji *and* the character before it.
  assert.deepStrictEqual(L.textDelta("hi 👋", "hi "), { backspaces: 1, insert: "" });
  assert.deepStrictEqual(L.textDelta("a👨‍👩‍👧‍👦", "a"), { backspaces: 1, insert: "" });
  assert.deepStrictEqual(L.textDelta("x👋🏽", "x"), { backspaces: 1, insert: "" });
  // Deleting an accented character outright: one backspace, nothing typed.
  assert.deepStrictEqual(L.textDelta("caf\u00e9", "caf"), { backspaces: 1, insert: "" });
  // Replacing it with the unaccented letter is one backspace plus one insert —
  // still exactly one backspace, which is the property that matters.
  assert.deepStrictEqual(L.textDelta("caf\u00e9", "cafe"), { backspaces: 1, insert: "e" });
  // Same for a decomposed e + combining acute, which is two code units.
  assert.deepStrictEqual(L.textDelta("cafe\u0301", "caf"), { backspaces: 1, insert: "" });
});

test("textDelta: deleting several graphemes counts them individually", () => {
  assert.deepStrictEqual(L.textDelta("ab👋cd", "ab"), { backspaces: 3, insert: "" });
});

test("textDelta: a mid-string edit rewinds to the divergence point", () => {
  // "cat" -> "cot": share "c", delete "at", type "ot".
  assert.deepStrictEqual(L.textDelta("cat", "cot"), { backspaces: 2, insert: "ot" });
});

test("textDelta: no change sends nothing", () => {
  assert.deepStrictEqual(L.textDelta("same", "same"), { backspaces: 0, insert: "" });
  assert.deepStrictEqual(L.textDelta("", ""), { backspaces: 0, insert: "" });
});

test("textDelta: emoji replaced by a different emoji", () => {
  const d = L.textDelta("hi 👋", "hi 👍");
  assert.strictEqual(d.backspaces, 1);
  assert.strictEqual(d.insert, "👍");
});

test("chunkByGrapheme never splits a cluster and reassembles exactly", () => {
  assert.deepStrictEqual(L.chunkByGrapheme("", 8), []);
  assert.deepStrictEqual(L.chunkByGrapheme("hello", 16), ["hello"]);

  const text = "abc👨‍👩‍👧‍👦def👋🏽ghi";
  const chunks = L.chunkByGrapheme(text, 8);
  assert.strictEqual(chunks.join(""), text, "lossless");
  for (const chunk of chunks) {
    // Every chunk must itself be a whole number of graphemes, i.e. splitting
    // and rejoining the chunk's graphemes reproduces it.
    assert.strictEqual(L.graphemes(chunk).join(""), chunk);
  }

  // An oversized single cluster is emitted whole rather than mangled.
  assert.deepStrictEqual(L.chunkByGrapheme("👨‍👩‍👧‍👦", 4), ["👨‍👩‍👧‍👦"]);

  // Chunks stay inside the cap when the content allows it.
  for (const chunk of L.chunkByGrapheme("a".repeat(25), 8)) {
    assert.ok(chunk.length <= 8, `chunk ${chunk.length} <= 8`);
  }
});

test("chunkByGrapheme output always fits the server's text cap", () => {
  // The server rejects text over 256 UTF-16 units; the client chunks at 200.
  const long = "👋".repeat(300);
  for (const chunk of L.chunkByGrapheme(long, 200)) {
    assert.ok(chunk.length <= 256, "within server limit");
  }
});

test("backoffDelay grows, is capped at 5s, and is jittered", () => {
  // With random = 0.5 the jitter factor is exactly 1.0.
  assert.strictEqual(L.backoffDelay(0, 0.5), 1000);
  assert.strictEqual(L.backoffDelay(1, 0.5), 2000);
  assert.strictEqual(L.backoffDelay(2, 0.5), 4000);
  assert.strictEqual(L.backoffDelay(3, 0.5), 5000, "capped");
  assert.strictEqual(L.backoffDelay(50, 0.5), 5000, "stays capped");

  // Jitter spans ±25% so a fleet of retries doesn't synchronise.
  assert.strictEqual(L.backoffDelay(3, 0), 3750);
  assert.strictEqual(L.backoffDelay(3, 1), 6250);

  // Never a tight loop: a Mac that is asleep must not be hammered.
  for (let a = 0; a < 10; a++) {
    assert.ok(L.backoffDelay(a, 0) >= 750, "never busy-loops");
  }
});

test("swipeDirection requires travel and a dominant axis", () => {
  assert.strictEqual(L.swipeDirection(0, 0, 70), null, "no movement");
  assert.strictEqual(L.swipeDirection(40, 0, 70), null, "below threshold");

  assert.strictEqual(L.swipeDirection(-100, 0, 70), "left");
  assert.strictEqual(L.swipeDirection(100, 0, 70), "right");
  assert.strictEqual(L.swipeDirection(0, -100, 70), "up");
  assert.strictEqual(L.swipeDirection(0, 100, 70), "down");

  // A 45° smudge is ambiguous and must fire nothing, rather than picking an
  // axis arbitrarily and sending the wrong action.
  assert.strictEqual(L.swipeDirection(80, 80, 70), null, "diagonal rejected");
  assert.strictEqual(L.swipeDirection(-80, 75, 70), null, "diagonal rejected");

  // Clearly horizontal despite some vertical drift.
  assert.strictEqual(L.swipeDirection(120, 20, 70), "right");
});

test("viewForSwipe moves one step and clamps at the ends", () => {
  // Bar order is shortcuts · trackpad · keyboard, so a left swipe walks right.
  assert.strictEqual(L.viewForSwipe("shortcuts", -1), "trackpad", "swipe left advances");
  assert.strictEqual(L.viewForSwipe("trackpad", -1), "keyboard");
  assert.strictEqual(L.viewForSwipe("keyboard", -1), "keyboard", "clamps, no wrap");
  assert.strictEqual(L.viewForSwipe("trackpad", 1), "shortcuts", "swipe right goes back");
  assert.strictEqual(L.viewForSwipe("shortcuts", 1), "shortcuts", "clamps, no wrap");
});

test("viewForOrientation: landscape shows the keyboard", () => {
  assert.strictEqual(L.viewForOrientation({
    landscape: true, manualOverride: false, current: "trackpad", lastPortraitView: "trackpad",
  }), "keyboard");
});

test("viewForOrientation: a manual override survives rotation", () => {
  assert.strictEqual(L.viewForOrientation({
    landscape: true, manualOverride: true, current: "trackpad", lastPortraitView: "trackpad",
  }), "trackpad", "user chose trackpad in landscape; respect it");
});

test("viewForOrientation: portrait restores the last portrait view", () => {
  assert.strictEqual(L.viewForOrientation({
    landscape: false, manualOverride: false, current: "keyboard", lastPortraitView: "shortcuts",
  }), "shortcuts");

  assert.strictEqual(L.viewForOrientation({
    landscape: false, manualOverride: false, current: "keyboard", lastPortraitView: undefined,
  }), "trackpad", "trackpad is the default");
});

test("viewForOrientation: portrait leaves a non-keyboard view alone", () => {
  // Rotating portrait->portrait (or a keyboard resize misread as a change)
  // must not move the user off the view they are using.
  assert.strictEqual(L.viewForOrientation({
    landscape: false, manualOverride: false, current: "shortcuts", lastPortraitView: "shortcuts",
  }), "shortcuts");
  assert.strictEqual(L.viewForOrientation({
    landscape: false, manualOverride: false, current: "trackpad", lastPortraitView: "trackpad",
  }), "trackpad");
});

test("rotating portrait -> landscape -> portrait returns you home", () => {
  let state = { landscape: false, manualOverride: false, current: "shortcuts", lastPortraitView: "shortcuts" };

  state.landscape = true;
  state.current = L.viewForOrientation(state);
  assert.strictEqual(state.current, "keyboard");

  state.landscape = false;
  state.current = L.viewForOrientation(state);
  assert.strictEqual(state.current, "shortcuts", "back to where the user was");
});

test("auto-keyboard only ever switches TO the keyboard", () => {
  const base = { isTextFocused: true, enabled: true, view: "trackpad",
                 dragging: false, buttonHeld: false };

  assert.strictEqual(L.shouldAutoShowKeyboard(base), true, "from trackpad");
  assert.strictEqual(L.shouldAutoShowKeyboard({ ...base, view: "shortcuts" }), true);

  // Never moves away from the keyboard, and never acts on losing focus — so a
  // click out of a text field cannot throw you off the view you are using.
  assert.strictEqual(L.shouldAutoShowKeyboard({ ...base, view: "keyboard" }), false);
  assert.strictEqual(L.shouldAutoShowKeyboard({ ...base, isTextFocused: false }), false);
});

test("auto-keyboard stays out of the way mid-interaction", () => {
  const base = { isTextFocused: true, enabled: true, view: "trackpad",
                 dragging: false, buttonHeld: false };
  assert.strictEqual(L.shouldAutoShowKeyboard({ ...base, dragging: true }), false,
    "not while dragging");
  assert.strictEqual(L.shouldAutoShowKeyboard({ ...base, buttonHeld: true }), false,
    "not while a mouse button is held");
});

test("auto-keyboard respects the setting", () => {
  const base = { isTextFocused: true, enabled: false, view: "trackpad",
                 dragging: false, buttonHeld: false };
  assert.strictEqual(L.shouldAutoShowKeyboard(base), false);
});

test("focus() is only attempted inside the activation window", () => {
  // Safari honours focus() for a short period after a real touch; outside it
  // the call is ignored and the user must tap. Attempting anyway is harmless
  // but the window is what makes zero-tap possible at all.
  assert.strictEqual(L.canRaiseKeyboard(0), true, "immediately after a tap");
  assert.strictEqual(L.canRaiseKeyboard(100), true);
  assert.strictEqual(L.canRaiseKeyboard(3999), true);
  assert.strictEqual(L.canRaiseKeyboard(4000), false, "window has closed");
  assert.strictEqual(L.canRaiseKeyboard(60000), false, "long idle");
  assert.strictEqual(L.canRaiseKeyboard(-1), false, "clock skew");
});

// ───────────────────────── key tables ─────────────────────────
//
// These moved out of app.js so they could be covered here: a wrong code in the
// table types the wrong character on the Mac, which is invisible to any test
// that only checks a message was sent.

test("keyCodeForChar maps characters case-insensitively", () => {
  assert.strictEqual(L.keyCodeForChar("a"), 0);
  assert.strictEqual(L.keyCodeForChar("A"), 0, "upper case maps to the same key");
  assert.strictEqual(L.keyCodeForChar("c"), 8);
  assert.strictEqual(L.keyCodeForChar(" "), 49);
  assert.strictEqual(L.keyCodeForChar("\\"), 42);
});

test("keyCodeForChar returns null rather than a wrong key", () => {
  // Returning a default would silently type the wrong character; the caller
  // falls back to text.insert instead.
  assert.strictEqual(L.keyCodeForChar("é"), null);
  assert.strictEqual(L.keyCodeForChar("👋"), null);
  assert.strictEqual(L.keyCodeForChar(""), null);
  assert.strictEqual(L.keyCodeForChar(null), null);
  assert.strictEqual(L.keyCodeForChar(undefined), null);
});

test("key code 0 is not mistaken for absent", () => {
  // "a" is key code 0, so any `code || fallback` or `if (code)` check in the
  // lookup chain would drop it.
  assert.strictEqual(L.keyCodeForChar("a"), 0);
  assert.notStrictEqual(L.keyCodeForChar("a"), null);
  assert.strictEqual(L.keyLabel(0), "A");
});

test("keyLabel names special keys and falls back safely", () => {
  assert.strictEqual(L.keyLabel(L.KEY_CODE_RETURN), "return");
  assert.strictEqual(L.keyLabel(L.KEY_CODE_BACKSPACE), "⌫");
  assert.strictEqual(L.keyLabel(49), "space");
  assert.strictEqual(L.keyLabel(122), "F1");
  assert.strictEqual(L.keyLabel(8), "C");
  assert.strictEqual(L.keyLabel(9999), "?", "unknown code never throws");
  assert.strictEqual(L.keyLabel(null), "?");
  assert.strictEqual(L.keyLabel(undefined), "?");
});

test("comboLabel writes modifiers in Apple's order", () => {
  // Tapped in any order, rendered in one: ⌃⌥⇧⌘.
  assert.strictEqual(L.comboLabel(8, ["command"]), "⌘C");
  assert.strictEqual(L.comboLabel(6, ["shift", "command"]), "⇧⌘Z");
  assert.strictEqual(L.comboLabel(6, ["command", "shift"]), "⇧⌘Z",
    "order of the input must not change the output");
  assert.strictEqual(
    L.comboLabel(40, ["command", "control", "shift", "option"]), "⌃⌥⇧⌘K");
  assert.strictEqual(L.comboLabel(8, []), "C", "no modifiers");
  assert.strictEqual(L.comboLabel(8, null), "C", "missing mods array");
  assert.strictEqual(L.comboLabel(8, ["bogus"]), "C", "unknown modifier is ignored");
});

test("every SPECIAL_KEYS entry has a distinct code and a label", () => {
  const codes = L.SPECIAL_KEYS.map((k) => k.keyCode);
  assert.strictEqual(new Set(codes).size, codes.length, "no duplicate key codes");
  for (const key of L.SPECIAL_KEYS) {
    assert.ok(key.label.length > 0, "every special key is labelled");
    assert.strictEqual(typeof key.keyCode, "number");
  }
});

test("KEYMAP has no duplicate codes", () => {
  // Two characters sharing a code means one of them types the other.
  const codes = Object.values(L.KEYMAP);
  assert.strictEqual(new Set(codes).size, codes.length);
});

test("MOD_ORDER and MOD_SYMBOL cover the same four modifiers", () => {
  assert.deepStrictEqual(
    [...L.MOD_ORDER].sort(), Object.keys(L.MOD_SYMBOL).sort(),
    "a modifier in one table but not the other renders blank");
});

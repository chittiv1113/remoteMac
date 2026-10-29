// Pure logic, separated from the DOM so it can be tested under `node --test`.
//
// What lives here is everything most likely to be subtly wrong: the text diff
// (where diffing in the wrong unit corrupts remote text), swipe direction,
// reconnect pacing, the view state machine, and the key tables.
//
// Loaded as a plain script in the browser (sets window.RemoteMacLogic) and
// require()d in tests. No bundler, no module system needed.

(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.RemoteMacLogic = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  // ───────────────────────── text ─────────────────────────

  const segmenter = (typeof Intl !== "undefined" && Intl.Segmenter)
    ? new Intl.Segmenter(undefined, { granularity: "grapheme" })
    : null;

  /// Split a string into user-perceived characters.
  ///
  /// This is the unit everything else here works in. An emoji is one grapheme
  /// but two or more UTF-16 code units, and `"👋".length === 2`, which is why
  /// `String.length`-based diffing emits two backspaces to delete one emoji.
  function graphemes(string) {
    if (!string) return [];
    if (segmenter) return Array.from(segmenter.segment(string), (s) => s.segment);
    return Array.from(string);   // code points — still better than UTF-16 units
  }

  /// Work out what to send to turn `previous` into `next`.
  ///
  /// Returns `{ backspaces, insert }`: how many ⌫ presses, then what text to
  /// type. Compares by grapheme and finds the common prefix, so an edit in the
  /// middle deletes back to the divergence point and retypes the tail.
  function textDelta(previous, next) {
    const before = graphemes(previous);
    const after = graphemes(next);

    let shared = 0;
    const limit = Math.min(before.length, after.length);
    while (shared < limit && before[shared] === after[shared]) shared++;

    return {
      backspaces: before.length - shared,
      insert: after.slice(shared).join(""),
    };
  }

  /// Split text into messages of at most `maxUnits` UTF-16 units without ever
  /// breaking a grapheme. A single cluster above the cap is emitted whole.
  function chunkByGrapheme(string, maxUnits) {
    const out = [];
    let current = "", count = 0;
    for (const cluster of graphemes(string)) {
      const size = cluster.length;
      if (count > 0 && count + size > maxUnits) { out.push(current); current = ""; count = 0; }
      current += cluster;
      count += size;
    }
    if (current) out.push(current);
    return out;
  }

  // ─────────────────────── reconnect ───────────────────────

  /// Capped exponential backoff with jitter. `random` is injectable so tests
  /// are deterministic.
  function backoffDelay(attempt, random) {
    const r = typeof random === "number" ? random : Math.random();
    const base = Math.min(5000, 1000 * Math.pow(2, attempt));
    return base * (0.75 + r * 0.5);
  }

  // ──────────────────────── gestures ───────────────────────

  /// Direction of a swipe, or null if it hasn't travelled far enough or is too
  /// diagonal to be unambiguous.
  function swipeDirection(dx, dy, threshold, dominance) {
    const minTravel = threshold === undefined ? 70 : threshold;
    const ratio = dominance === undefined ? 1.3 : dominance;
    if (Math.hypot(dx, dy) < minTravel) return null;

    const horizontal = Math.abs(dx) > Math.abs(dy);
    if (horizontal && Math.abs(dx) < Math.abs(dy) * ratio) return null;
    if (!horizontal && Math.abs(dy) < Math.abs(dx) * ratio) return null;

    if (horizontal) return dx < 0 ? "left" : "right";
    return dy < 0 ? "up" : "down";
  }

  // ────────────────────── view state ──────────────────────

  /// Left to right, as the bottom bar presents them. Trackpad sits in the
  /// middle because it is the one you reach for most.
  const VIEW_ORDER = ["shortcuts", "trackpad", "keyboard"];

  /// Which view a header swipe moves to. Clamps at the ends rather than wrapping.
  function viewForSwipe(current, dx) {
    const index = VIEW_ORDER.indexOf(current);
    if (index < 0) return current;
    const step = dx < 0 ? 1 : -1;
    const next = Math.max(0, Math.min(VIEW_ORDER.length - 1, index + step));
    return VIEW_ORDER[next];
  }

  /// The orientation rule:
  ///   landscape -> keyboard, unless the user overrode it this session
  ///   portrait  -> the last portrait view (trackpad by default)
  function viewForOrientation(state) {
    if (state.landscape) {
      return state.manualOverride ? state.current : "keyboard";
    }
    if (state.current === "keyboard") return state.lastPortraitView || "trackpad";
    return state.current;
  }

  /// Should the phone bring its keyboard view up because a text field gained
  /// focus on the Mac?
  ///
  /// Deliberately conservative. It only ever moves *to* the keyboard, never
  /// away, so it cannot pull a view out from under someone mid-task; it stays
  /// out of the way while a mouse button is held or a drag is in progress; and
  /// it does nothing if the user has turned it off.
  function shouldAutoShowKeyboard(state) {
    if (!state.isTextFocused) return false;
    if (!state.enabled) return false;
    if (state.view === "keyboard") return false;     // already there
    if (state.dragging || state.buttonHeld) return false;
    return true;
  }

  /// Whether a focus() call stands any chance of raising the iOS software
  /// keyboard: Safari only honours it inside the transient activation window
  /// that follows a real touch.
  function canRaiseKeyboard(msSinceGesture, windowMs) {
    const limit = windowMs === undefined ? 4000 : windowMs;
    return msSinceGesture >= 0 && msSinceGesture < limit;
  }

  // ──────────────────────── key tables ────────────────────────
  //
  // macOS virtual key codes. The Mac validates every code it receives against
  // its own allowlist, so this table is a convenience for the UI, never the
  // security boundary.

  const KEYMAP = {
    a:0, s:1, d:2, f:3, h:4, g:5, z:6, x:7, c:8, v:9, b:11,
    q:12, w:13, e:14, r:15, y:16, t:17,
    o:31, u:32, i:34, p:35, l:37, j:38, k:40, n:45, m:46,
    "1":18, "2":19, "3":20, "4":21, "5":23, "6":22, "7":26, "8":28, "9":25, "0":29,
    "-":27, "=":24, "[":33, "]":30, ";":41, "'":39,
    ",":43, ".":47, "/":44, "\\":42, "`":50, " ":49,
  };

  const SPECIAL_KEYS = [
    { label: "space", keyCode: 49 }, { label: "return", keyCode: 36 },
    { label: "tab", keyCode: 48 }, { label: "esc", keyCode: 53 },
    { label: "⌫", keyCode: 51 }, { label: "⌦", keyCode: 117 },
    { label: "←", keyCode: 123 }, { label: "→", keyCode: 124 },
    { label: "↑", keyCode: 126 }, { label: "↓", keyCode: 125 },
    { label: "home", keyCode: 115 }, { label: "end", keyCode: 119 },
    { label: "⇞", keyCode: 116 }, { label: "⇟", keyCode: 121 },
    { label: "F1", keyCode: 122 }, { label: "F2", keyCode: 120 },
    { label: "F3", keyCode: 99 }, { label: "F4", keyCode: 118 },
    { label: "F5", keyCode: 96 }, { label: "F6", keyCode: 97 },
    { label: "F7", keyCode: 98 }, { label: "F8", keyCode: 100 },
    { label: "F9", keyCode: 101 }, { label: "F10", keyCode: 109 },
    { label: "F11", keyCode: 103 }, { label: "F12", keyCode: 111 },
  ];

  const MOD_SYMBOL = { command: "⌘", control: "⌃", shift: "⇧", option: "⌥" };
  /// Apple's canonical order for writing a shortcut, so ⌃⌥⇧⌘K never renders
  /// as ⌘⇧⌥⌃K depending on the order the chips were tapped.
  const MOD_ORDER = ["control", "option", "shift", "command"];

  const KEY_CODE_RETURN = 36;
  const KEY_CODE_BACKSPACE = 51;

  /// The key code that types `ch`, or null if this keyboard layout has none.
  function keyCodeForChar(ch) {
    if (!ch) return null;
    const code = KEYMAP[ch.toLowerCase()];
    return code === undefined ? null : code;
  }

  /// Human label for a key code, for shortcut previews and button subtitles.
  function keyLabel(keyCode) {
    if (keyCode === null || keyCode === undefined) return "?";
    const special = SPECIAL_KEYS.find((s) => s.keyCode === keyCode);
    if (special) return special.label;
    for (const key in KEYMAP) {
      if (KEYMAP[key] === keyCode) return key === " " ? "space" : key.toUpperCase();
    }
    return "?";
  }

  /// A shortcut as a person writes it: modifiers in Apple's order, then the key.
  function comboLabel(keyCode, mods) {
    const held = mods || [];
    const symbols = MOD_ORDER.filter((m) => held.includes(m)).map((m) => MOD_SYMBOL[m]);
    return symbols.join("") + keyLabel(keyCode);
  }

  return {
    graphemes: graphemes,
    textDelta: textDelta,
    chunkByGrapheme: chunkByGrapheme,
    backoffDelay: backoffDelay,
    swipeDirection: swipeDirection,
    viewForSwipe: viewForSwipe,
    viewForOrientation: viewForOrientation,
    shouldAutoShowKeyboard: shouldAutoShowKeyboard,
    canRaiseKeyboard: canRaiseKeyboard,
    keyCodeForChar: keyCodeForChar,
    keyLabel: keyLabel,
    comboLabel: comboLabel,
    KEYMAP: KEYMAP,
    SPECIAL_KEYS: SPECIAL_KEYS,
    MOD_SYMBOL: MOD_SYMBOL,
    MOD_ORDER: MOD_ORDER,
    KEY_CODE_RETURN: KEY_CODE_RETURN,
    KEY_CODE_BACKSPACE: KEY_CODE_BACKSPACE,
  };
});

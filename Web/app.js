// remoteMac — the phone client.
//
// Three views (trackpad / shortcuts / keyboard) driven by orientation, a
// token-authenticated WebSocket on its own port, and a v1 command protocol.
// Zero dependencies: no bundler, no framework, no build step.
//
// Loaded after logic.js (pure, testable) and deck.js (the shortcut deck).
// What stays here is the parts that are inseparable from the connection: the
// socket, pairing, the view state machine, the trackpad, and the keyboard.

(function () {
  "use strict";

  const L = window.RemoteMacLogic;
  const Deck = window.RemoteMacDeck;
  const $ = (id) => document.getElementById(id);

  const PROTOCOL = 1;
  const TOKEN_KEY = "remotemac.token.v1";
  const SETTINGS_KEY = "remotemac.settings.v1";

  // ── protocol limits, mirrored from Sources/Protocol.swift ──
  //
  // The Mac rejects rather than clamps, so sending anything outside these
  // bounds is a dropped command and a visible stutter. Staying inside them is
  // the client's job; enforcing them is the Mac's.
  const MAX_POINTER_DELTA = 200;      // points, per pointer.move
  const MAX_SCROLL_DELTA = 500;       // points, per pointer.scroll
  const MAX_TEXT_UTF16 = 256;         // per text.insert
  /// Headroom under MAX_TEXT_UTF16, so a grapheme that straddles the boundary
  /// cannot push a chunk over the cap.
  const TEXT_CHUNK_UTF16 = 200;

  /// Discovered from /config.json rather than hardcoded, so the page and the
  /// server cannot disagree about where the control socket lives.
  let controlPort = null;
  const CONTROL_PORT_FALLBACK = 8766;

  // ───────────────────────── settings ─────────────────────────

  const SETTINGS_DEFAULTS = {
    moveSpeed: 1.1, accel: 0.05, scrollSpeed: 1.0, scrollDir: 1,
    theme: "dark", pointerHz: 60, autoKeyboard: true,
  };
  const MIN_POINTER_HZ = 30, MAX_POINTER_HZ = 120;

  let settings = loadSettings();

  function loadSettings() {
    try {
      const raw = localStorage.getItem(SETTINGS_KEY);
      if (raw) return Object.assign({}, SETTINGS_DEFAULTS, JSON.parse(raw));
    } catch (e) { /* private browsing, or corrupt — use defaults */ }
    return Object.assign({}, SETTINGS_DEFAULTS);
  }

  function saveSettings() {
    try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings)); } catch (e) {}
  }

  const clamp = (value, lo, hi) => Math.max(lo, Math.min(hi, value));
  const now = () => performance.now();

  function buzz() {
    try { if (navigator.vibrate) navigator.vibrate(8); } catch (e) {}
  }

  const TOAST_MS = 2600;
  let toastTimer = null;
  function toast(message) {
    const el = $("toast");
    el.textContent = message;
    el.classList.add("on");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove("on"), TOAST_MS);
  }

  // ─────────────────────────── theme ───────────────────────────

  const themeMQ = window.matchMedia("(prefers-color-scheme: dark)");

  function applyTheme() {
    const chosen = settings.theme || "dark";
    const resolved = chosen === "system" ? (themeMQ.matches ? "dark" : "light") : chosen;
    document.documentElement.setAttribute("data-theme", resolved);
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", resolved === "light" ? "#ececed" : "#0a0a0c");
  }
  themeMQ.addEventListener("change", () => { if (settings.theme === "system") applyTheme(); });
  applyTheme();

  // ────────────────────── token and pairing ──────────────────────

  function storedToken() {
    try { return localStorage.getItem(TOKEN_KEY); } catch (e) { return null; }
  }
  function storeToken(token) {
    try { localStorage.setItem(TOKEN_KEY, token); } catch (e) {}
  }
  function clearToken() {
    try { localStorage.removeItem(TOKEN_KEY); } catch (e) {}
  }

  const pairScreen = $("pair-screen");
  const pairError = $("pair-error");
  const PIN_PATTERN = /^\d{6}$/;

  function showPairScreen(message) {
    pairScreen.classList.remove("hidden");
    pairError.textContent = message || "";
    $("pair-pin").value = "";
  }
  function hidePairScreen() { pairScreen.classList.add("hidden"); }

  async function submitPIN() {
    const pin = $("pair-pin").value.trim();
    if (!PIN_PATTERN.test(pin)) { pairError.textContent = "Enter all six digits."; return; }

    const button = $("pair-submit");
    button.disabled = true;
    pairError.textContent = "Checking…";
    try {
      const response = await fetch("/pair", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: "pin=" + encodeURIComponent(pin),
      });
      const payload = await response.json().catch(() => ({}));

      if (response.ok && payload.token) {
        storeToken(payload.token);
        pairError.textContent = "";
        hidePairScreen();
        connect();
        return;
      }
      if (response.status === 429) {
        pairError.textContent = "Too many attempts. Wait " + (payload.retryAfter || 30) + "s.";
      } else if (response.status === 401) {
        pairError.textContent = "Wrong PIN. Check the Mac's menu bar.";
      } else {
        pairError.textContent = "Pairing failed (" + response.status + ").";
      }
    } catch (e) {
      pairError.textContent = "Could not reach the Mac.";
    } finally {
      button.disabled = false;
    }
  }
  $("pair-submit").addEventListener("click", submitPIN);
  $("pair-pin").addEventListener("keydown", (e) => { if (e.key === "Enter") submitPIN(); });

  // ───────────────────────── connection ─────────────────────────

  const MAX_BACKOFF_ATTEMPT = 8;

  let ws = null;
  let reconnectTimer = null;
  let attempt = 0;
  let authed = false;

  const dot = $("dot");
  const statusEl = $("status");
  const statusText = $("status-text");
  const offlineScreen = $("offline-screen");
  const offlineDetail = $("offline-detail");

  function setConnected(ok, detail) {
    authed = ok;
    dot.className = "dot" + (ok ? " on" : "");
    statusEl.classList.toggle("live", ok);
    // The dot alone says "something is a colour"; the word says what.
    statusText.textContent = ok ? "Connected" : (detail || "Reconnecting…");
    if (ok) {
      offlineScreen.classList.add("hidden");
      return;
    }
    offlineDetail.textContent = detail || "Reconnecting…";
    // Only raise the overlay once a retry has actually failed; a brief blip
    // during normal reconnect shouldn't throw a wall up instantly.
    if (attempt > 0) offlineScreen.classList.remove("hidden");
  }

  async function discoverControlPort() {
    if (controlPort) return controlPort;
    try {
      const response = await fetch("/config.json", { cache: "no-store" });
      const config = await response.json();
      if (Number.isInteger(config.controlPort) && config.controlPort > 0) {
        controlPort = config.controlPort;
        // Without Accessibility the Mac accepts every command and drops every
        // event. Saying so beats looking connected while doing nothing.
        if (config.accessibility === false) {
          toast("The Mac hasn't granted Accessibility — input will do nothing.");
        }
        return controlPort;
      }
    } catch (e) { /* fall through to the default */ }
    controlPort = CONTROL_PORT_FALLBACK;
    return controlPort;
  }

  function closeSocket() {
    if (!ws) return;
    try {
      ws.onclose = null;          // a deliberate close must not trigger reconnect
      ws.close();
    } catch (e) {}
  }

  async function connect() {
    const token = storedToken();
    if (!token) { showPairScreen(); return; }

    const port = await discoverControlPort();

    clearTimeout(reconnectTimer);
    closeSocket();

    try {
      // Follow the page's scheme. A plaintext socket from an https page would
      // be blocked as mixed content anyway, and the Mac only accepts an Origin
      // matching how it served the page.
      const scheme = location.protocol === "https:" ? "wss://" : "ws://";
      ws = new WebSocket(scheme + location.hostname + ":" + port + "/");
    } catch (e) {
      scheduleReconnect();
      return;
    }

    ws.onopen = () => {
      // The token is sent explicitly as the first frame. It is never a cookie,
      // so no other origin's page can borrow it.
      raw({ t: "auth", token: token });
    };
    ws.onmessage = (event) => {
      let message;
      try { message = JSON.parse(event.data); } catch (e) { return; }
      handleServerMessage(message);
    };
    ws.onclose = () => {
      releaseHeldInput();
      setConnected(false);
      scheduleReconnect();
    };
    ws.onerror = () => { try { ws.close(); } catch (e) {} };
  }

  function handleServerMessage(message) {
    switch (message.t) {
      case "auth.required":
        break;                                   // answered in onopen
      case "welcome":
        attempt = 0;
        setConnected(true);
        send({ t: "deck.get" });
        break;
      case "auth.failed":
      case "auth.timeout":
        // The token is stale or was revoked on the Mac. Pair again.
        clearToken();
        setConnected(false, "This phone is no longer paired.");
        offlineScreen.classList.add("hidden");
        showPairScreen("This phone was unpaired. Enter the new PIN.");
        break;
      case "busy":
        setConnected(false, "Another phone is controlling this Mac.");
        offlineScreen.classList.remove("hidden");
        break;
      case "paused":
        setConnected(false, "Remote control is paused on the Mac.");
        offlineScreen.classList.remove("hidden");
        break;
      case "resumed":
        setConnected(true);
        break;
      case "deck":
        if (message.deck && message.deck.folders) Deck.adopt(message.deck);
        else Deck.seedMac();
        break;
      case "apps":
        Deck.setInstalledApps(message.apps);
        break;
      case "focus":
        onMacFocusChanged(message.text === true);
        break;
      case "error":
        if (message.reason) toast(message.reason);
        break;
    }
  }

  /// Capped exponential backoff with jitter, so a Mac that is asleep or off is
  /// not hammered by a phone left on a table.
  function scheduleReconnect() {
    clearTimeout(reconnectTimer);
    const delay = L.backoffDelay(attempt);
    attempt = Math.min(attempt + 1, MAX_BACKOFF_ATTEMPT);
    reconnectTimer = setTimeout(connect, delay);
  }

  $("offline-retry").addEventListener("click", () => { attempt = 0; connect(); });

  /// Send without the authenticated check — only the auth frame itself.
  function raw(object) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    object.v = PROTOCOL;
    ws.send(JSON.stringify(object));
  }

  function send(object) {
    if (!authed) return;
    raw(object);
  }

  // Release anything the Mac might think is held. Safe to call repeatedly.
  function releaseHeldInput() {
    if (leftHeld || rightHeld) {
      leftHeld = rightHeld = false;
      document.querySelectorAll(".padbtn.held").forEach((b) => b.classList.remove("held"));
    }
    dragging = false;
    if (activeMods.length) { activeMods = []; refreshModChips(); }
  }

  document.addEventListener("visibilitychange", () => {
    // Safari suspends sockets in the background; drop held state so nothing is
    // stuck down when we come back.
    if (!document.hidden) return;
    send({ t: "pointer.up" });
    releaseHeldInput();
  });

  // ────────────────────── view state machine ──────────────────────
  //
  //   landscape            -> keyboard  (unless overridden this session)
  //   portrait             -> last portrait view (default trackpad)
  //   header swipe / tabs  -> explicit choice
  //
  // Orientation is read with matchMedia, never by comparing window dimensions:
  // the software keyboard resizes the visual viewport, and treating that as a
  // rotation would make the view flap while typing.

  const switcher = $("switcher");
  const viewTitle = $("view-title");

  const landscapeMQ = window.matchMedia("(orientation: landscape)");
  const NAV_SWIPE_DISTANCE = 44;
  const NAV_SWIPE_DOMINANCE = 1.4;
  const VIEW_TITLES = { trackpad: "Trackpad", shortcuts: "Shortcuts", keyboard: "Keyboard" };

  let view = "trackpad";
  let lastPortraitView = "trackpad";
  let manualOverride = false;        // user chose a view that contradicts orientation

  function setView(next, explicit) {
    view = next;
    if (next !== "keyboard") lastPortraitView = next;
    if (explicit) manualOverride = (landscapeMQ.matches !== (next === "keyboard"));

    document.querySelectorAll(".view").forEach((section) => {
      section.classList.toggle("active", section.id === "view-" + next);
    });
    document.querySelectorAll("#switcher .tab").forEach((tab) => {
      tab.classList.toggle("active", tab.dataset.view === next);
    });
    // The sliding pill is positioned purely in CSS off this attribute, so the
    // animation survives without any per-frame work here.
    switcher.dataset.active = next;
    viewTitle.textContent = VIEW_TITLES[next] || next;

    // iOS will not raise the software keyboard from a focus() that no user
    // gesture led to — a WebKit restriction, not something to work around. The
    // textarea's placeholder tells the user to tap, which is the correct
    // minimum; focus is attempted anyway for the cases where it does work.
    if (next === "keyboard") kb.focus({ preventScroll: true });
    else kb.blur();

    if (next === "shortcuts") Deck.render();
  }

  function applyOrientation() {
    const next = L.viewForOrientation({
      landscape: landscapeMQ.matches,
      manualOverride: manualOverride,
      current: view,
      lastPortraitView: lastPortraitView,
    });
    if (next !== view) setView(next, false);
  }
  landscapeMQ.addEventListener("change", () => { manualOverride = false; applyOrientation(); });

  document.querySelectorAll("#switcher .tab").forEach((tab) => {
    tab.addEventListener("click", () => { buzz(); setView(tab.dataset.view, true); });
  });

  // Swiping the bottom bar also changes view. It is confined to the bar so the
  // trackpad's one-finger swipe stays pointer movement — stealing that would
  // make the pad unusable.
  (function wireNavSwipe() {
    let startX = null, startY = null;

    switcher.addEventListener("touchstart", (e) => {
      if (e.touches.length !== 1) { startX = null; return; }
      startX = e.touches[0].clientX;
      startY = e.touches[0].clientY;
    }, { passive: true });

    switcher.addEventListener("touchend", (e) => {
      if (startX === null) return;
      const touch = e.changedTouches[0];
      const dx = touch.clientX - startX, dy = touch.clientY - startY;
      startX = null;

      if (Math.abs(dx) < NAV_SWIPE_DISTANCE) return;
      if (Math.abs(dx) < Math.abs(dy) * NAV_SWIPE_DOMINANCE) return;

      const next = L.viewForSwipe(view, dx);
      if (next === view) return;
      buzz();
      setView(next, true);
    }, { passive: true });
  })();

  // ───────────────────── system action buttons ─────────────────────

  document.querySelectorAll("[data-action]").forEach((button) => {
    button.addEventListener("click", () => {
      buzz();
      send({ t: "system.action", action: button.dataset.action });
    });
  });

  // ─────────────────────── keyboard view ───────────────────────

  const kb = $("kb-input");
  /// How long the staging buffer may grow before it is emptied. Long enough to
  /// edit a sentence, short enough that the diff stays cheap.
  const MAX_BUFFER_LENGTH = 400;

  let activeMods = [];

  function refreshModChips() {
    document.querySelectorAll("#kb-mods .modchip").forEach((chip) => {
      chip.classList.toggle("on", activeMods.includes(chip.dataset.mod));
    });
    document.documentElement.classList.toggle("mods-held", activeMods.length > 0);

    const badge = $("mod-badge");
    if (badge) {
      badge.textContent = L.MOD_ORDER
        .filter((m) => activeMods.includes(m))
        .map((m) => L.MOD_SYMBOL[m])
        .join("");
    }
  }

  document.querySelectorAll("#kb-mods .modchip").forEach((chip) => {
    chip.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      const mod = chip.dataset.mod;
      activeMods = activeMods.includes(mod)
        ? activeMods.filter((m) => m !== mod)
        : activeMods.concat([mod]);
      refreshModChips();
    });
  });

  document.querySelectorAll("#kb-special .sp").forEach((button) => {
    button.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      sendKey(parseInt(button.dataset.key, 10));
    });
  });

  function sendKey(keyCode) {
    send({ t: "key.press", keyCode: keyCode, mods: activeMods.slice() });
  }

  /// Empty the staging buffer and resync the diff baseline.
  ///
  /// Both must move together: clearing the textarea without resetting
  /// `lastValue` would make the next diff think the user deleted everything and
  /// emit a backspace per character.
  function clearBuffer() {
    kb.value = "";
    lastValue = "";
  }

  $("kb-clear").addEventListener("click", () => { clearBuffer(); kb.focus(); });

  // iOS gives no way out of a focused textarea on its own, so the software
  // keyboard would cover the modifier and arrow rows with no way back.
  $("kb-hide").addEventListener("click", () => { kb.blur(); });

  // Tapping the empty area of the keyboard view also dismisses it — the
  // ordinary expectation on iOS, and a much larger target than the button.
  $("view-keyboard").addEventListener("click", (e) => {
    if (e.target === $("view-keyboard")) kb.blur();
  });

  // Swipe down to dismiss, which is what iOS trains people to expect.
  //
  // Only from the top of the textarea's own scroll, so a genuine scroll through
  // a long buffer is never mistaken for a dismissal.
  (function wireSwipeToDismiss() {
    const DISMISS_DISTANCE = 45;
    let startY = null, startScroll = 0;

    function begin(e) {
      if (e.touches.length !== 1) { startY = null; return; }
      startY = e.touches[0].clientY;
      startScroll = kb.scrollTop;
    }
    function end(e) {
      if (startY === null) return;
      const dy = e.changedTouches[0].clientY - startY;
      startY = null;
      if (dy > DISMISS_DISTANCE && startScroll <= 0) kb.blur();
    }

    for (const target of [kb, $("view-keyboard"), $("kb-special"), $("kb-mods")]) {
      target.addEventListener("touchstart", begin, { passive: true });
      target.addEventListener("touchend", end, { passive: true });
    }
  })();

  // ── text reconciliation, by grapheme ──
  //
  // The textarea is a staging buffer; we diff it against what we last sent and
  // emit the difference. The unit of comparison is the **grapheme cluster**, not
  // the UTF-16 code unit — an emoji is one grapheme but two or more code units,
  // so a code-unit diff emits two backspaces to delete one emoji and destroys
  // the character before it.

  let lastValue = "";
  let composing = false;

  function flushDiff() {
    const delta = L.textDelta(lastValue, kb.value);

    // With a modifier held, a typed character means a shortcut, not text.
    if (activeMods.length > 0 && delta.backspaces === 0 && delta.insert) {
      for (const ch of L.graphemes(delta.insert)) {
        const code = L.keyCodeForChar(ch);
        if (code !== null) sendKey(code);
        else send({ t: "text.insert", text: ch });
      }
      kb.value = lastValue;              // don't keep shortcut chars in the buffer
      return;
    }

    for (let i = 0; i < delta.backspaces; i++) {
      send({ t: "key.press", keyCode: L.KEY_CODE_BACKSPACE, mods: [] });
    }

    if (delta.insert) {
      // A newline must be an Enter keypress, not an inserted \n character.
      // Typing "\n" into Terminal or a search field does nothing; the app is
      // waiting for the Return key, which is a different event entirely.
      const lines = delta.insert.split("\n");
      lines.forEach((line, index) => {
        if (index > 0) sendKey(L.KEY_CODE_RETURN);
        if (!line) return;
        for (const chunk of L.chunkByGrapheme(line, TEXT_CHUNK_UTF16)) {
          send({ t: "text.insert", text: chunk });
        }
      });
      if (lines.length > 1) { clearBuffer(); return; }   // a Return went through
    }

    lastValue = kb.value;

    // Never truncate mid-composition, or the IME state desyncs.
    if (kb.value.length > MAX_BUFFER_LENGTH && !composing) clearBuffer();
  }

  /// Return from the keyboard: press Return on the Mac, then empty the box.
  ///
  /// The line has been committed to the Mac, so leaving it on screen is just
  /// clutter — and it makes the next line read as a continuation of something
  /// already sent.
  function sendReturn() {
    sendKey(L.KEY_CODE_RETURN);
    clearBuffer();
  }

  // Return on the phone's keyboard means "press Return on the Mac", so it must
  // never land in the staging buffer as a line break.
  //
  // Two listeners because the software and hardware keyboards report it
  // differently: iOS raises beforeinput with inputType "insertLineBreak" and
  // may not fire a useful keydown at all, while a paired hardware keyboard
  // fires keydown. Whichever arrives first wins; the other sees an unchanged
  // value and does nothing.
  kb.addEventListener("beforeinput", (e) => {
    if (e.inputType !== "insertLineBreak" && e.inputType !== "insertParagraph") return;
    e.preventDefault();
    sendReturn();
  });
  kb.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" || e.isComposing || composing) return;
    e.preventDefault();
    sendReturn();
  });

  kb.addEventListener("compositionstart", () => { composing = true; });
  kb.addEventListener("compositionend", () => { composing = false; flushDiff(); });
  kb.addEventListener("input", (e) => {
    if (e.isComposing || composing) return;
    flushDiff();
  });

  /// The Mac reports that something typable gained or lost focus.
  ///
  /// Only ever switches *to* the keyboard — never away — so this cannot yank a
  /// view out from under you while you are working.
  function onMacFocusChanged(isText) {
    const should = L.shouldAutoShowKeyboard({
      isTextFocused: isText,
      enabled: settings.autoKeyboard !== false,
      view: view,
      dragging: dragging,
      buttonHeld: leftHeld || rightHeld,
    });
    if (!should) return;

    setView("keyboard", false);

    // iOS will not raise the software keyboard from a focus() that is not tied
    // to a user gesture. If the Mac's focus change was caused by a tap on the
    // trackpad a moment ago we may still be inside Safari's transient
    // activation window, and the focus will be honoured. If not, the
    // placeholder is the fallback.
    if (L.canRaiseKeyboard(now() - lastGestureAt)) {
      kb.focus({ preventScroll: true });
    }
  }

  // ───────────────────────── trackpad ─────────────────────────

  const pad = $("trackpad");
  const padGlow = $("pad-glow");

  /// Move the glow under the finger.
  ///
  /// Transform only, so this is a compositor job rather than a repaint of the
  /// whole pad — it runs on every touchmove and must cost nothing.
  function moveGlow(touch) {
    const box = pad.getBoundingClientRect();
    padGlow.style.transform =
      "translate3d(" + (touch.clientX - box.left) + "px," + (touch.clientY - box.top) + "px,0)";
  }
  function showGlow(on) { pad.classList.toggle("touching", on); }

  const TAP_MS = 250;              // longer than this is a press, not a tap
  const TAP_MOVE = 8;              // CSS px of slop allowed in a tap
  const DOUBLE_MS = 300;           // window for a second tap to count as double
  const SWIPE_DISTANCE = 70;       // CSS px before a multi-finger swipe fires
  const PINCH_DECIDE = 12;         // CSS px before two fingers commit to scroll or pinch
  const ZOOM_STEP = 0.12;          // spread ratio change that emits one zoom step
  const SCROLL_FRICTION = 0.94;    // per-frame momentum decay
  const MOMENTUM_MIN = 0.02;       // velocity below which momentum stops
  const MOMENTUM_HANDOFF_MS = 120; // lift must follow movement this closely to coast
  const SCROLL_HZ = 60;
  const MAX_FRAME_MS = 32;         // clamp dt so a backgrounded tab cannot fling
  const VELOCITY_SMOOTHING = 0.6;  // weight on the previous velocity estimate

  // Safari grants a few seconds of "transient activation" after a real touch.
  // A focus() outside that window will not raise the software keyboard, so the
  // auto-keyboard only attempts it when a tap has just happened.
  let lastGestureAt = 0;

  let leftHeld = false, rightHeld = false;
  const buttonHeld = () => leftHeld || rightHeld;

  // ── pointer and scroll coalescing ──
  //
  // touchmove can fire far faster than the Mac needs. Accumulate deltas and
  // flush on a timer, so the rate is bounded by choice rather than by hardware.

  let pendingX = 0, pendingY = 0, moveTimer = null;

  function queueMove(dx, dy) {
    pendingX += dx;
    pendingY += dy;
    if (moveTimer) return;
    const interval = 1000 / clamp(settings.pointerHz, MIN_POINTER_HZ, MAX_POINTER_HZ);
    moveTimer = setTimeout(flushMove, interval);
  }

  function flushMove() {
    moveTimer = null;
    if (pendingX === 0 && pendingY === 0) return;
    const dx = clamp(pendingX, -MAX_POINTER_DELTA, MAX_POINTER_DELTA);
    const dy = clamp(pendingY, -MAX_POINTER_DELTA, MAX_POINTER_DELTA);
    pendingX = 0;
    pendingY = 0;
    // Two decimals: the Mac interpolates sub-pixel, and more digits is just
    // bytes on the wire.
    send({ t: "pointer.move", dx: round2(dx), dy: round2(dy) });
  }

  let pendingScrollX = 0, pendingScrollY = 0, scrollTimer = null;

  function queueScroll(dx, dy) {
    pendingScrollX += dx;
    pendingScrollY += dy;
    if (scrollTimer) return;
    scrollTimer = setTimeout(flushScroll, 1000 / SCROLL_HZ);
  }

  function flushScroll() {
    scrollTimer = null;
    const dx = Math.round(clamp(pendingScrollX, -MAX_SCROLL_DELTA, MAX_SCROLL_DELTA));
    const dy = Math.round(clamp(pendingScrollY, -MAX_SCROLL_DELTA, MAX_SCROLL_DELTA));
    pendingScrollX = 0;
    pendingScrollY = 0;
    if (dx || dy) send({ t: "pointer.scroll", dx: dx, dy: dy });
  }

  const round2 = (n) => Math.round(n * 100) / 100;
  const scrollScale = () => settings.scrollSpeed * settings.scrollDir;

  // ── gesture recognizer ──
  //
  // The highest finger count seen during a gesture locks its class, and a
  // multi-finger action fires at most once per gesture. Classifying on the
  // instantaneous count would fire the three-finger action during a four-finger
  // swipe, because fingers never land at the same moment.

  let gesture = null;              // "pointer" | "scroll" | "pinch" | "swipe"
  let maxTouches = 0;
  let swipeFired = false, swipeStart = null, swipeLast = null;
  let startTime = 0, moved = false, dragging = false, armedForDrag = false;
  let lastPoint = null, lastCentroid = null;
  let pinchStartSpread = 0, pinchLastSpread = 0, pinchStartCentroid = null;
  let scrollVX = 0, scrollVY = 0, lastScrollAt = 0, momentumFrame = null;
  let clickCount = 0, lastClickAt = 0, lastTapEndAt = 0;

  function centroid(touches) {
    let x = 0, y = 0;
    for (const touch of touches) { x += touch.clientX; y += touch.clientY; }
    return { x: x / touches.length, y: y / touches.length };
  }

  function spread(touches) {
    return Math.hypot(touches[0].clientX - touches[1].clientX,
                      touches[0].clientY - touches[1].clientY);
  }

  function stopMomentum() {
    if (momentumFrame) { cancelAnimationFrame(momentumFrame); momentumFrame = null; }
    scrollVX = scrollVY = 0;
  }

  function startMomentum() {
    if (Math.hypot(scrollVX, scrollVY) < MOMENTUM_MIN) return;
    let previous = now();
    const step = (timestamp) => {
      const dt = Math.min(timestamp - previous, MAX_FRAME_MS);
      previous = timestamp;
      scrollVX *= SCROLL_FRICTION;
      scrollVY *= SCROLL_FRICTION;
      if (Math.hypot(scrollVX, scrollVY) < MOMENTUM_MIN) { momentumFrame = null; return; }
      queueScroll(scrollVX * dt * scrollScale(), scrollVY * dt * scrollScale());
      momentumFrame = requestAnimationFrame(step);
    };
    momentumFrame = requestAnimationFrame(step);
  }

  function resetGesture() {
    gesture = null;
    maxTouches = 0;
    swipeFired = false;
    swipeStart = swipeLast = null;
    lastPoint = lastCentroid = null;
    moved = false;
    armedForDrag = false;
    pinchStartCentroid = null;
  }

  function fireSwipeIfReady() {
    if (swipeFired || !swipeStart || !swipeLast) return;
    const dx = swipeLast.x - swipeStart.x, dy = swipeLast.y - swipeStart.y;
    // Direction dominance is enforced inside swipeDirection: a diagonal smudge
    // returns null rather than firing an arbitrary axis.
    const dir = L.swipeDirection(dx, dy, SWIPE_DISTANCE);
    if (!dir) return;

    flushMove();
    send({ t: "swipe", dir: dir, fingers: Math.min(maxTouches, 4) });
    swipeFired = true;
    buzz();
  }

  pad.addEventListener("touchstart", (e) => {
    e.preventDefault();
    stopMomentum();
    moveGlow(e.touches[0]);
    showGlow(true);
    const count = e.touches.length;
    maxTouches = Math.max(maxTouches, count);

    if (count === 1 && gesture === null) {
      gesture = "pointer";
      startTime = now();
      moved = false;
      dragging = false;
      lastPoint = { x: e.touches[0].clientX, y: e.touches[0].clientY };
      // Tap-then-drag: a second touch arriving quickly means "hold the button".
      armedForDrag = !buttonHeld() && (now() - lastTapEndAt) < DOUBLE_MS;
    } else if (count === 2) {
      // Two fingers: decide scroll vs pinch on first movement.
      gesture = "scroll";
      pinchStartSpread = spread(e.touches);
      pinchLastSpread = pinchStartSpread;
      pinchStartCentroid = centroid(e.touches);
      armedForDrag = false;
    } else if (count >= 3) {
      gesture = "swipe";
      swipeStart = centroid(e.touches);
      swipeLast = swipeStart;
      armedForDrag = false;
    }
    lastCentroid = centroid(e.touches);
  }, { passive: false });

  pad.addEventListener("touchmove", (e) => {
    e.preventDefault();
    moveGlow(e.touches[0]);
    const count = e.touches.length;
    maxTouches = Math.max(maxTouches, count);

    if (gesture === "swipe") {
      // A 3-finger gesture that grows to 4 before firing is re-read as 4-finger.
      if (count >= 3) { swipeLast = centroid(e.touches); fireSwipeIfReady(); }
      moved = true;
      return;
    }

    if (count === 2 && (gesture === "scroll" || gesture === "pinch")) {
      trackTwoFingers(e.touches);
      moved = true;
      return;
    }

    if (count === 1 && gesture === "pointer" && lastPoint) {
      trackOneFinger(e.touches[0]);
    }
  }, { passive: false });

  function trackTwoFingers(touches) {
    const current = centroid(touches);
    const currentSpread = spread(touches);

    // Commit to pinch only when the spread is changing more than the pair is
    // translating; otherwise a two-finger scroll with slightly drifting fingers
    // would read as a zoom.
    if (gesture === "scroll" && pinchStartCentroid) {
      const spreadChange = Math.abs(currentSpread - pinchStartSpread);
      const translation = Math.hypot(current.x - pinchStartCentroid.x,
                                     current.y - pinchStartCentroid.y);
      if (Math.max(spreadChange, translation) > PINCH_DECIDE && spreadChange > translation) {
        gesture = "pinch";
        pinchLastSpread = currentSpread;
      }
    }

    if (gesture === "pinch") {
      const ratio = currentSpread / pinchLastSpread;
      if (ratio > 1 + ZOOM_STEP) {
        send({ t: "system.action", action: "zoom_in" });
        pinchLastSpread = currentSpread;
      } else if (ratio < 1 - ZOOM_STEP) {
        send({ t: "system.action", action: "zoom_out" });
        pinchLastSpread = currentSpread;
      }
    } else if (lastCentroid) {
      const dx = current.x - lastCentroid.x, dy = current.y - lastCentroid.y;
      const timestamp = now();
      const dt = Math.max(timestamp - lastScrollAt, 1);
      scrollVX = VELOCITY_SMOOTHING * scrollVX + (1 - VELOCITY_SMOOTHING) * (dx / dt);
      scrollVY = VELOCITY_SMOOTHING * scrollVY + (1 - VELOCITY_SMOOTHING) * (dy / dt);
      lastScrollAt = timestamp;
      if (Math.abs(dx) > 0.1 || Math.abs(dy) > 0.1) {
        queueScroll(dx * scrollScale(), dy * scrollScale());
      }
    }

    lastCentroid = current;
  }

  function trackOneFinger(touch) {
    const x = touch.clientX, y = touch.clientY;
    const dx = x - lastPoint.x, dy = y - lastPoint.y;
    if (Math.abs(dx) > TAP_MOVE || Math.abs(dy) > TAP_MOVE) moved = true;

    if (armedForDrag && !dragging && moved) {
      dragging = true;
      send({ t: "pointer.down", button: "left", mods: activeMods.slice() });
    }

    if (dx !== 0 || dy !== 0) {
      if (dragging) {
        // No acceleration while dragging: a drag is a positioning task, and
        // acceleration makes it hard to land on a target.
        queueMove(dx * settings.moveSpeed, dy * settings.moveSpeed);
      } else {
        const speed = Math.hypot(dx, dy);
        const factor = settings.moveSpeed * (1 + Math.min(speed, 40) * settings.accel);
        queueMove(dx * factor, dy * factor);
      }
    }
    lastPoint = { x: x, y: y };
  }

  pad.addEventListener("touchend", (e) => {
    e.preventDefault();
    lastGestureAt = now();
    if (e.touches.length === 0) showGlow(false);

    if (gesture === "swipe") {
      fireSwipeIfReady();
      if (e.touches.length === 0) resetGesture();
      return;
    }

    if (e.touches.length > 0) {
      // Fingers still down — keep tracking, but don't finish the gesture.
      if (e.touches.length === 1) {
        lastPoint = { x: e.touches[0].clientX, y: e.touches[0].clientY };
      }
      lastCentroid = centroid(e.touches);
      return;
    }

    if (dragging) {
      flushMove();
      send({ t: "pointer.up" });
      dragging = false;
    } else if (isTap()) {
      sendTapClick();
    } else if (moved && gesture === "scroll" && (now() - lastScrollAt) < MOMENTUM_HANDOFF_MS) {
      startMomentum();
    }
    resetGesture();
  }, { passive: false });

  function isTap() {
    return gesture === "pointer" && !moved && (now() - startTime) < TAP_MS && !buttonHeld();
  }

  function sendTapClick() {
    // Two fingers resting during a tap is the standard right-click gesture.
    if (maxTouches >= 2) {
      send({ t: "pointer.click", button: "right", count: 1, mods: activeMods.slice() });
      clickCount = 0;
      lastClickAt = 0;
      lastTapEndAt = now();
      return;
    }
    const timestamp = now();
    clickCount = (timestamp - lastClickAt < DOUBLE_MS) ? Math.min(clickCount + 1, 3) : 1;
    lastClickAt = timestamp;
    send({ t: "pointer.click", button: "left", count: clickCount, mods: activeMods.slice() });
    lastTapEndAt = now();
  }

  pad.addEventListener("touchcancel", () => {
    showGlow(false);
    if (gesture === "swipe") fireSwipeIfReady();
    if (dragging) {
      flushMove();
      send({ t: "pointer.up" });
      dragging = false;
    }
    resetGesture();
  }, { passive: false });

  // Held click buttons: press and hold one, then drag on the pad, for a real
  // drag-select without needing a double-tap-and-drag.
  function wireClickButton(button, which) {
    button.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      // Capture the pointer so sliding off the button still delivers its
      // release here, rather than leaving the Mac's button stuck down.
      try { button.setPointerCapture(e.pointerId); } catch (err) {}
      if (which === "left") leftHeld = true;
      else rightHeld = true;
      button.classList.add("held");
      send({ t: "pointer.down", button: which, mods: activeMods.slice() });
    });

    const release = () => {
      if (which === "left") {
        if (!leftHeld) return;
        leftHeld = false;
      } else {
        if (!rightHeld) return;
        rightHeld = false;
      }
      button.classList.remove("held");
      send({ t: "pointer.up" });
    };
    button.addEventListener("pointerup", release);
    button.addEventListener("pointercancel", release);
  }
  wireClickButton($("click-left"), "left");
  wireClickButton($("click-right"), "right");

  // Block page zoom and overscroll; iOS Safari ignores the viewport meta for
  // these, so they have to be cancelled per event.
  ["gesturestart", "gesturechange", "gestureend"].forEach((name) => {
    document.addEventListener(name, (e) => e.preventDefault(), { passive: false });
  });
  document.addEventListener("touchmove", (e) => {
    if (e.touches.length > 1 && !e.target.closest("#trackpad")) e.preventDefault();
  }, { passive: false });

  // ───────────────────────── settings sheet ─────────────────────────

  $("settings-btn").addEventListener("click", openSettings);

  function openSettings() {
    const modalRoot = $("modal-root");
    const close = () => { modalRoot.innerHTML = ""; };

    modalRoot.innerHTML =
      '<div class="modal-bg"></div><div class="modal-card">' +
      '<div class="modal-head"><div class="modal-title">Settings</div>' +
        '<button id="st-close" class="modal-x" aria-label="Close">✕</button></div>' +
      '<div id="st-body"></div>' +
      '<div class="modal-actions"><button id="st-unpair" class="danger">Unpair this phone</button>' +
        '<span class="spacer"></span><button id="st-done" class="primary">Done</button></div>' +
      "</div>";

    modalRoot.querySelector(".modal-bg").addEventListener("click", close);
    modalRoot.querySelector("#st-close").addEventListener("click", close);
    modalRoot.querySelector("#st-done").addEventListener("click", close);
    modalRoot.querySelector("#st-unpair").addEventListener("click", () => {
      clearToken();
      close();
      closeSocket();
      setConnected(false);
      offlineScreen.classList.add("hidden");
      showPairScreen("Unpaired. Enter the PIN from the Mac to reconnect.");
    });

    const body = modalRoot.querySelector("#st-body");
    addSlider(body, "moveSpeed", "Pointer speed", 0.4, 3, 0.1, (v) => v.toFixed(1) + "×");
    addSlider(body, "accel", "Acceleration", 0, 0.2, 0.01, (v) => v.toFixed(2));
    addSlider(body, "scrollSpeed", "Scroll speed", 0.3, 3, 0.1, (v) => v.toFixed(1) + "×");
    addSlider(body, "pointerHz", "Update rate",
              MIN_POINTER_HZ, MAX_POINTER_HZ, 10, (v) => v + " Hz");

    addCheckbox(body, "Invert scroll direction",
                () => settings.scrollDir === -1,
                (on) => { settings.scrollDir = on ? -1 : 1; });
    addCheckbox(body, "Show keyboard when a Mac text field is focused",
                () => settings.autoKeyboard !== false,
                (on) => { settings.autoKeyboard = on; });

    addThemePicker(body);
  }

  function addSlider(body, key, label, min, max, step, format) {
    const row = document.createElement("div");
    row.className = "st-row";
    row.innerHTML = '<div class="st-label">' + label + ' <span class="st-val"></span></div>';

    const input = document.createElement("input");
    input.type = "range";
    input.min = min;
    input.max = max;
    input.step = step;
    input.value = settings[key];

    const readout = row.querySelector(".st-val");
    readout.textContent = format(settings[key]);

    input.addEventListener("input", () => {
      settings[key] = parseFloat(input.value);
      readout.textContent = format(settings[key]);
      saveSettings();
    });

    row.appendChild(input);
    body.appendChild(row);
  }

  function addCheckbox(body, label, isOn, apply) {
    const row = document.createElement("div");
    row.className = "st-row";

    const wrap = document.createElement("label");
    wrap.className = "st-check";
    const input = document.createElement("input");
    input.type = "checkbox";
    input.checked = isOn();
    wrap.appendChild(input);
    wrap.appendChild(document.createTextNode(" " + label));

    input.addEventListener("change", () => { apply(input.checked); saveSettings(); });

    row.appendChild(wrap);
    body.appendChild(row);
  }

  function addThemePicker(body) {
    const row = document.createElement("div");
    row.className = "st-row";
    row.innerHTML = '<div class="st-label">Theme</div><div class="seg" id="st-theme">'
      + '<button data-t="dark">Dark</button><button data-t="light">Light</button>'
      + '<button data-t="system">System</button></div>';
    body.appendChild(row);

    const buttons = row.querySelectorAll("#st-theme button");
    buttons.forEach((button) => {
      button.classList.toggle("on", settings.theme === button.dataset.t);
      button.addEventListener("click", () => {
        settings.theme = button.dataset.t;
        saveSettings();
        applyTheme();
        buttons.forEach((b) => b.classList.toggle("on", b === button));
      });
    });
  }

  // ─────────────────────────── start ───────────────────────────

  Deck.init({ send: send, toast: toast, buzz: buzz });
  if (!storedToken()) showPairScreen();
  setView(landscapeMQ.matches ? "keyboard" : "trackpad", false);
  connect();
})();

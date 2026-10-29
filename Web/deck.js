// The shortcut deck and its button editor.
//
// Split out of app.js because it is a self-contained feature: it owns the deck
// state, its own storage, the paged grid, drag-to-reorder, and the editor
// sheet. It talks to the rest of the app through the four functions passed to
// `init`, and nothing else — no shared globals, no reaching into app.js.
//
// Note what crosses the wire when a button is pressed: only its **id**. The Mac
// resolves that against its own validated copy of the deck, so a target string
// from this file is never trusted at run time.

(function (root) {
  "use strict";

  const L = root.RemoteMacLogic;
  const $ = (id) => document.getElementById(id);

  // Server-side limits, mirrored here so the UI can refuse politely instead of
  // letting the Mac reject the write. The Mac enforces them regardless; these
  // are for the error message, not for safety. Keep in step with Limits in
  // Sources/Protocol.swift.
  const MAX_FOLDERS = 12;
  const MAX_ITEMS_PER_FOLDER = 60;
  const MAX_LABEL_LENGTH = 32;
  const MAX_FOLDER_NAME_LENGTH = 24;
  const MAX_TEXT_LENGTH = 256;

  const STORAGE_KEY = "remotemac.deck.v1";
  const ITEMS_PER_PAGE = 9;
  /// How long a press must be held before a button lifts for reordering. Short
  /// enough to feel responsive, long enough that a tap is never a drag.
  const DRAG_HOLD_MS = 220;
  /// Hold this long outside edit mode to open a button's editor. Longer than
  /// the drag hold, because here it competes with an ordinary tap that runs the
  /// shortcut, and running something by accident is the worse outcome.
  const EDIT_HOLD_MS = 500;
  const DRAG_CANCEL_DISTANCE = 10;
  const MAX_APPS_LISTED = 40;

  /// Background swatches offered in the editor. Only hex values survive
  /// server-side validation, so none of these can carry a `url()`.
  const COLORS = ["", "#2a2520", "#1f2a24", "#202a33", "#2b2230", "#33281f"];
  const HEX_COLOR = /^#[0-9a-fA-F]{3,8}$/;
  const PNG_DATA_URI = "data:image/png;base64,";

  // Injected by app.js.
  let send = () => {};
  let toast = () => {};
  let buzz = () => {};

  let deck = null;
  let activeFolder = 0;
  let editMode = false;
  let installedApps = [];
  let refreshAppPicker = null;

  let pagesEl, dotsEl, tabsEl, toolbarEl, modalRoot, hintEl;

  function uid() { return "x" + Math.random().toString(36).slice(2, 9); }

  // ───────────────────────── storage ─────────────────────────

  function loadLocal() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (parsed && parsed.folders) return parsed;
      }
    } catch (e) { /* private browsing, or corrupt — fall back to defaults */ }
    return null;
  }

  function saveLocal() {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(deck)); } catch (e) {}
  }

  /// Persist locally and push to the Mac. The Mac's copy is authoritative for
  /// *running* a button, so a save that only lands here would show buttons that
  /// do nothing.
  function persist() {
    saveLocal();
    pushToMac();
  }

  function pushToMac() { send({ t: "deck.save", deck: JSON.stringify(deck) }); }

  function shortcut(label, keyCode, mods) {
    return { id: uid(), type: "shortcut", label: label, keyCode: keyCode, mods: mods };
  }

  function link(label, target, icon) {
    return { id: uid(), type: "launch", label: label, target: target, icon: icon };
  }

  function defaultDeck() {
    return { folders: [
      { id: uid(), name: "Basics", items: [
        shortcut("Copy", 8, ["command"]),
        shortcut("Paste", 9, ["command"]),
        shortcut("Cut", 7, ["command"]),
        shortcut("Undo", 6, ["command"]),
        shortcut("Redo", 6, ["command", "shift"]),
        shortcut("Select all", 0, ["command"]),
        shortcut("Save", 1, ["command"]),
        shortcut("Find", 3, ["command"]),
        shortcut("Reload", 15, ["command"]),
      ] },
      { id: uid(), name: "Web", items: [
        link("YouTube", "https://www.youtube.com/", "▶"),
        link("Gmail", "https://mail.google.com/", "✉"),
        shortcut("New tab", 17, ["command"]),
        shortcut("Close tab", 13, ["command"]),
      ] },
      { id: uid(), name: "Apps/Windows", items: [
        shortcut("Spotlight", 49, ["command"]),
        shortcut("Switch app", 48, ["command"]),
      ] },
      { id: uid(), name: "Mine", items: [] },
    ] };
  }

  // ───────────────────────── rendering ─────────────────────────

  function render() {
    renderFolderTabs();
    renderToolbar();
    renderPages();
    // The two modes answer the same tap differently, so say which is live.
    hintEl.textContent = editMode
      ? "Tap to edit · hold to reorder"
      : "Tap to run · hold to edit";
  }

  function renderFolderTabs() {
    if (activeFolder >= deck.folders.length) activeFolder = 0;
    tabsEl.innerHTML = "";
    deck.folders.forEach((folder, index) => {
      const tab = document.createElement("button");
      tab.className = "folder-tab" + (index === activeFolder ? " active" : "");
      tab.textContent = folder.name;
      tab.addEventListener("click", () => { activeFolder = index; render(); });
      tabsEl.appendChild(tab);
    });
    if (!editMode) return;

    const add = document.createElement("button");
    add.className = "folder-tab add";
    add.textContent = "＋";
    add.addEventListener("click", () => {
      if (deck.folders.length >= MAX_FOLDERS) { toast("Folder limit reached."); return; }
      const name = prompt("Folder name", "New");
      if (!name) return;
      deck.folders.push({
        id: uid(), name: name.slice(0, MAX_FOLDER_NAME_LENGTH), items: [],
      });
      activeFolder = deck.folders.length - 1;
      persist(); render();
    });
    tabsEl.appendChild(add);
  }

  function renderToolbar() {
    toolbarEl.innerHTML = "";
    if (!editMode) return;

    const rename = document.createElement("button");
    rename.textContent = "✎ Rename folder";
    rename.addEventListener("click", () => {
      const folder = deck.folders[activeFolder];
      const name = prompt("Folder name", folder.name);
      if (!name) return;
      folder.name = name.slice(0, MAX_FOLDER_NAME_LENGTH);
      persist(); render();
    });

    const remove = document.createElement("button");
    remove.className = "danger";
    remove.textContent = "🗑 Delete folder";
    remove.addEventListener("click", () => {
      if (deck.folders.length <= 1) { toast("At least one folder is required."); return; }
      if (!confirm("Delete this folder and its buttons?")) return;
      deck.folders.splice(activeFolder, 1);
      activeFolder = 0;
      persist(); render();
    });

    toolbarEl.appendChild(rename);
    toolbarEl.appendChild(remove);
  }

  function renderPages() {
    // Re-rendering resets scrollLeft, which would snap the user back to page 1
    // mid-drag. Restore it.
    const keepScroll = pagesEl.scrollLeft;
    pagesEl.innerHTML = "";

    const folder = deck.folders[activeFolder];
    const cells = (folder ? folder.items : []).map(renderCell);
    if (editMode) cells.push(renderAddCell());

    const pages = [];
    for (let i = 0; i < cells.length; i += ITEMS_PER_PAGE) {
      pages.push(cells.slice(i, i + ITEMS_PER_PAGE));
    }
    if (pages.length === 0) pages.push([]);

    pages.forEach((cellsOnPage, pageIndex) => {
      const page = document.createElement("div");
      page.className = "deck-page";
      cellsOnPage.forEach((cell, slot) => {
        // The grid index must be absolute, not per-page, or reordering onto
        // page 2 would move the wrong item.
        cell.dataset.idx = pageIndex * ITEMS_PER_PAGE + slot;
        page.appendChild(cell);
      });
      pagesEl.appendChild(page);
    });

    pagesEl.scrollLeft = keepScroll;
    renderDots(pages.length);
  }

  function subtitle(item) {
    if (item.type === "shortcut") return L.comboLabel(item.keyCode, item.mods);
    if (item.type === "text") return "Text";
    if (item.type === "launch") return isAppPath(item.target) ? "App" : "Link";
    return "";
  }

  function renderCell(item) {
    const button = document.createElement("button");
    button.className = "deck-btn";
    if (item.color && HEX_COLOR.test(item.color)) button.style.background = item.color;
    if (dragState && dragState.item === item) button.classList.add("drag-src");

    if (item.icon) button.appendChild(renderIcon(item.icon));

    const label = document.createElement("span");
    label.textContent = item.label || "(unnamed)";
    button.appendChild(label);

    const sub = subtitle(item);
    if (sub) {
      const subEl = document.createElement("span");
      subEl.className = "sub";
      subEl.textContent = sub;
      button.appendChild(subEl);
    }

    if (editMode) {
      button.addEventListener("touchstart", (e) => armDrag(e, item, button), { passive: true });
    } else {
      // Tap runs it, hold edits it. Deciding by gesture means you never have to
      // flip a global mode first and then guess what a tap will do.
      wireHoldToEdit(button, item);
      button.addEventListener("click", () => {
        if (takeSuppressedClick(button)) return;
        send({ t: "shortcut.run", id: item.id });
        buzz();
      });
    }
    return button;
  }

  // ── hold a button to edit it (outside edit mode) ──

  let holdTimer = null, holdTarget = null, suppressClickFor = null;

  function wireHoldToEdit(button, item) {
    button.addEventListener("touchstart", (e) => {
      const touch = e.touches[0];
      cancelHold();
      holdTarget = { button: button, x: touch.clientX, y: touch.clientY };
      button.classList.add("holding");
      holdTimer = setTimeout(() => {
        if (!holdTarget || holdTarget.button !== button) return;
        cancelHold();
        // The touch still produces a click afterwards; it must not also run
        // the shortcut we just opened for editing.
        suppressClickFor = button;
        buzz();
        openEditor(item);
      }, EDIT_HOLD_MS);
    }, { passive: true });

    // Moving means a page swipe, not a hold.
    button.addEventListener("touchmove", (e) => {
      if (!holdTarget) return;
      const touch = e.touches[0];
      const travelled = Math.hypot(touch.clientX - holdTarget.x, touch.clientY - holdTarget.y);
      if (travelled > DRAG_CANCEL_DISTANCE) cancelHold();
    }, { passive: true });

    button.addEventListener("touchend", cancelHold, { passive: true });
    button.addEventListener("touchcancel", cancelHold, { passive: true });
  }

  function cancelHold() {
    if (holdTimer) { clearTimeout(holdTimer); holdTimer = null; }
    if (holdTarget) holdTarget.button.classList.remove("holding");
    holdTarget = null;
  }

  /// True once, for the click that follows a completed hold.
  function takeSuppressedClick(button) {
    if (suppressClickFor !== button) return false;
    suppressClickFor = null;
    return true;
  }

  /// An icon is either a base64 PNG (an app icon picked from the Mac) or a
  /// short glyph. Both forms are validated server-side before they are stored;
  /// an `<img src>` built from anything else could make an outbound request.
  function renderIcon(icon) {
    if (icon.startsWith(PNG_DATA_URI)) {
      const img = document.createElement("img");
      img.className = "ic-img";
      img.src = icon;
      img.alt = "";
      return img;
    }
    const span = document.createElement("span");
    span.className = "ic";
    span.textContent = icon;
    return span;
  }

  function renderAddCell() {
    const button = document.createElement("button");
    button.className = "deck-btn add";
    button.textContent = "＋";
    button.addEventListener("click", () => openEditor(null));
    return button;
  }

  function renderDots(count) {
    dotsEl.innerHTML = "";
    if (count <= 1) return;
    for (let i = 0; i < count; i++) {
      const dot = document.createElement("span");
      dot.className = "pd" + (i === 0 ? " on" : "");
      dotsEl.appendChild(dot);
    }
  }

  // ─────────────────── drag to reorder (edit mode) ───────────────────

  let dragCandidate = null, dragState = null, dragTimer = null;

  function armDrag(e, item, button) {
    const touch = e.touches[0];
    dragCandidate = { item: item, button: button, x: touch.clientX, y: touch.clientY, armed: false };
    dragTimer = setTimeout(() => {
      if (!dragCandidate) return;
      dragCandidate.armed = true;
      button.classList.add("lift");
    }, DRAG_HOLD_MS);
  }

  function clearCandidate() {
    if (dragTimer) { clearTimeout(dragTimer); dragTimer = null; }
    if (dragCandidate) dragCandidate.button.classList.remove("lift");
    dragCandidate = null;
  }

  function beginDrag(touch) {
    const { button, item } = dragCandidate;
    clearTimeout(dragTimer);
    dragTimer = null;
    dragCandidate = null;

    const rect = button.getBoundingClientRect();
    const ghost = button.cloneNode(true);
    ghost.classList.add("drag-ghost");
    ghost.style.cssText += "position:fixed;left:" + rect.left + "px;top:" + rect.top
      + "px;width:" + rect.width + "px;height:" + rect.height
      + "px;margin:0;z-index:60;pointer-events:none;";
    document.body.appendChild(ghost);

    dragState = {
      item: item, ghost: ghost,
      offsetX: touch.clientX - rect.left,
      offsetY: touch.clientY - rect.top,
    };
    renderPages();
  }

  function moveDrag(touch) {
    const ghost = dragState.ghost;
    ghost.style.left = (touch.clientX - dragState.offsetX) + "px";
    ghost.style.top = (touch.clientY - dragState.offsetY) + "px";

    // The ghost sits under the finger, so it would always be the element found
    // at that point. Hide it for the hit test only.
    ghost.style.visibility = "hidden";
    const under = document.elementFromPoint(touch.clientX, touch.clientY);
    ghost.style.visibility = "visible";

    const target = under && under.closest ? under.closest(".deck-btn") : null;
    if (!target || target.classList.contains("add")) return;

    const targetIndex = parseInt(target.dataset.idx, 10);
    if (isNaN(targetIndex)) return;

    const items = deck.folders[activeFolder].items;
    const currentIndex = items.indexOf(dragState.item);
    if (currentIndex < 0 || targetIndex === currentIndex) return;

    items.splice(currentIndex, 1);
    items.splice(targetIndex, 0, dragState.item);
    renderPages();
  }

  function endDrag() {
    dragState.ghost.remove();
    dragState = null;
    persist();
    renderPages();
  }

  function wireDragGestures() {
    document.addEventListener("touchmove", (e) => {
      if (dragState) { e.preventDefault(); moveDrag(e.touches[0]); return; }
      if (!dragCandidate) return;

      const touch = e.touches[0];
      if (dragCandidate.armed) {
        e.preventDefault();
        beginDrag(touch);
        return;
      }
      // Moved before the hold completed: this is a page swipe, not a drag.
      const travelled = Math.hypot(touch.clientX - dragCandidate.x, touch.clientY - dragCandidate.y);
      if (travelled > DRAG_CANCEL_DISTANCE) clearCandidate();
    }, { passive: false });

    document.addEventListener("touchend", () => {
      if (dragState) { endDrag(); return; }
      // Released before the hold completed: a tap in edit mode means "edit me".
      if (dragCandidate) {
        const item = dragCandidate.item;
        clearCandidate();
        openEditor(item);
      }
    });

    pagesEl.addEventListener("scroll", () => {
      const width = pagesEl.clientWidth;
      if (!width) return;
      const index = Math.round(pagesEl.scrollLeft / width);
      dotsEl.querySelectorAll(".pd").forEach((dot, i) => dot.classList.toggle("on", i === index));
    });
  }

  // ───────────────────────── button editor ─────────────────────────

  let draft = null, draftIndex = -1;

  function isAppPath(target) { return (target || "").startsWith("/"); }

  function openEditor(item) {
    draftIndex = item ? deck.folders[activeFolder].items.indexOf(item) : -1;
    // A deep copy, so Cancel genuinely cancels.
    draft = item
      ? JSON.parse(JSON.stringify(item))
      : { id: uid(), type: "shortcut", label: "", keyCode: 8, mods: ["command"] };
    if (!draft.mods) draft.mods = [];
    renderEditor();
  }

  function closeEditor() {
    modalRoot.innerHTML = "";
    draft = null;
    refreshAppPicker = null;
  }

  function renderEditor() {
    modalRoot.innerHTML =
      '<div class="modal-bg"></div><div class="modal-card">' +
      '<div class="modal-head"><div class="modal-title">' +
        (draftIndex >= 0 ? "Edit button" : "Add button") +
      '</div><button id="ed-close" class="modal-x" aria-label="Close">✕</button></div>' +
      '<div class="seg" id="ed-type">' +
        '<button data-type="shortcut">Shortcut</button>' +
        '<button data-type="text">Text</button>' +
        '<button data-type="launch">App / link</button></div>' +
      '<input id="ed-label" class="ed-input" placeholder="Button name" maxlength="'
        + MAX_LABEL_LENGTH + '">' +
      '<div class="ed-row"><input id="ed-icon" class="ed-input ed-icon" maxlength="2" placeholder="🙂">' +
        '<select id="ed-folder" class="ed-input" aria-label="Folder"></select></div>' +
      '<div class="ed-colors" id="ed-colors"></div>' +
      '<div id="ed-body"></div>' +
      '<div class="modal-actions">' +
        (draftIndex >= 0 ? '<button id="ed-delete" class="danger">Delete</button>' : "") +
        '<span class="spacer"></span><button id="ed-cancel">Cancel</button>' +
        '<button id="ed-save" class="primary">Save</button>' +
      "</div></div>";

    const find = (selector) => modalRoot.querySelector(selector);

    find(".modal-bg").addEventListener("click", closeEditor);
    find("#ed-cancel").addEventListener("click", closeEditor);
    find("#ed-close").addEventListener("click", closeEditor);

    const labelEl = find("#ed-label");
    labelEl.value = draft.label || "";
    labelEl.addEventListener("input", () => { draft.label = labelEl.value; });

    // A data-URI icon came from the app picker; it is not editable as text, so
    // the field stays blank rather than showing a kilobyte of base64.
    const iconEl = find("#ed-icon");
    iconEl.value = (draft.icon && !draft.icon.startsWith("data:")) ? draft.icon : "";
    iconEl.addEventListener("input", () => { draft.icon = iconEl.value || null; });

    const folderEl = find("#ed-folder");
    deck.folders.forEach((folder, index) => {
      const option = document.createElement("option");
      option.value = index;
      option.textContent = folder.name;
      if (index === activeFolder) option.selected = true;
      folderEl.appendChild(option);
    });

    const colorsEl = find("#ed-colors");
    COLORS.forEach((color) => {
      const swatch = document.createElement("button");
      swatch.className = "sw" + ((draft.color || "") === color ? " on" : "");
      swatch.style.background = color || "transparent";
      if (!color) { swatch.textContent = "∅"; swatch.setAttribute("aria-label", "No colour"); }
      swatch.addEventListener("click", () => {
        draft.color = color || null;
        colorsEl.querySelectorAll(".sw").forEach((s) => s.classList.remove("on"));
        swatch.classList.add("on");
      });
      colorsEl.appendChild(swatch);
    });

    modalRoot.querySelectorAll("#ed-type button").forEach((button) => {
      button.classList.toggle("on", button.dataset.type === draft.type);
      button.addEventListener("click", () => {
        draft.type = button.dataset.type;
        if (draft.type === "shortcut" && draft.keyCode == null) {
          draft.keyCode = 8;
          draft.mods = ["command"];
        }
        renderEditor();
      });
    });

    renderEditorBody();

    if (draftIndex >= 0) {
      find("#ed-delete").addEventListener("click", () => {
        if (!confirm("Delete this button?")) return;
        deck.folders[activeFolder].items.splice(draftIndex, 1);
        persist(); closeEditor(); render();
      });
    }
    find("#ed-save").addEventListener("click", saveDraft);
  }

  function renderEditorBody() {
    const body = modalRoot.querySelector("#ed-body");
    if (draft.type === "shortcut") renderComboBuilder(body);
    else if (draft.type === "text") renderTextEditor(body);
    else if (draft.type === "launch") renderLaunchEditor(body);
  }

  function renderTextEditor(body) {
    body.innerHTML = '<div class="ed-label">Text to type</div>'
      + '<textarea id="ed-text" class="ed-input ed-text" maxlength="' + MAX_TEXT_LENGTH + '"></textarea>';
    const area = body.querySelector("#ed-text");
    area.value = draft.text || "";
    area.addEventListener("input", () => { draft.text = area.value; });
  }

  function renderComboBuilder(body) {
    body.innerHTML = '<div class="ed-label">Key</div>'
      + '<div class="ed-mods" id="ed-mods"></div>'
      + '<input id="ed-keychar" class="ed-input" maxlength="1" placeholder="a, 1, = …"'
        + ' autocapitalize="off" autocorrect="off">'
      + '<div class="ed-label">or a special key</div>'
      + '<div class="ed-specials" id="ed-specials"></div>'
      + '<div class="ed-preview" id="ed-preview"></div>';

    const modsEl = body.querySelector("#ed-mods");
    const charEl = body.querySelector("#ed-keychar");
    const specialsEl = body.querySelector("#ed-specials");
    const previewEl = body.querySelector("#ed-preview");

    function refresh() {
      previewEl.textContent = L.comboLabel(draft.keyCode, draft.mods);
      modsEl.querySelectorAll("button").forEach((b) => {
        b.classList.toggle("on", draft.mods.includes(b.dataset.mod));
      });
      specialsEl.querySelectorAll("button").forEach((b) => {
        b.classList.toggle("on", parseInt(b.dataset.key, 10) === draft.keyCode);
      });
    }

    L.MOD_ORDER.forEach((mod) => {
      const button = document.createElement("button");
      button.dataset.mod = mod;
      button.textContent = L.MOD_SYMBOL[mod];
      button.addEventListener("click", () => {
        draft.mods = draft.mods.includes(mod)
          ? draft.mods.filter((m) => m !== mod)
          : draft.mods.concat([mod]);
        refresh();
      });
      modsEl.appendChild(button);
    });

    // Only prefill the character field if the current key *is* a character;
    // otherwise it is a special key and belongs to the grid below.
    const existing = L.keyLabel(draft.keyCode);
    charEl.value = existing.length === 1 ? existing.toLowerCase() : "";
    charEl.addEventListener("input", () => {
      const code = L.keyCodeForChar(charEl.value);
      if (code === null) return;
      draft.keyCode = code;
      refresh();
    });

    L.SPECIAL_KEYS.forEach((special) => {
      const button = document.createElement("button");
      button.dataset.key = special.keyCode;
      button.textContent = special.label;
      button.addEventListener("click", () => {
        draft.keyCode = special.keyCode;
        charEl.value = "";
        refresh();
      });
      specialsEl.appendChild(button);
    });

    refresh();
  }

  function renderLaunchEditor(body) {
    body.innerHTML = '<div class="ed-label">Link (https only) or pick an installed app</div>'
      + '<input id="ed-target" class="ed-input" placeholder="https://…"'
        + ' autocapitalize="off" autocorrect="off">'
      + '<div class="ed-label">Installed apps</div>'
      + '<input id="ed-appsearch" class="ed-input" placeholder="Search apps…"'
        + ' autocapitalize="off" autocorrect="off">'
      + '<div class="ed-apps" id="ed-apps"></div>';

    const targetEl = body.querySelector("#ed-target");
    targetEl.value = draft.target || "";
    targetEl.addEventListener("input", () => { draft.target = targetEl.value; });

    const searchEl = body.querySelector("#ed-appsearch");
    const listEl = body.querySelector("#ed-apps");

    // Held so the `apps` message can repaint the list when it arrives, which is
    // usually after the sheet is already open.
    refreshAppPicker = () => {
      const needle = searchEl.value.toLowerCase();
      listEl.innerHTML = "";
      installedApps
        .filter((app) => !needle || app.name.toLowerCase().includes(needle))
        .slice(0, MAX_APPS_LISTED)
        .forEach((app) => listEl.appendChild(appRow(app, targetEl)));
    };
    searchEl.addEventListener("input", refreshAppPicker);
    refreshAppPicker();

    send({ t: "apps.get" });
  }

  function appRow(app, targetEl) {
    const row = document.createElement("button");
    row.className = "app-row";
    if (app.icon) {
      const img = document.createElement("img");
      img.src = app.icon;
      img.alt = "";
      row.appendChild(img);
    }
    const name = document.createElement("span");
    name.textContent = app.name;
    row.appendChild(name);

    row.addEventListener("click", () => {
      draft.target = app.path;
      if (!draft.label) draft.label = app.name.slice(0, MAX_LABEL_LENGTH);
      if (app.icon) draft.icon = app.icon;
      targetEl.value = app.path;
      modalRoot.querySelector("#ed-label").value = draft.label;
    });
    return row;
  }

  function fallbackLabel(item) {
    if (item.type === "shortcut") return L.comboLabel(item.keyCode, item.mods);
    if (item.type === "text") return (item.text || "Text").slice(0, 8);
    if (item.type === "launch") return isAppPath(item.target) ? "App" : "Link";
    return "Button";
  }

  function saveDraft() {
    if (draft.type === "launch") {
      const target = (draft.target || "").trim();
      const isApp = target.startsWith("/") && target.endsWith(".app");
      const isHTTPS = /^https:\/\/.+/i.test(target);
      if (!isApp && !isHTTPS) {
        toast("Links must start with https:// , or pick an installed app.");
        return;
      }
      draft.target = target;
    }
    if (!draft.label) draft.label = fallbackLabel(draft);

    const folderEl = modalRoot.querySelector("#ed-folder");
    let destination = folderEl ? parseInt(folderEl.value, 10) : activeFolder;
    if (isNaN(destination) || destination < 0 || destination >= deck.folders.length) {
      destination = activeFolder;
    }

    if (draftIndex >= 0) {
      const items = deck.folders[activeFolder].items;
      if (destination === activeFolder) {
        items[draftIndex] = draft;
      } else {
        items.splice(draftIndex, 1);
        deck.folders[destination].items.push(draft);
      }
    } else {
      if (deck.folders[destination].items.length >= MAX_ITEMS_PER_FOLDER) {
        toast("Folder is full.");
        return;
      }
      deck.folders[destination].items.push(draft);
    }
    activeFolder = destination;

    persist(); closeEditor(); render();
  }

  // ───────────────────────── public interface ─────────────────────────

  root.RemoteMacDeck = {
    /// `hooks` supplies the three things this module cannot do for itself:
    /// send a command, show a message, and buzz.
    init: function (hooks) {
      send = hooks.send;
      toast = hooks.toast;
      buzz = hooks.buzz;

      pagesEl = $("deck-pages");
      dotsEl = $("page-dots");
      tabsEl = $("folder-tabs");
      toolbarEl = $("deck-toolbar");
      modalRoot = $("modal-root");
      hintEl = $("deck-hint");

      deck = loadLocal() || defaultDeck();

      $("deck-edit").addEventListener("click", () => {
        editMode = !editMode;
        $("deck-edit").classList.toggle("on", editMode);
        toolbarEl.classList.toggle("on", editMode);
        render();
      });

      wireDragGestures();
      render();
    },

    render: render,

    /// The Mac sent its copy of the deck. It wins: it is the copy that actually
    /// resolves button presses.
    adopt: function (fromMac) {
      deck = fromMac;
      saveLocal();
      render();
    },

    /// The Mac has no deck yet — give it this one.
    seedMac: pushToMac,

    setInstalledApps: function (apps) {
      installedApps = apps || [];
      if (refreshAppPicker) refreshAppPicker();
    },
  };
})(window);

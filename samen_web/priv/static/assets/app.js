// Samen client runtime — ADR-042 C2. Dependency-free LiveView transport shim + the
// global ⌘K focus listener. Loaded (deferred, in order) after phoenix.min.js (which
// defines the global `Phoenix`) and phoenix_live_view.min.js (global `LiveView`).
//
// Masking stays SERVER-RENDERED (ADR-042 §6 / C6): this file resolves NO value, holds
// NO token or key, and references NO vault field. It is a DOM patcher + a focus/nav
// affordance — nothing more. Every value the socket carries has already passed through
// Samen.Api.PiiResolution on the actor's plane server-side.
(function () {
  // (d) The seam future kit hooks register into — empty today.
  window.SamenHooks = window.SamenHooks || {};

  // (a) CSRF token from the meta the shared root layout emits.
  var meta = document.querySelector("meta[name='csrf-token']");
  var csrfToken = meta && meta.getAttribute("content");

  // (a2) In-flight affordance for `simple_form` (kit F06). The form carries
  //      `data-busy-text` (default "Saving…"); LiveView reads a submit button's
  //      `phx-disable-with` when the submit starts, so give any submit button that sets none
  //      the form's text first. A capture listener on `document` runs before LiveView's own
  //      `window` submit listener. Reads no field value; touches only a button attribute.
  document.addEventListener("submit", function (e) {
    var form = e.target;
    if (!form || !form.getAttribute || !form.hasAttribute("data-busy-text")) return;
    var text = form.getAttribute("data-busy-text");
    if (!text) return;
    var buttons = form.querySelectorAll("button[type=submit], button:not([type])");
    for (var i = 0; i < buttons.length; i++) {
      if (!buttons[i].hasAttribute("phx-disable-with")) buttons[i].setAttribute("phx-disable-with", text);
    }
  }, true);

  // (b) Construct the LiveSocket against the "/live" websocket every host endpoint
  //     declares, authenticating with the same CSRF token via connect params (C7). If a
  //     vendored client script failed to load (blocked / network), leave the server-rendered
  //     page intact (links and forms still work) instead of throwing a ReferenceError.
  if (window.LiveView && window.Phoenix) {
    var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
      hooks: window.SamenHooks,
      params: { _csrf_token: csrfToken }
    });

    // (c) Connect. Websocket transport only (matches the endpoints' declaration).
    liveSocket.connect();

    // (d) Expose for reconnect/debug from the console.
    window.liveSocket = liveSocket;
  }

  // (e) The GLOBAL ⌘K (Ctrl+K) focus shortcut, relocated verbatim from the inline
  //     root-layout <script> (WS-E E6 / ADR-027). Focuses the ⌘K palette input when
  //     present, else the per-list search box, else submits its search form. Purely a
  //     focus/navigation affordance — it renders/reads no value, so it cannot touch
  //     masking.
  document.addEventListener("keydown", function (e) {
    if (!(e.metaKey || e.ctrlKey) || (e.key !== "k" && e.key !== "K")) return;
    var el = document.getElementById("cmdk-input") || document.querySelector("input[data-cmdk]");
    if (el) { e.preventDefault(); el.focus(); if (el.select) el.select(); return; }
    var form = document.querySelector("form.search[action]");
    if (form) { e.preventDefault(); form.submit(); }
  });
})();

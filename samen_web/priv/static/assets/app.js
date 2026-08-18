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

  // (b) Construct the LiveSocket against the "/live" websocket every host endpoint
  //     declares, authenticating with the same CSRF token via connect params (C7).
  var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    hooks: window.SamenHooks,
    params: { _csrf_token: csrfToken }
  });

  // (c) Connect. Websocket transport only (matches the endpoints' declaration).
  liveSocket.connect();

  // (d) Expose for reconnect/debug from the console.
  window.liveSocket = liveSocket;

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

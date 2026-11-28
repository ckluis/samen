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

  // (a3) The `data-confirm` interlock. The kit renders `data-confirm="<question>"` on every
  //      destructive control (delete_confirm, kill/stop/approve buttons, link or form). Nothing
  //      else in the served client reads it, so this does: a capture listener on `document`
  //      runs before LiveView's own `window` listeners, asks `window.confirm`, and on refusal
  //      stops the event dead (preventDefault + stopImmediatePropagation) so no `phx-click`,
  //      link navigation or form submit follows. Delegated, so elements patched in later are
  //      covered. A form is confirmed on its submit event only (a click on one of its buttons
  //      is not asked twice). Reads no field value.
  function confirmGuard(e, ask, wantForm) {
    var t = e && e.target;
    if (!t || !t.closest) return;
    var el = t.closest("[data-confirm]");
    if (!el) return;
    var isForm = el.tagName === "FORM";
    if (isForm !== wantForm) return;
    if (!ask(el.getAttribute("data-confirm") || "")) {
      e.preventDefault();
      e.stopImmediatePropagation();
    }
  }
  var askUser = function (text) { return window.confirm(text); };
  document.addEventListener("click", function (e) { confirmGuard(e, askUser, false); }, true);
  document.addEventListener("submit", function (e) { confirmGuard(e, askUser, true); }, true);

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

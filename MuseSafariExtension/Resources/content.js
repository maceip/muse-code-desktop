/*
 * content.js
 * MuseSafariExtension
 *
 * Persistent DOM inspection, form interaction, navigation, and structured
 * extraction engine injected into Safari pages for the Muse coding agent.
 */

(() => {
  let lastPingTime = 0;

  const pollLocalHTTPAndBackground = () => {
    try {
      const now = Date.now();
      if (now - lastPingTime < 3000) {
        return;
      }
      lastPingTime = now;

      if (typeof browser !== "undefined" && browser.runtime && browser.runtime.sendMessage) {
        browser.runtime
          .sendMessage({
            target: "background",
            command: { action: "checkIfThisTabOwned" }
          })
          .then((resp) => {
            if (resp && resp.data && resp.data.owned && window.__museSafariBridge && window.__museSafariBridge.updateOwnedBadge) {
              window.__museSafariBridge.updateOwnedBadge(true);
            }
            if (resp && resp.pendingCommand && window.__museSafariBridge && window.__museSafariBridge.handleCommand) {
              const cmd = resp.pendingCommand;
              window.__museSafariBridge.handleCommand(cmd).then((cmdResult) => {
                browser.runtime
                  .sendMessage({
                    target: "background",
                    commandResult: {
                      id: cmd.id,
                      result: cmdResult
                    }
                  })
                  .catch(() => {});
              });
            }
          })
          .catch(() => {});
      }
    } catch (_) {}
  };
  const pingBackground = pollLocalHTTPAndBackground;

  if (window.__museSafariBridgeInterval) {
    clearInterval(window.__museSafariBridgeInterval);
  }
  const alreadyInstalled = Boolean(window.__museSafariBridgeInstalled);
  window.__museSafariBridgeInstalled = true;

  function computeSelector(el) {
    if (!el || el.nodeType !== 1) return "";
    if (el.id) {
      return `#${CSS.escape(el.id)}`;
    }
    const nameAttr = el.getAttribute("name");
    if (nameAttr) {
      return `${el.tagName.toLowerCase()}[name="${CSS.escape(nameAttr)}"]`;
    }
    const ariaLabel = el.getAttribute("aria-label");
    if (ariaLabel) {
      return `${el.tagName.toLowerCase()}[aria-label="${CSS.escape(ariaLabel)}"]`;
    }
    const parts = [];
    let curr = el;
    while (curr && curr.nodeType === 1 && curr !== document.body && parts.length < 5) {
      let tag = curr.tagName.toLowerCase();
      if (curr.id) {
        parts.unshift(`#${CSS.escape(curr.id)}`);
        break;
      }
      const parent = curr.parentElement;
      if (parent) {
        const siblings = Array.from(parent.children).filter((c) => c.tagName === curr.tagName);
        if (siblings.length > 1) {
          const idx = siblings.indexOf(curr) + 1;
          tag += `:nth-of-type(${idx})`;
        }
      }
      parts.unshift(tag);
      curr = parent;
    }
    return parts.join(" > ");
  }

  function findLabelForElement(el) {
    if (!el) return "";
    if (el.id) {
      const explicit = document.querySelector(`label[for="${CSS.escape(el.id)}"]`);
      if (explicit && explicit.innerText) return explicit.innerText.trim();
    }
    const parentLabel = el.closest("label");
    if (parentLabel && parentLabel.innerText) return parentLabel.innerText.trim();
    const aria = el.getAttribute("aria-label") || el.getAttribute("placeholder") || el.getAttribute("title") || "";
    return aria.trim();
  }

  function resolveElement(selectorOrHint) {
    if (!selectorOrHint) return null;
    try {
      const direct = document.querySelector(selectorOrHint);
      if (direct) return direct;
    } catch (_) {}

    const lowered = String(selectorOrHint).toLowerCase().trim();
    const candidates = Array.from(
      document.querySelectorAll(
        "input, textarea, select, button, a, label, [role='button'], [role='menuitem'], [role='option'], [role='checkbox'], [role='radio'], [contenteditable='true']"
      )
    );
    const exactMatches = [];
    for (const el of candidates) {
      const name = (el.getAttribute("name") || "").toLowerCase();
      const id = (el.id || "").toLowerCase();
      const ariaLabel = (el.getAttribute("aria-label") || "").toLowerCase();
      const text = (el.innerText || el.value || "").toLowerCase().trim();
      if (
        name === lowered ||
        id === lowered ||
        ariaLabel === lowered ||
        text === lowered
      ) {
        exactMatches.push(el);
      }
    }
    if (exactMatches.length > 0) {
      // Prefer an enabled match inside an open modal/dialog, or the last enabled match in DOM order
      const enabledInModal = exactMatches.filter(
        (el) => !el.disabled && el.closest("[role='dialog'], [aria-modal='true'], .modal, .ReactModal__Content")
      );
      if (enabledInModal.length > 0) {
        return enabledInModal[enabledInModal.length - 1];
      }
      const enabledMatches = exactMatches.filter((el) => !el.disabled);
      if (enabledMatches.length > 0) {
        return enabledMatches[enabledMatches.length - 1];
      }
      return exactMatches[exactMatches.length - 1];
    }
    for (const el of candidates) {
      const name = (el.getAttribute("name") || "").toLowerCase();
      const id = (el.id || "").toLowerCase();
      const placeholder = (el.getAttribute("placeholder") || "").toLowerCase();
      const ariaLabel = (el.getAttribute("aria-label") || "").toLowerCase();
      const label = findLabelForElement(el).toLowerCase();
      const text = (el.innerText || el.value || "").toLowerCase().trim();
      if (
        placeholder.includes(lowered) ||
        ariaLabel.includes(lowered) ||
        label.includes(lowered) ||
        text.includes(lowered)
      ) {
        return el;
      }
    }
    return null;
  }

  function setNativeElementValue(el, value) {
    if (!el) return false;
    el.focus();
    if (el.tagName === "SELECT") {
      const strVal = String(value);
      const option = Array.from(el.options).find(
        (opt) => opt.value === strVal || opt.text.trim().toLowerCase() === strVal.toLowerCase()
      );
      if (option) {
        el.value = option.value;
      } else {
        el.value = strVal;
      }
    } else if (el.type === "checkbox" || el.type === "radio") {
      el.checked = Boolean(value);
    } else if (el.isContentEditable) {
      el.innerText = String(value);
    } else {
      const proto =
        el.tagName === "TEXTAREA"
          ? window.HTMLTextAreaElement.prototype
          : window.HTMLInputElement.prototype;
      const descriptor = Object.getOwnPropertyDescriptor(proto, "value");
      if (descriptor && descriptor.set) {
        descriptor.set.call(el, String(value));
      } else {
        el.value = String(value);
      }
      // Also update React/Redux controlled form fibers in main world if present
      if (el.id) {
        try {
          const s = document.createElement("script");
          s.textContent = `(() => {
            const target = document.getElementById(${JSON.stringify(el.id)});
            if (!target) return;
            if (target._valueTracker) target._valueTracker.setValue("");
            const fk = Object.keys(target).find(k => k.startsWith("__reactInternalInstance") || k.startsWith("__reactFiber"));
            let f = fk ? target[fk] : null;
            while (f) {
              if (f.memoizedProps && typeof f.memoizedProps.onChange === "function" && String(f.memoizedProps.onChange).includes("nextValue")) {
                try { f.memoizedProps.onChange(${JSON.stringify(String(value))}); } catch (_) {}
                break;
              }
              f = f.return;
            }
          })()`;
          document.documentElement.appendChild(s);
          s.remove();
        } catch (_) {}
      }
    }
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    el.blur();
    return true;
  }

  function inspectDOM() {
    const inputs = Array.from(document.querySelectorAll("input, textarea, select")).slice(0, 120).map((el) => ({
      tag: el.tagName.toLowerCase(),
      type: el.getAttribute("type") || (el.tagName === "TEXTAREA" ? "textarea" : "text"),
      selector: computeSelector(el),
      name: el.getAttribute("name") || "",
      id: el.id || "",
      label: findLabelForElement(el),
      placeholder: el.getAttribute("placeholder") || "",
      value: el.type === "password" ? "***" : el.value || "",
      checked: Boolean(el.checked),
      disabled: Boolean(el.disabled),
      options:
        el.tagName === "SELECT"
          ? Array.from(el.options).slice(0, 60).map((o) => ({ value: o.value, text: o.text.trim() }))
          : undefined
    }));

    const buttons = Array.from(
      document.querySelectorAll(
        "button, input[type='submit'], [role='button'], [role='menuitem'], [role='option'], [role='checkbox'], [role='radio'], [role='dialog'] a:not([href]), [aria-modal='true'] a:not([href])"
      )
    )
      .slice(0, 120)
      .map((el) => ({
        tag: el.tagName.toLowerCase(),
        role: el.getAttribute("role") || "",
        selector: computeSelector(el),
        text: (el.innerText || el.value || el.getAttribute("aria-label") || "").trim().slice(0, 100),
        disabled: Boolean(el.disabled)
      }))
      .filter((b) => b.text.length > 0 || b.selector.length > 0);

    const links = Array.from(document.querySelectorAll("a[href]"))
      .slice(0, 50)
      .map((a) => ({
        text: (a.innerText || a.getAttribute("aria-label") || "").trim().slice(0, 120),
        href: a.href,
        selector: computeSelector(a)
      }))
      .filter((l) => l.text.length > 0);

    const headings = Array.from(document.querySelectorAll("h1, h2, h3"))
      .slice(0, 25)
      .map((h) => ({
        level: h.tagName.toLowerCase(),
        text: (h.innerText || "").trim().slice(0, 160)
      }))
      .filter((h) => h.text.length > 0);

    const bodyText = (document.body ? document.body.innerText : "").replace(/\s+/g, " ").trim().slice(0, 2500);

    return {
      url: window.location.href,
      title: document.title || "",
      readyState: document.readyState,
      headings,
      inputs,
      buttons,
      links,
      formCount: document.forms.length,
      textExcerpt: bodyText
    };
  }

  function extractScholarResults() {
    const rows = Array.from(document.querySelectorAll(".gs_r.gs_or.gs_scl, .gs_ri, article, .result, .g"));
    const results = [];
    for (const row of rows.slice(0, 20)) {
      const titleEl = row.querySelector(".gs_rt a, h3 a, h2 a, a");
      const metaEl = row.querySelector(".gs_a, .cite, .author");
      const snippetEl = row.querySelector(".gs_rs, .snippet, p");
      const pdfEl = row.querySelector(".gs_or_ggsm a, a[href$='.pdf']");
      if (titleEl && titleEl.innerText.trim()) {
        results.push({
          title: titleEl.innerText.trim(),
          url: titleEl.href || "",
          authorsAndVenue: metaEl ? metaEl.innerText.trim() : "",
          snippet: snippetEl ? snippetEl.innerText.trim() : "",
          pdfUrl: pdfEl ? pdfEl.href : null
        });
      }
    }
    return results;
  }

  function updateOwnedBadge(owned) {
    let badge = document.getElementById("__muse-safari-owned-pill");
    let topBar = document.getElementById("__muse-safari-top-bar");
    let themeMeta = document.querySelector('meta[name="theme-color"]');

    if (!owned) {
      if (badge) badge.remove();
      if (topBar) topBar.remove();
      if (themeMeta && themeMeta.hasAttribute("data-muse-owned")) {
        const prev = themeMeta.getAttribute("data-muse-prev-color");
        if (prev) {
          themeMeta.setAttribute("content", prev);
          themeMeta.removeAttribute("data-muse-owned");
          themeMeta.removeAttribute("data-muse-prev-color");
        } else {
          themeMeta.remove();
        }
      }
      if (document.title.startsWith("🟢 ")) {
        document.title = document.title.slice(3);
      }
      return;
    }

    // 1. Tint Safari tab bar via <meta name="theme-color">
    if (document.head) {
      if (!themeMeta) {
        themeMeta = document.createElement("meta");
        themeMeta.setAttribute("name", "theme-color");
        themeMeta.setAttribute("data-muse-owned", "true");
        document.head.appendChild(themeMeta);
      } else if (!themeMeta.hasAttribute("data-muse-owned")) {
        themeMeta.setAttribute("data-muse-prev-color", themeMeta.getAttribute("content") || "");
        themeMeta.setAttribute("data-muse-owned", "true");
      }
      themeMeta.setAttribute("content", "#10b981");
    }

    // 2. Prefix tab title with a green indicator dot so the tab itself stands out in the Safari tab bar
    if (document.title && !document.title.startsWith("🟢 ")) {
      document.title = "🟢 " + document.title;
    }

    // 3. Render a 3px emerald-blue glowing top border across the viewport
    if (!topBar && document.body) {
      topBar = document.createElement("div");
      topBar.id = "__muse-safari-top-bar";
      Object.assign(topBar.style, {
        position: "fixed",
        top: "0",
        left: "0",
        right: "0",
        height: "3px",
        zIndex: "2147483647",
        background: "linear-gradient(90deg, #10b981 0%, #0077ff 50%, #10b981 100%)",
        boxShadow: "0 1px 10px rgba(16, 185, 129, 0.75)",
        pointerEvents: "none"
      });
      document.body.appendChild(topBar);
    }

    // 4. Render floating corner pill badge
    if (!badge && document.body) {
      badge = document.createElement("div");
      badge.id = "__muse-safari-owned-pill";
      badge.textContent = "● Muse Claimed Tab";
      Object.assign(badge.style, {
        position: "fixed",
        bottom: "12px",
        right: "12px",
        zIndex: "2147483647",
        padding: "5px 11px",
        borderRadius: "999px",
        background: "linear-gradient(135deg, #059669, #10b981)",
        color: "#ffffff",
        fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif",
        fontSize: "11.5px",
        fontWeight: "600",
        boxShadow: "0 4px 14px rgba(16, 185, 129, 0.45)",
        border: "1px solid rgba(255, 255, 255, 0.35)",
        pointerEvents: "none"
      });
      document.body.appendChild(badge);
    }
  }

  async function handleCommand(cmd) {
    const action = cmd.action || "inspectDOM";

    if (action === "markOwned") {
      updateOwnedBadge(Boolean(cmd.owned));
      return { ok: true, action };
    }

    if (action === "inspectDOM" || action === "snapshot") {
      return { ok: true, action, data: inspectDOM() };
    }

    if (action === "getValue" || action === "querySelector") {
      const el = resolveElement(cmd.selector);
      if (!el) {
        return { ok: false, action, error: `Element not found for selector: ${cmd.selector}` };
      }
      const rect = el.getBoundingClientRect();
      return {
        ok: true,
        action,
        data: {
          selector: computeSelector(el),
          tag: el.tagName.toLowerCase(),
          text: (el.innerText || el.textContent || "").trim(),
          value: el.value !== undefined ? el.value : null,
          checked: Boolean(el.checked),
          href: el.href || null,
          attributes: Object.fromEntries(Array.from(el.attributes || []).map((a) => [a.name, a.value])),
          rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
        }
      };
    }

    if (action === "querySelectorAll") {
      const nodes = Array.from(document.querySelectorAll(cmd.selector || "a")).slice(0, cmd.limit || 50);
      return {
        ok: true,
        action,
        data: nodes.map((el) => ({
          selector: computeSelector(el),
          tag: el.tagName.toLowerCase(),
          text: (el.innerText || el.textContent || "").trim(),
          value: el.value !== undefined ? el.value : null,
          href: el.href || null
        }))
      };
    }

    if (action === "fill" || action === "setValue") {
      const el = resolveElement(cmd.selector);
      if (!el) {
        return { ok: false, action, error: `Input element not found: ${cmd.selector}` };
      }
      setNativeElementValue(el, cmd.value ?? "");
      if (cmd.submit) {
        const form = el.closest("form");
        if (form) {
          if (typeof form.requestSubmit === "function") form.requestSubmit();
          else form.submit();
        } else {
          el.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", keyCode: 13, bubbles: true }));
        }
      }
      return {
        ok: true,
        action,
        data: {
          selector: computeSelector(el),
          value: el.value
        }
      };
    }

    if (action === "fillForm") {
      const fields = cmd.fields || {};
      const filled = [];
      const missing = [];
      for (const [key, val] of Object.entries(fields)) {
        const el = resolveElement(key);
        if (el) {
          setNativeElementValue(el, val);
          filled.push({ field: key, selector: computeSelector(el), value: String(val) });
        } else {
          missing.push(key);
        }
      }
      if (cmd.submit && filled.length > 0) {
        const firstEl = resolveElement(filled[0].selector);
        const form = firstEl ? firstEl.closest("form") : document.forms[0];
        if (form) {
          if (typeof form.requestSubmit === "function") form.requestSubmit();
          else form.submit();
        }
      }
      return {
        ok: missing.length === 0 || filled.length > 0,
        action,
        data: { filled, missing }
      };
    }

    if (action === "click") {
      const el = resolveElement(cmd.selector || cmd.text);
      if (!el) {
        return { ok: false, action, error: `Clickable element not found: ${cmd.selector || cmd.text}` };
      }
      el.scrollIntoView({ block: "center", behavior: "instant" });
      try {
        el.focus();
        for (const evType of ["pointerdown", "mousedown", "pointerup", "mouseup"]) {
          el.dispatchEvent(new MouseEvent(evType, { bubbles: true, cancelable: true, view: window }));
        }
      } catch (_) {}
      el.click();
      return {
        ok: true,
        action,
        data: {
          selector: computeSelector(el),
          text: (el.innerText || el.value || "").trim()
        }
      };
    }

    if (action === "submit") {
      const el = cmd.selector ? resolveElement(cmd.selector) : document.activeElement;
      const form = (el && el.closest ? el.closest("form") : null) || document.forms[0];
      if (!form) {
        return { ok: false, action, error: "No form found to submit" };
      }
      if (typeof form.requestSubmit === "function") form.requestSubmit();
      else form.submit();
      return { ok: true, action, data: { submitted: true } };
    }

    if (action === "scroll") {
      if (cmd.selector) {
        const el = resolveElement(cmd.selector);
        if (!el) return { ok: false, action, error: `Element not found: ${cmd.selector}` };
        el.scrollIntoView({ block: "center", behavior: "smooth" });
      } else if (cmd.position === "top") {
        window.scrollTo({ top: 0, behavior: "instant" });
      } else if (cmd.position === "bottom") {
        window.scrollTo({ top: document.body.scrollHeight, behavior: "instant" });
      } else {
        window.scrollBy({ left: cmd.x || 0, top: cmd.y || 500, behavior: "instant" });
      }
      return { ok: true, action, data: { scrollX: window.scrollX, scrollY: window.scrollY } };
    }

    if (action === "goBack") {
      window.history.back();
      return { ok: true, action };
    }

    if (action === "goForward") {
      window.history.forward();
      return { ok: true, action };
    }

    if (action === "extractScholar") {
      return { ok: true, action, data: { url: window.location.href, results: extractScholarResults() } };
    }

    if (action === "eval") {
      try {
        const fn = new Function(`return (${cmd.script})`);
        const result = await fn();
        return { ok: true, action, data: { result } };
      } catch (err) {
        return { ok: false, action, error: String(err && err.message ? err.message : err) };
      }
    }

    return { ok: false, action, error: `Unsupported action: ${action}` };
  }

  window.__museSafariBridge = {
    handleCommand,
    inspectDOM,
    extractScholarResults,
    resolveElement,
    setNativeElementValue,
    updateOwnedBadge
  };

  if (typeof browser !== "undefined" && browser.runtime && browser.runtime.onMessage) {
    if (!alreadyInstalled) {
      browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
        const handler =
          window.__museSafariBridge && window.__museSafariBridge.handleCommand
            ? window.__museSafariBridge.handleCommand
            : handleCommand;
        handler(message || {}).then(sendResponse);
        return true;
      });
    }
    pingBackground();
    window.__museSafariBridgeInterval = setInterval(pingBackground, 5000);
  }
})();

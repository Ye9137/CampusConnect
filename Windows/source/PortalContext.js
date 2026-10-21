((run) => {
  const origin = /*CONTEXT_ORIGIN*/;
  const fallback = /*CONTEXT_FALLBACK*/;
  if (location.origin !== origin) return typeof fallback === 'boolean' ? false : 'wrong-origin';
  const selector = /*CONTEXT_PASSWORD_SELECTOR*/ || 'input[type="password"]';
  const candidates = [], leaves = [];
  let count = 0, exhausted = false;
  const visit = (target, depth) => {
    if (depth > 8 || ++count > 64) { exhausted = true; return; }
    try {
      if (target.location.origin !== origin) return;
      const doc = target.document;
      // Prefer a form on this document over embedded ancillary content.
      // Hidden password controls are intentional on older CMCC portals.
      if (doc.querySelector(selector)) { candidates.push(target); return; }
      let children = 0;
      for (const frame of doc.querySelectorAll('frame,iframe')) {
        const style = target.getComputedStyle(frame);
        if (![...frame.getClientRects()].some(rect => rect.width > 0 && rect.height > 0) || style.display === 'none' ||
            style.visibility === 'hidden' || style.visibility === 'collapse') continue;
        children++;
        visit(frame.contentWindow, depth + 1);
      }
      if (!children) leaves.push(target);
    } catch (_) { /* Cross-origin and sandboxed frames never receive credentials. */ }
  };
  const direct = () => run(window, document, location, HTMLInputElement, globalThis.HTMLSelectElement,
    globalThis.HTMLOptGroupElement, globalThis.Event, globalThis.FocusEvent, globalThis.MouseEvent, globalThis.getComputedStyle);
  let hasFrames;
  try { hasFrames = !!document.querySelector('frame,iframe'); document.querySelector(selector); }
  catch (_) { return direct(); }
  if (!hasFrames) return direct();
  visit(window, 0);
  const target = candidates.length === 1 ? candidates[0] :
    candidates.length === 0 && leaves.length === 1 ? leaves[0] : null;
  if (!target || exhausted) return fallback;
  return run(target, target.document, target.location, target.HTMLInputElement,
    target.HTMLSelectElement, target.HTMLOptGroupElement, target.Event,
    target.FocusEvent, target.MouseEvent, target.getComputedStyle.bind(target));
})(function(window, document, location, HTMLInputElement, HTMLSelectElement,
    HTMLOptGroupElement, Event, FocusEvent, MouseEvent, getComputedStyle) {
  return /*CONTEXT_SCRIPT*/;
})

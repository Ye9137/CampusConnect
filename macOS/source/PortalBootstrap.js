(() => {
  // No credentials or native bridge: only accelerate the inspected school's
  // initialization, preserving its original callbacks and encryption settings.
  const allowedOrigin = /*CAMPUS_ORIGIN*/;
  if (location.origin !== allowedOrigin) return;
  try {
    for (let ancestor = window; ; ancestor = ancestor.parent) {
      if (ancestor.location.origin !== allowedOrigin) return;
      if (ancestor === ancestor.parent) break;
    }
  } catch (_) { return; }
  if (window.__campusPortalBootstrapInstalled) return;
  window.__campusPortalBootstrapInstalled = true;
  // Keep operator popups from covering the login button. Install once per
  // document so manual choices still work after autofill has stopped.
  const menus = new Map();
  const visible = element => element && element.getClientRects().length > 0 &&
    getComputedStyle(element).visibility !== 'hidden';
  const popupFor = opener => {
    if (opener.id === 'serviceShowHideTop') return document.getElementById('serviceShowHide');
    const ids = (opener.getAttribute('aria-controls') || opener.getAttribute('aria-owns') || '').split(/\s+/).filter(Boolean);
    if (ids.length) return ids.map(id => document.getElementById(id)).find(popup => popup?.matches('[role="listbox"],[role="menu"]'));
    const popups = document.querySelectorAll('[role="listbox"],[role="menu"]');
    return popups.length === 1 ? popups[0] : null;
  };
  window.__campusRegisterServiceMenu = opener => {
    if (opener && !menus.has(opener)) menus.set(opener, {fallback:null, revision:0});
  };
  window.__campusCollapseServiceMenu = opener => {
    const state = menus.get(opener);
    const popup = state && popupFor(opener);
    if (!popup) return;
    // Give the school's own dismiss handler the first chance to update state.
    if (visible(popup)) opener.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', code:'Escape', bubbles:true}));
    if (visible(popup)) {
      state.fallback ||= {value:popup.style.getPropertyValue('display'), priority:popup.style.getPropertyPriority('display')};
      popup.style.setProperty('display', 'none', 'important');
    }
    if (opener.hasAttribute('aria-expanded')) opener.setAttribute('aria-expanded', 'false');
    if (popup.contains(document.activeElement)) document.activeElement.blur();
  };
  document.addEventListener('click', event => {
    // This known ePortal menu may use DIVs without accessible roles.
    const known = document.getElementById('serviceShowHideTop');
    if (known) window.__campusRegisterServiceMenu(known);
    for (const [opener, state] of menus) {
      if (!opener.isConnected) { menus.delete(opener); continue; }
      const popup = popupFor(opener);
      if (!popup) continue;
      if (opener.contains(event.target)) {
        const revision = ++state.revision;
        // Release a fallback after the school's toggle runs. Its handler sees a
        // closed popup, and a later opening is never blocked by our inline rule.
        const fallback = state.fallback;
        if (fallback) setTimeout(() => {
          if (state.revision !== revision) return;
          if (popup.style.getPropertyValue('display') === 'none' && popup.style.getPropertyPriority('display') === 'important') {
            if (fallback.value) popup.style.setProperty('display', fallback.value, fallback.priority);
            else popup.style.removeProperty('display');
          }
          state.fallback = null;
        });
        continue;
      }
      const choice = event.target.closest?.('[id^="bch_service_"],[role="option"],[role="menuitemradio"],[role="menuitem"],li,button');
      if (!choice || !popup.contains(choice) || choice.closest('[disabled],[aria-disabled="true"]')) continue;
      const revision = ++state.revision;
      const name = choice.textContent.trim();
      setTimeout(() => {
        if (state.revision !== revision || !opener.isConnected) return;
        // Only dismiss a confirmed choice, after the school's click handlers.
        const label = opener.id === 'serviceShowHideTop' ? document.getElementById('selectDisname') : opener;
        const value = document.getElementById('net_access_type');
        const text = label instanceof HTMLInputElement ? label.value : label?.textContent.trim();
        if ((text === name && (opener !== known || value?.value)) ||
            choice.getAttribute('aria-selected') === 'true' || choice.getAttribute('aria-checked') === 'true') {
          window.__campusCollapseServiceMenu(opener);
        }
      });
    }
  }, true);
  const start = () => {
    const load = window.onload;
    const known = typeof load === 'function' &&
      /^function\s*\([^)]*\)\s*\{\s*fillData\(\);\s*getServices\(\);\s*autosize\(\);?\s*\}$/.test(Function.prototype.toString.call(load));
    if (!known || !document.querySelector('#loginLink') ||
        typeof window.AuthInterFace?.pageInfo !== 'function' ||
        typeof window.AuthInterFace?.getServices !== 'function') return;
    const state = window.__campusReady = {pageInfo:false, getServices:false, failed:false};
    for (const name of ['pageInfo','getServices']) {
      const original = AuthInterFace[name];
      AuthInterFace[name] = function(...args) {
        const callback = args[args.length-1];
        if (typeof callback !== 'function') return original.apply(this,args);
        args[args.length-1] = function(...values) {
          // Mark ready only AFTER the school has installed handlers, selected
          // the service, and loaded its encryption key / captcha requirements.
          try { const result = callback.apply(this,values); state[name] = true; return result; }
          catch (error) { state.failed = true; throw error; }
        };
        return original.apply(this,args);
      };
    }
    // This exact handler has no load-event dependency. Invoke once at DOM ready;
    // late background images must not initialize it again or overwrite fields.
    window.onload = null;
    try { load.call(window); } catch (_) { state.failed = true; }
  };
  document.addEventListener('DOMContentLoaded', start, {once:true});
})();

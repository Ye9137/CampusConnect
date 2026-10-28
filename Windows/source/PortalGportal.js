  // Supplied Gportal template: the input label is "登 录" (NBSP). Select its
  // exact form/control and let the school's original login()/AES path submit.
  const gportalStatus = (() => {
    if (!gportalForm || !gportalButton || !cfg.submit) return null;
    const jq = window.jQuery;
    const iv = gportalForm.querySelector('input#iv[name="iv"]');
    if (typeof window.login !== 'function' || typeof window.cryptoEncode !== 'function' ||
        typeof window.CryptoJS?.AES?.encrypt !== 'function' || !iv?.value ||
        typeof jq?.fn?.on !== 'function') return 'waiting-ready';
    const state = window.__campusSubmitAttempt ||= {};
    if (state.gportalObserved) return null;
    const requests = new WeakSet();
    const expectedOrigin = cfg.origin;
    jq(document).on('ajaxSend.campusGportal', (_event, xhr, settings) => {
      if (!window.__campusSubmitted || String(settings.type).toUpperCase() !== 'POST') return;
      let url;
      try { url = new URL(settings.url, location.href); } catch (_) { return; }
      if (url.origin !== expectedOrigin || url.pathname !== '/gportal/web/authLogin') return;
      requests.add(xhr); state.gportalRequestStarted = true; state.result = null;
    });
    jq(document).on('ajaxComplete.campusGportal', (_event, xhr) => {
      if (!requests.has(xhr)) return;
      requests.delete(xhr);
      if (xhr.status < 200 || xhr.status >= 300) {
        state.result = xhr.status === 0 || [408,429].includes(xhr.status) || xhr.status >= 500 ? 'request-error' : 'fail';
        return;
      }
      let result = xhr.responseJSON;
      if (!result) { try { result = JSON.parse(xhr.responseText); } catch (_) { return; } }
      if (typeof result?.status === 'number') state.result = result.status === 1 ? 'success' : 'fail';
    });
    state.gportalObserved = true;
    return null;
  })();
  if (gportalStatus) return gportalStatus;

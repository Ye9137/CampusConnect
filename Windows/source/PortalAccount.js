  // The supplied account portal loads its password rules asynchronously.
  // Observe its original jQuery requests; never replace validation or submit APIs.
  const accountStatus = (() => {
    if (!cfg.submit || !accountButton || user.id !== 'username' || pass.id !== 'password' || pass.form?.id !== 'my-form') return null;
    const jq = window.jQuery;
    if (typeof passwordRuleScope !== 'object' || passwordRuleScope === null ||
        !['0','1',0,1].includes(passwordRuleScope.portal_auth) ||
        (passwordRuleScope.portal_auth == '1' && (typeof passwordConfig !== 'object' || passwordConfig === null)) ||
        typeof postData !== 'object' || postData === null || typeof host_url !== 'string' ||
        typeof window.doAuthCheck !== 'function' || typeof window.doPortalLogin !== 'function' ||
        typeof jq?.fn?.on !== 'function') return 'waiting-ready';
    const params = new URLSearchParams(location.search);
    if (((params.get('wlanuserip') || params.get('ip')) && !postData.userIpv4) ||
        (params.get('mac') && !postData.userMac)) return 'waiting-ready';
    const state = window.__campusSubmitAttempt ||= {};
    if (state.accountObserved) return null;
    const endpoint = value => {
      if (typeof value !== 'string' || !value) return null;
      try { const url = new URL(value, location.href); url.hash = ''; return url.href; } catch (_) { return null; }
    };
    const stages = new Map();
    for (const [stage, value] of [['password-check', host_url + '/account/check'], ['portal-login', host_url + '/account/login'],
        ['auth-sync', window.dxzAuthApiUrl], ['auth-check', window.dxzCheckApiUrl]]) {
      const url = endpoint(value);
      if (url) stages.set(url, stage);
    }
    const requests = new WeakMap();
    jq(document).on('ajaxSend.campusAccount', (_event, xhr, settings) => {
      if (!window.__campusSubmitted || String(settings.type).toUpperCase() !== 'POST') return;
      const stage = stages.get(endpoint(settings.url));
      if (!stage) return;
      requests.set(xhr, stage); state.accountRequestStarted = true;
      state.result = null; state.failureCode = ''; state.accountStage = stage;
    });
    jq(document).on('ajaxComplete.campusAccount', (_event, xhr) => {
      const stage = requests.get(xhr);
      if (!stage) return;
      requests.delete(xhr);
      if (xhr.status < 200 || xhr.status >= 300) {
        // Optional prechecks deliberately fall through on network errors.
        if (stage === 'password-check' || stage === 'portal-login') state.result = 'request-error';
        return;
      }
      let result = xhr.responseJSON;
      if (!result) { try { result = JSON.parse(xhr.responseText); } catch (_) { return; } }
      if (!result || typeof result !== 'object') return;
      if (stage === 'portal-login' && result.code === 0) { state.result = 'success'; return; }
      if (stage === 'portal-login' && result.code === 2) { state.result = 'captcha'; return; }
      const rejected = stage === 'portal-login' ? result.code === 1 || (result.code !== 0 && result.code !== 2 && !!result.msg) :
        stage === 'password-check' ? result.code === 1 : result.code !== 1 && result.code !== -1 && !!result.msg;
      if (rejected) {
        state.result = 'fail'; state.accountStage = stage;
        // Retain only a bounded error identifier, never response text or credentials.
        state.failureCode = typeof result.msg === 'string' ? result.msg.match(/\bE[0-9]{4,8}\b/)?.[0] || '' : '';
      }
    });
    state.accountObserved = true;
    return null;
  })();
  if (accountStatus) return accountStatus;

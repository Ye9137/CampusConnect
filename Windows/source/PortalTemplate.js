(() => {
  const cfg = /*CAMPUS_CONFIG*/;
  if (location.origin !== cfg.origin) return 'wrong-origin';
  const outcome = window.__campusSubmitAttempt?.result;
  const successPage = location.pathname === '/eportal/success.jsp' &&
    !!new URLSearchParams(location.search).get('userIndex');
  const zportalSuccess = /^\/zportal\/goToAuthResult\/?$/.test(location.pathname || '') && (() => {
    const form = document.querySelector('form#hidden_form[method="post"]');
    const logout = document.querySelector('#logout_submit');
    if (!form || !logout || !logout.getClientRects().length || document.querySelector('#login_submit')) return false;
    const action = new URL(form.action, location.href);
    return action.origin === cfg.origin && action.pathname === '/zportal/logout' &&
      ['userName','userIp','deviceIp'].every(name => form.querySelector('input[type="hidden"][name="'+name+'"]'));
  })();
  if (successPage || zportalSuccess || outcome === 'success') return 'authenticated';
  if (outcome === 'fail') return 'authentication-rejected';
  if (cfg.statusOnly) return window.__campusSubmitted ? 'awaiting-authentication' : 'not-submitted';
  const pending = cfg.confirmSubmit && window.__campusSubmitAttempt;
  if (pending && pending.failed) return 'submission-unconfirmed';
  if (window.__campusSubmitted) return 'already-submitted';
  if (pending && pending.handlerStarted) {
    if (pending.failed || Date.now() - pending.startedAt >= 8000) return 'submission-unconfirmed';
    return 'waiting-submit';
  }
  if (document.readyState === 'loading') return 'waiting-ready';
  const ready = window.__campusReady;
  if (ready && (ready.failed || !ready.pageInfo || !ready.getServices)) return 'waiting-ready';
  const visible = e => e && !e.disabled && e.getClientRects().length > 0;
  const editable = e => e instanceof HTMLInputElement && !e.disabled && !e.readOnly;
  let user, pass, submit, portalUser, portalPass, portalButton, zportalUser, zportalPass, zportalButton;
  const tipFor = input => input === portalUser ? document.querySelector('#username_tip') :
    input === portalPass ? document.querySelector('#pwd_tip') || document.querySelector('#passwordIn_1') : input === zportalPass ? input.form?.querySelector('input#tx[type="text"]') : null;
  const available = input => editable(input) && (visible(input) ||
    ((portalButton || zportalButton) && visible(tipFor(input))));
  try {
    // Ruijie ePortal displays readonly tips over hidden real inputs. Its login
    // control is an image-only anchor, so text/button heuristics cannot find it.
    portalUser = document.querySelector('#username');
    portalPass = document.querySelector('#pwd');
    portalButton = document.querySelector('#loginLink');
    if (!editable(portalUser) || portalUser.type !== 'text' ||
        !editable(portalPass) || portalPass.type !== 'password' || !portalButton) {
      portalUser = portalPass = portalButton = null;
    }
    // Inspected CMCC union page: use its original prompt and checkform handler.
    if (!portalButton) {
      const button = document.querySelector('#login_btn');
      const prompt = document.querySelector('#passwordIn_1');
      const account = document.querySelector('#username');
      const secret = document.querySelector('#pwd');
      if (editable(account) && account.type === 'text' && editable(secret) && secret.type === 'password' &&
          editable(prompt) && prompt.type === 'text' && /checkform\s*\(/.test(button?.getAttribute('onclick') || '') &&
          typeof window.checkform === 'function' && typeof window.hidePassword === 'function') {
        portalUser = account; portalPass = secret; portalButton = button;
      }
    }
    // Unknown ePortal variants retain full-load behavior; only inspected initialization is accelerated.
    if (portalButton && !ready && document.readyState !== 'complete') return 'waiting-ready';
    // Inspected zPortal uses #tx as a visible password prompt over #password.
    // Match the complete form so the separate QR-code login button is not chosen.
    const zform = document.querySelector('form#login_form');
    zportalUser = zform?.querySelector('input#user_name[name="username"]');
    zportalPass = zform?.querySelector('input#password[name="pwd"][type="password"]');
    zportalButton = zform?.querySelector('button#login_submit[type="button"]');
    if (!editable(zportalUser) || !editable(zportalPass) || !zportalButton ||
        zportalUser.form !== zform || zportalPass.form !== zform || zportalButton.form !== zform) {
      zportalUser = zportalPass = zportalButton = null;
    }
    pass = cfg.passwordSelector ? document.querySelector(cfg.passwordSelector) :
      portalPass || zportalPass || [...document.querySelectorAll('input[type="password"]')].find(e => editable(e) && visible(e));
    const root = pass && pass.form ? pass.form : document;
    user = cfg.userSelector ? document.querySelector(cfg.userSelector) : portalUser || zportalUser ||
      [...root.querySelectorAll('input:not([type="password"]):not([type="hidden"]):not([type="checkbox"]):not([type="radio"]):not([type="submit"]):not([type="button"])')]
      .filter(e => editable(e) && visible(e)).find(e => /user|account|student|phone|login|学号|账号|手机/i.test([e.name,e.id,e.placeholder,e.autocomplete].join(' ')));
    if (!user && !cfg.userSelector) user = [...root.querySelectorAll('input[type="text"],input[type="tel"],input[type="email"],input:not([type])')].find(e => editable(e) && visible(e));
    submit = cfg.submitSelector ? document.querySelector(cfg.submitSelector) : portalButton || zportalButton ||
      [...root.querySelectorAll('button,input[type="submit"],input[type="button"],a,[role="button"]')].filter(e => e.getClientRects().length > 0)
        .find(e => e.type === 'submit' || /^(登录|登陆|认证|连接|login|log in|sign in|connect)(\s*(login|登录|登陆))?$/i.test((e.innerText || e.value || '').trim()));
  } catch (_) { return 'invalid-selector'; }
  if (!available(user) || !available(pass)) return 'missing-fields';
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
  for (const [input, value] of [[user,cfg.username],[pass,cfg.password]]) {
    if (input === portalPass && portalButton?.id === 'login_btn' && visible(tipFor(input))) tipFor(input).click();
    if (!visible(input)) {
      const tip = tipFor(input);
      if (visible(tip)) {
        tip.focus();
        // Background WebViews may not deliver native focus. Invoke the school's
        // own reveal handlers without taking OS focus or changing its DOM styles.
        if (!visible(input) && visible(tip)) tip.dispatchEvent(new FocusEvent('focus'));
        if (!visible(input) && visible(tip)) tip.dispatchEvent(new FocusEvent('focusin', {bubbles:true}));
        if (!visible(input) && visible(tip)) tip.click();
      }
    }
    if (!editable(input) || !visible(input)) return 'missing-fields';
    if (!cfg.confirmSubmit || input.value !== value) {
      setter.call(input, value);
      input.dispatchEvent(new Event('input', {bubbles:true}));
      input.dispatchEvent(new Event('change', {bubbles:true}));
    }
  }
  // A service mismatch pauses submission, but must not skip the independent
  // network pledge. Keep the school's service handlers before agreement checks.
  const serviceStatus = (() => {
    const serviceName = (cfg.serviceOption || '').trim();
    // Some portals place the operator dropdown outside the credentials form.
    // Include unassociated controls, but never select a service in another form.
    const serviceSelects = [...document.querySelectorAll('select')]
      .filter(select => visible(select) && !select.multiple && (!select.form || select.form === pass.form));
    const servicePlaceholder = text => /^(请)?选择((运营商|服务)(选项)?|选项)[：:….。]*$/.test((text || '').replace(/\s/g, ''));
    const serviceText = control => (control instanceof HTMLInputElement ? control.value || control.placeholder : control.textContent || '').trim();
    const serviceDescriptor = control => [control.id, control.getAttribute('name'), control.getAttribute('aria-label'),
      control.getAttribute('aria-controls'), ...(control.getAttribute('aria-labelledby') || '').split(/\s+/)
        .map(id => document.getElementById(id)?.textContent || '')].join(' ');
    const serviceOpeners = [...document.querySelectorAll('[role="combobox"],[aria-haspopup],[aria-controls],button,[role="button"]')]
      .filter(control => !(control instanceof HTMLSelectElement) && visible(control) &&
        control.getAttribute('aria-disabled') !== 'true' && (!control.closest('form') || control.closest('form') === pass.form) &&
        (servicePlaceholder(serviceText(control)) || window.__campusCustomServiceMenus?.has(control) ||
          (control.matches('[role="combobox"],[aria-haspopup]') &&
            (serviceText(control) === serviceName || /运营商|服务|operator|carrier|service/i.test(serviceDescriptor(control))))));
    for (const opener of serviceOpeners) window.__campusRegisterServiceMenu?.(opener);
    const eportalOpener = document.querySelector('#serviceShowHideTop');
    window.__campusRegisterServiceMenu?.(eportalOpener);
    if (!serviceName && (serviceSelects.some(select => servicePlaceholder(select.selectedOptions[0]?.textContent)) ||
        serviceOpeners.some(control => servicePlaceholder(serviceText(control))))) {
      return 'service-required';
    }
    if (serviceName) {
      const normalized = text => (text || '').trim();
      const serviceValue = document.querySelector('#net_access_type');
      const serviceLabel = document.querySelector('#selectDisname');
      if (portalButton && serviceValue && serviceLabel && !(serviceValue instanceof HTMLSelectElement)) {
        // Use the school's existing menu click handlers, including domain/operator updates.
        // Opening the menu can lazily fetch services for the account just filled above.
        if (normalized(serviceLabel.textContent) !== serviceName || !serviceValue.value) {
          const opener = document.querySelector('#serviceShowHideTop');
          const opened = window.__campusServiceMenus ||= new WeakMap();
          if (visible(opener) && opened.get(opener) !== cfg.username) {
            opened.set(opener, cfg.username);
            opener.click();
          }
          const choices = [...document.querySelectorAll('#serviceShowHide [id^="bch_service_"]')]
            .filter(row => visible(row) && row.getAttribute('aria-disabled') !== 'true' &&
              normalized((row.querySelector('[id^="_service_"]') || row).textContent) === serviceName);
          if (choices.length !== 1) return 'missing-service';
          choices[0].click();
          if (normalized(serviceLabel.textContent) !== serviceName || !serviceValue.value) return 'missing-service';
        }
        window.__campusCollapseServiceMenu?.(eportalOpener);
      } else {
        // Operator choices can also be horizontal native or accessible radios,
        // including controls placed above and outside the credentials form.
        const radios = [...document.querySelectorAll('input[type="radio"],[role="radio"]')];
        const radioChoices = radios.filter(control => {
          if (!(control instanceof HTMLInputElement) && control.querySelector('input[type="radio"]')) return false;
          const form = control.form || control.closest('form');
          if (form && form !== pass.form) return false;
          if (control.matches(':disabled') || control.closest('[aria-disabled="true"]')) return false;
          const labels = [...(control.labels || [])];
          const wrapper = control.closest('label,[role="radio"]');
          if (wrapper && !labels.includes(wrapper)) labels.push(wrapper);
          for (const id of (control.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean)) {
            const label = document.getElementById(id);
            if (label) labels.push(label);
          }
          if (!visible(control) && !labels.some(visible)) return false;
          const names = [control.getAttribute('aria-label'), ...labels.map(label => label.textContent)];
          if (control.getAttribute('role') === 'radio') names.push(control.textContent);
          // Older pages use bare text or FONT/SPAN text after each input.
          // Localization comments and indentation can sit between the two.
          let sibling = control.nextSibling;
          while (sibling && (sibling.nodeType === 8 ||
              (sibling.nodeType === 3 && !normalized(sibling.textContent)))) sibling = sibling.nextSibling;
          if (sibling?.nodeType === 3) names.push(sibling.textContent);
          if (sibling?.nodeType === 1 && sibling.matches('font,span,label') &&
              !sibling.querySelector('input,button,[role="radio"]')) names.push(sibling.textContent);
          return names.some(name => normalized(name) === serviceName);
        });
        const choices = serviceSelects
          .flatMap(select => [...select.options].filter(option => !option.disabled &&
            !(option.parentElement instanceof HTMLOptGroupElement && option.parentElement.disabled) &&
            normalized(option.textContent) === serviceName).map(option => ({select, option})));
        if (choices.length + radioChoices.length > 1) return 'missing-service';
        if (radioChoices.length === 1) {
          const radio = radioChoices[0];
          const checked = () => radio instanceof HTMLInputElement ? radio.checked : radio.getAttribute('aria-checked') === 'true';
          if (!checked()) {
            const previous = window.__campusServiceRadioAttempt;
            if (!previous || previous.control !== radio || previous.username !== cfg.username || previous.serviceName !== serviceName) {
              window.__campusServiceRadioAttempt = {control:radio, username:cfg.username, serviceName};
              // Click through the school's handler; setting checked alone skips
              // account-domain updates and other operator-specific page logic.
              radio.click();
            }
          }
          if (!radio.isConnected || !checked() || radio.matches(':disabled') ||
              radio.closest('[aria-disabled="true"]')) return 'missing-service';
        } else if (choices.length === 1) {
          const {select, option} = choices[0];
          if (select.selectedIndex !== option.index) {
            select.selectedIndex = option.index;
            select.dispatchEvent(new Event('input', {bubbles:true}));
            select.dispatchEvent(new Event('change', {bubbles:true}));
          }
          if (select.selectedOptions[0] !== option || select.disabled) return 'missing-service';
          select.blur();
        } else {
          // Custom portals may create their choices only after opening the menu.
          // Match the configured visible name, without a fixed carrier/value list.
          if (serviceOpeners.length !== 1) return 'missing-service';
          const opener = serviceOpeners[0];
          if (serviceText(opener) !== serviceName) {
            const opened = window.__campusCustomServiceMenus ||= new WeakMap();
            const previous = opened.get(opener);
            if ((!previous || previous.username !== cfg.username || previous.serviceName !== serviceName) &&
                opener.getAttribute('aria-expanded') !== 'true') {
              opened.set(opener, {username:cfg.username, serviceName});
              opener.click();
            }
            const popupIds = (opener.getAttribute('aria-controls') || opener.getAttribute('aria-owns') || '').split(/\s+/).filter(Boolean);
            const popups = popupIds.length ? popupIds.map(id => document.getElementById(id)).filter(Boolean) :
              [...document.querySelectorAll('[role="listbox"],[role="menu"]')];
            const options = [...new Set(popups.filter(visible).flatMap(popup =>
              [...popup.querySelectorAll('[role="option"],[role="menuitem"],[role="menuitemradio"],li,button')]))]
              .filter(option => visible(option) && !option.closest('[aria-disabled="true"],[disabled]') &&
                normalized(option.textContent) === serviceName);
            if (options.length !== 1) return 'missing-service';
            options[0].click();
            if (serviceText(opener) !== serviceName && options[0].getAttribute('aria-selected') !== 'true' &&
                options[0].getAttribute('aria-checked') !== 'true') return 'missing-service';
          }
          window.__campusCollapseServiceMenu?.(opener);
        }
      }
    }
    return null;
  })();
  /*CAMPUS_AGREEMENTS*/
  if (serviceStatus) return serviceStatus;
  // School handlers can reject/reset a value; never report success or submit it.
  if (!editable(user) || !editable(pass) || !visible(user) || !visible(pass) ||
      user.value !== cfg.username || pass.value !== cfg.password) return 'missing-fields';
  /*CAMPUS_CAPTCHA*/
  if (!cfg.submit) return 'filled';
  if (!visible(submit)) return 'missing-submit';
  if (portalButton && /doauthen/.test(submit.getAttribute('onclick') || '') &&
      typeof window.doauthen !== 'function') return 'waiting-ready';
  // Captchas and extra operator fields need the user's input; don't burn a login attempt.
  if (portalButton && ['#validCode','#operatorUserId','#operatorPwd'].some(selector => {
    const input = document.querySelector(selector);
    return visible(input) && !input.value.trim();
  })) return 'manual-required';
  // WKWebView can finish filling before the page handles its first activation.
  // Observe only the known school's own login flow; never call its API ourselves.
  if (cfg.confirmSubmit && submit === portalButton && /doauthen/.test(submit.getAttribute('onclick') || '')) {
    if (typeof window.AuthInterFace?.login !== 'function') return 'waiting-ready';
    const state = window.__campusSubmitAttempt ||= {clicks:0, prepared:false, handlerStarted:false, failed:false};
    const observe = (owner, key, flag) => {
      if (owner[key] === state[key]) return;
      const original = owner[key];
      const wrapped = function(...args) {
        if (flag === 'login') {
          window.__campusSubmitted = true;
          // Observe the school's response without replacing its request or callback.
          const last = args.length - 1;
          if (typeof args[last] === 'function') {
            const callback = args[last];
            args[last] = function(result, ...rest) {
              if (result?.result === 'success') state.result = 'success';
              else if (result?.result === 'fail') state.result = 'fail';
              return callback.call(this, result, ...rest);
            };
          }
        }
        else { state.handlerStarted = true; state.startedAt = Date.now(); }
        try { return original.apply(this, args); }
        catch (error) { state.failed = true; throw error; }
      };
      state[key] = wrapped; owner[key] = wrapped;
    };
    observe(window, 'doauthen', 'handler');
    observe(window.AuthInterFace, 'login', 'login');
    if (!state.prepared || state.button !== submit || state.user !== user || state.pass !== pass) {
      state.prepared = true; state.button = submit; state.user = user; state.pass = pass;
      if (document.activeElement === user || document.activeElement === pass) document.activeElement.blur();
      submit.focus();
      // Let blur/change handlers and layout finish before rechecking the values.
      return 'waiting-submit';
    }
    if (state.clicks >= 2) {
      // Both click events were lost: invoke the same page handler once. All
      // school validation/encryption/service logic remains in that handler.
      try { window.doauthen.call(submit); } catch (_) { state.failed = true; }
      if (state.failed) return 'submission-unconfirmed';
      return window.__campusSubmitted ? 'submitted' : 'waiting-submit';
    }
    state.clicks++;
    try {
      if (state.clicks === 1) submit.click();
      else submit.dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true, view:window}));
    } catch (_) { state.failed = true; }
    if (state.failed) return 'submission-unconfirmed';
    if (window.__campusSubmitted) return 'submitted';
    // A second activation is allowed only if the school's handler never ran.
    return 'waiting-submit';
  }
  window.__campusSubmitted = true;
  submit.click();
  return 'submitted';
})()

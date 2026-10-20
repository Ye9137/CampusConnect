  // Runs only after the native connection check and the saved-origin gate.
  const captchaStatus = (() => {
    const fields = [...document.querySelectorAll('input')].filter(input => (!input.form || input.form === pass.form) && input !== user && input !== pass &&
      visible(input) && !input.readOnly && /^(text|tel|number|search)$/.test(input.type) &&
      /captcha|valid[_-]?code|verify[_-]?code|check[_-]?code|验证码/i.test(
        [input.id, input.name, input.placeholder, input.getAttribute('aria-label'), input.getAttribute('formcontrolname'),
          ...[...(input.labels || [])].map(label => label.textContent)].join(' ')));
    const needsCode = input => !input.value.trim() || (input.form?.id === 'login_form' &&
      input.id === 'valid_code' && input.name === 'validCode' && input.value.trim() === '验证码');
    if (!fields.length) return null;
    if (fields.length !== 1) return fields.some(needsCode) ? 'manual-required' : null;
    const input = fields[0];
    if (!needsCode(input)) return null;
    const namedImages = [...document.querySelectorAll('img')].filter(image => visible(image) &&
      /captcha|valid[_-]?code|verify[_-]?(code|img|image)|验证码/i.test(
        [image.id, image.className, image.alt, image.getAttribute('src')?.startsWith('data:') ? '' : image.getAttribute('src')].join(' ')));
    let image = namedImages.length === 1 ? namedImages[0] : null;
    if (!image) {
      for (let parent = input.parentElement, depth = 0; parent && depth < 3; parent = parent.parentElement, depth++) {
        const images = [...parent.querySelectorAll('img')].filter(visible);
        if (images.length === 1) { image = images[0]; break; }
        if (parent === pass.form || images.length > 1) break;
      }
    }
    if (!image) return 'manual-required';
    if (window.__campusCaptcha?.input === input && window.__campusCaptcha.image === image &&
        !window.__campusCaptcha.stale && !window.__campusCaptcha.used && window.__campusCaptcha.matches?.()) return 'captcha-required';
    const expectedUser = user.value, expectedPassword = pass.value, expectedImageSource = image.getAttribute('src');
    // Use the original response bytes only when this is the image the page is displaying.
    // Keep the choice fixed for this challenge, even if a response arrives after the dialog opens.
    const apiImage = window.__campusCaptchaApiImage;
    const fromResponse = typeof apiImage === 'string' && apiImage === expectedImageSource;
    const numericOnly = input.type === 'number' || input.inputMode === 'numeric' ||
      /^(?:\[0-9\]|\\d)(?:[+*]|\{\d+(?:,\d*)?\})$/.test(input.pattern);
    const state = {input, image, stale:false, used:false, ticket:Date.now().toString(36) + Math.random().toString(36).slice(2)};
    state.matches = () => user.isConnected && pass.isConnected && user.value === expectedUser && pass.value === expectedPassword &&
      image.getAttribute('src') === expectedImageSource;
    const pixels = () => {
      if (image.getAttribute('src') !== expectedImageSource || !image.complete || !image.naturalWidth || image.naturalWidth > 1024 || image.naturalHeight > 512) return null;
      if (fromResponse) return apiImage;
      try {
        const canvas = document.createElement('canvas');
        canvas.width = image.naturalWidth; canvas.height = image.naturalHeight;
        const context = canvas.getContext('2d');
        context.fillStyle = 'white'; context.fillRect(0, 0, canvas.width, canvas.height);
        context.drawImage(image, 0, 0);
        const data = canvas.toDataURL('image/png');
        return data.length <= 1500000 ? data : null;
      } catch (_) { return null; }
    };
    state.read = () => {
      if (state.stale || !input.isConnected || !image.isConnected) return null;
      const data = pixels();
      if (!data) return null;
      state.captured = data;
      const length = input.maxLength > 0 && input.maxLength <= 12 ? input.maxLength : 0;
      return {ticket:state.ticket, image:data, length, numericOnly, autoSubmit:!!cfg.submit, source:fromResponse ? 'response' : 'page'};
    };
    state.commit = (ticket, code) => {
      if (location.origin !== cfg.origin || state.ticket !== ticket || state.used || state.stale ||
          !input.isConnected || !image.isConnected || !visible(input) || input.readOnly ||
          !state.matches() || state.captured !== pixels()) return 'captcha-stale';
      if (typeof code !== 'string' || !(numericOnly ? /^[0-9]{1,12}$/ : /^[A-Za-z0-9]{1,12}$/).test(code) ||
          (input.maxLength > 0 && input.maxLength <= 12 && code.length !== input.maxLength)) return 'captcha-invalid';
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, code);
      input.dispatchEvent(new Event('input', {bubbles:true}));
      input.dispatchEvent(new Event('change', {bubbles:true}));
      if (input.value !== code || state.stale) return 'captcha-stale';
      if (!cfg.submit) { state.used = true; return 'filled'; }
      if (!submit?.isConnected || !visible(submit)) return 'missing-submit';
      state.used = true;
      window.__campusSubmitted = true;
      submit.click();
      return 'submitted';
    };
    image.addEventListener('load', () => { if (state.captured) state.stale = true; });
    window.__campusCaptcha = state;
    return 'captcha-required';
  })();
  if (captchaStatus) return captchaStatus;

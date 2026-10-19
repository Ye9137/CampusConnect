  // Activate required login checkboxes through school handlers.
  // The caller has already checked network/origin and identified the login inputs.
  {
    const root = pass.form || document;
    const attempted = window.__campusAgreementAttempts ||= new WeakMap();
    const candidates = [...root.querySelectorAll('input[type="checkbox"],[role="checkbox"]')]
      .filter(box => box instanceof HTMLInputElement ? box.type === 'checkbox' : box.getAttribute?.('role') === 'checkbox');
    for (const box of candidates) {
      if (box.form && box.form !== pass.form) continue;
      const labels = [...(box.labels || [])];
      const wrapper = box.closest('label,[role=checkbox],.checkbox,.agreement,.protocol');
      if (wrapper && !labels.includes(wrapper)) labels.push(wrapper);
      for (const id of (box.getAttribute('aria-labelledby') || '').split(/\s+/)) {
        const label = document.getElementById(id);
        if (label) labels.push(label);
      }
      // Older portals put pledge text in a plain DIV, FONT or text node rather
      // than a LABEL. Keep context local so another checkbox cannot donate its text.
      const controls = 'input,select,textarea,button,[role="checkbox"],[role="button"]';
      for (let parent = box.parentElement, depth = 0; parent && depth < 3; parent = parent.parentElement, depth++) {
        if (/^(FORM|BODY|HTML)$/.test(parent.tagName)) break;
        const peers = [...parent.querySelectorAll(controls)];
        if (peers.length !== 1 || peers[0] !== box) break;
        if (parent.textContent.trim()) { labels.push(parent); break; }
      }
      const nearby = [];
      for (const direction of labels.some(label => label.textContent.trim()) ? [] : ['nextSibling', 'previousSibling']) {
        for (let node = box[direction], count = 0; node && count < 8; node = node[direction], count++) {
          if (node.nodeType === 8) continue;
          if (node.nodeType === 3) { nearby.push(node.textContent); continue; }
          if (node.nodeType !== 1 || !/^(SPAN|FONT|A|SMALL|STRONG|EM|I|B)$/.test(node.tagName) ||
              node.matches(controls) || node.querySelector(controls)) break;
          nearby.push(node.textContent);
        }
        if (nearby.some(text => text.trim())) break;
      }
      const text = [box.getAttribute('aria-label'), ...labels.map(label => label.textContent),
        ...nearby, box.getAttribute('role') === 'checkbox' ? box.textContent : '', box.id, box.name].join(' ');
      if (/记住|自动登录|保持登录|订阅|推广|广告|促销|营销|优惠|newsletter|marketing|remember|stay\s+signed/i.test(text)) continue;
      const agreement = /同意|已阅读|阅读并|服务(?:使用)?协议|用户协议|隐私政策|使用条款|\bagree\b|\baccept\b|\bterms\b|\bprivacy\b/i.test(text) ||
        /(?:本人)?承诺.{0,32}(?:遵守|上网|网络)|遵守.{0,80}(?:网络安全法|法律法规|网络管理|网络道德)|网络(?:安全|使用|接入|行为)(?:协议|规定|规范|承诺|守则)/.test(text.replace(/\s+/g, ''));
      if (!box.required && box.getAttribute('aria-required') !== 'true' && !agreement) continue;
      if (!visible(box) && !labels.some(visible)) continue;
      const checked = () => box instanceof HTMLInputElement ? box.checked : box.getAttribute('aria-checked') === 'true';
      if (checked()) continue;
      if (box.disabled || box.getAttribute('aria-disabled') === 'true') return 'agreement-required';
      const previous = attempted.get(box);
      if (previous) return Date.now() - previous.started < 2000 ? 'waiting-agreement' : 'agreement-required';
      attempted.set(box, { started: Date.now() });
      box.click();
      if (!checked()) return 'waiting-agreement';
    }
  }

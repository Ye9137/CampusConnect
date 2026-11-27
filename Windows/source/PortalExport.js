// Evaluated only when the user requests an export in the native application's portal view.
(() => {
  const pages = [], notes = [], handlers = [], handlerIds = new Map();
  const knownEvents = typeof getEventListeners === 'function' ? getEventListeners : null;
  const allowed = /^(?:id|class|name|type|role|for|form|method|target|rel|media|title|alt|placeholder|disabled|required|multiple|hidden|checked|selected|tabindex|style|slot|part|autocomplete|aria-(?:label|labelledby|controls|expanded|disabled|checked|pressed)|data-(?:action|target|toggle|role|type)|on[a-z]+)$/i;
  const structural = /^(?:width|height|rows|cols|size|pattern|maxlength|minlength|min|max|step|readonly|autofocus|enctype|formmethod|formenctype|formnovalidate|novalidate|async|defer|nomodule|crossorigin|integrity|loading|decoding|dir|lang|scope|colspan|rowspan|open|popover|popovertarget|list|xmlns|aria-[a-z-]+|data-(?:testid|test-id|bs-(?:toggle|target)|v-[a-f\d]+)|_ng(?:content|host)-[a-z\d-]+)$/i;
  const vector = /^(?:d|points|viewbox|preserveaspectratio|x|y|x1|y1|x2|y2|cx|cy|r|rx|ry|dx|dy|fill|fill-rule|fill-opacity|stroke(?:-[a-z]+)*|opacity|transform|offset|stop-color|stop-opacity|gradientunits|gradienttransform|clip-path|clip-rule|mask|filter|stddeviation|marker(?:-[a-z]+)*|pathlength|vector-effect|text-anchor|dominant-baseline)$/i;
  const urlAttrs = new Set(['href','src','action','formaction','poster','xlink:href']);
  const url = (value, base) => {
    try {
      const u = new URL(value, base);
      if (/^data:(?:image|font|audio|video)\//i.test(value) || /^data:(?:text\/(?:css|javascript)|application\/(?:javascript|wasm))[,;]/i.test(value)) return value;
      if (u.protocol === 'blob:') return u.href;
      return /^https?:$/.test(u.protocol) ? u.origin + u.pathname : '';
    } catch { return ''; }
  };
  function events(target) {
    const result = {};
    if (!knownEvents) return result;
    for (const [name, entries] of Object.entries(knownEvents(target))) {
      const ids = [];
      for (const entry of entries) {
        if (typeof entry.listener !== 'function') continue;
        const code = Function.prototype.toString.call(entry.listener);
        if (!handlerIds.has(code)) {
          handlerIds.set(code, handlers.length);
          handlers.push(code);
        }
        ids.push(handlerIds.get(code));
      }
      if (ids.length) result[name] = ids;
    }
    return result;
  }
  function labelText(el) {
    if (!el || el.isContentEditable) return '';
    const walk = el.ownerDocument.createTreeWalker(el, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        if (node.nodeType === 3) return NodeFilter.FILTER_ACCEPT;
        return node.matches('input,textarea,select,script,style,[contenteditable]') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP;
      }
    });
    let text = '';
    while (text.length < 160 && walk.nextNode()) text += walk.currentNode.data.slice(0,160);
    return text.trim().replace(/\s+/g,' ').slice(0,160);
  }
  function collect(doc, context) {
    const references = new Map();
    function reference(address, type) {
      if (address && /^(?:https?:|blob:|data:)/i.test(address)) references.set(address,type);
    }
    for (const entry of doc.defaultView.performance.getEntriesByType('resource')) {
      const path = entry.name.split(/[?#]/,1)[0];
      const kind = {script:'Script', img:'Image', image:'Image', audio:'Media', video:'Media'}[entry.initiatorType];
      if (kind) reference(entry.name,kind);
      else if (/\.(?:m?js|cjs)$/i.test(path)) reference(entry.name,'Script');
      else if (/\.css$/i.test(path)) reference(entry.name,'Stylesheet');
      else if (/\.(?:woff2?|ttf|otf|eot)$/i.test(path)) reference(entry.name,'Font');
      else if (/\.wasm$/i.test(path)) reference(entry.name,'Wasm');
    }
    for (const script of doc.querySelectorAll('script[src]')) reference(script.src,'Script');
    for (const link of doc.querySelectorAll('link[href]')) {
      if (link.relList.contains('stylesheet')) reference(link.href,'Stylesheet');
      if (link.relList.contains('modulepreload')) reference(link.href,'Script');
      if (link.relList.contains('manifest')) reference(link.href,'Manifest');
    }
    // Raw addresses are used only to locate the browser's cached resource; they are not written to the index.
    const page = {context, documentAddress:doc.URL, references:[...references], url:url(doc.URL, doc.baseURI), controls:[], listeners:[], styles:[], html:''};
    pages.push(page);
    const inert = document.implementation.createHTMLDocument('');
    function captureStyles(root, scope) {
      // CSSOM edits and constructed stylesheets need not have a corresponding HTML node or network body.
      const sheets = new Set([...(root.styleSheets || []), ...(root.adoptedStyleSheets || [])]);
      for (const sheet of sheets) {
        try {
          page.styles.push({scope, source:sheet.href ? url(sheet.href, doc.baseURI) : null,
            css:Array.from(sheet.cssRules, rule=>rule.cssText).join('\n')});
        } catch {
          notes.push('浏览器限制读取样式规则：' + (sheet.href ? url(sheet.href, doc.baseURI) : scope));
        }
      }
    }
    captureStyles(doc, 'document');
    function visit(el, path) {
      const tag = el.localName;
      const copy = inert.createElementNS(el.namespaceURI, tag);
      for (const attr of el.attributes) {
        const key = attr.name.toLowerCase();
        if (urlAttrs.has(key)) {
          const clean = key === 'href' && /^\s*javascript:/i.test(attr.value) ? attr.value : url(attr.value, el.baseURI);
          if (key.endsWith('href') && /^#[\w:.-]+$/.test(attr.value)) copy.setAttribute(key,attr.value);
          else if (clean) copy.setAttribute(key, clean);
        } else if (allowed.test(key) || structural.test(key) ||
                   (el.namespaceURI === 'http://www.w3.org/2000/svg' && vector.test(key)) || (key === 'value' && (tag === 'option' ||
                   (tag === 'input' && ['button','submit','reset','radio','checkbox'].includes(el.type))))) {
          copy.setAttribute(attr.name, attr.value);
        } else if (/^data-[a-z0-9_-]+$/i.test(key)) {
          copy.setAttribute(key, '');
        }
      }
      const bound = events(el);
      if (Object.keys(bound).length) page.listeners.push({path, events:bound});
      const editable = el.isContentEditable || el.hasAttribute('contenteditable');
      if (el.matches('button,input,select,textarea,form,a[href],label,[role=button],[onclick],[tabindex]') || Object.keys(bound).length) {
        const label = copy.getAttribute('aria-label') || copy.getAttribute('placeholder') ||
          (tag === 'input' ? copy.getAttribute('value') : null) ||
          labelText(el.labels?.[0]) || (!editable && el.matches('button,a,label,[role=button]') ? labelText(el) : '');
        page.controls.push({path, tag, id:el.id, name:el.getAttribute('name'), type:el.getAttribute('type'), label,
          inline:Object.fromEntries([...copy.attributes].filter(a=>/^on/i.test(a.name) || (a.name==='href' && /^\s*javascript:/i.test(a.value))).map(a=>[a.name,a.value])), events:bound});
      }
      if (tag === 'iframe' || tag === 'frame') {
        if (el.contentDocument?.documentElement) collect(el.contentDocument, context + ' / ' + path);
        else notes.push('无法读取内嵌页：' + (copy.getAttribute('src') || path));
      }
      if (tag === 'script' && el.type === 'importmap') {
        // Keep module names and resolved paths; discard URL query parameters.
        try {
          const spec = JSON.parse(el.textContent);
          function mappings(map) {
            return Object.fromEntries(Object.entries(map || {}).map(([key,v])=>[key, typeof v === 'string' ? url(v,el.baseURI) : null]));
          }
          copy.textContent = JSON.stringify({imports:mappings(spec.imports),scopes:Object.fromEntries(
            Object.entries(spec.scopes || {}).map(([key,v])=>[url(key,el.baseURI),mappings(v)]))},null,2);
        } catch { notes.push('无法解析 importmap：' + path); }
        return copy;
      }
      if (editable || ['textarea','noscript'].includes(tag)) return copy;
      if (tag === 'script' && el.type && !/^(module|(?:text|application)\/(?:java|ecma)script)$/i.test(el.type)) return copy;
      function children(source, dest, prefix) {
        let index = 0;
        for (const child of source.childNodes) {
          if (child.nodeType === 1) {
            ++index;
            dest.append(visit(child, prefix + ' > ' + child.localName + ':nth-child(' + index + ')'));
          } else if (child.nodeType === 3) dest.append(inert.createTextNode(child.data));
        }
      }
      if (tag === 'template' && el.content) children(el.content, copy.content, path);
      else children(el, copy, path);
      if (el.shadowRoot) {
        captureStyles(el.shadowRoot, path + ' ::shadow');
        const template = inert.createElement('template');
        template.setAttribute('shadowrootmode','open');
        children(el.shadowRoot, template.content, path + ' ::shadow');
        copy.append(template);
        const boundRoot = events(el.shadowRoot);
        if (Object.keys(boundRoot).length) page.listeners.push({path:path+' ::shadow', events:boundRoot});
      }
      return copy;
    }
    for (const [label,target] of [['window',doc.defaultView],['document',doc]]) {
      const bound = events(target);
      if (Object.keys(bound).length) page.listeners.push({path:label, events:bound});
    }
    page.html = '<!DOCTYPE html>\n' + visit(doc.documentElement,'html').outerHTML;
  }
  collect(document,'main');
  if (!knownEvents) notes.push('此浏览器未提供动态监听器列表');
  return {pages,handlers,notes};
})()

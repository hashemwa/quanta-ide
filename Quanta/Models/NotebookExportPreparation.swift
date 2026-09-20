import Foundation

extension NotebookExporter {
    static let preparationScript = #"""
    (() => {
      const ready = new Set();
      let checkPlots = () => {};
      let plotError = false;
      window.addEventListener('message', event => {
        const frames = Array.from(document.querySelectorAll('iframe[data-quanta-plot]'));
        if (!frames.some(frame => frame.contentWindow === event.source)) return;
        if (event.data?.type === 'quanta-plot-ready') ready.add(event.source);
        if (event.data?.type === 'quanta-plot-error') plotError = true;
        checkPlots();
      });
      const allowed = new Set('P DIV SPAN B STRONG I EM U S BR HR PRE CODE BLOCKQUOTE UL OL LI TABLE CAPTION THEAD TBODY TFOOT TR TH TD H1 H2 H3 H4 H5 H6 A IMG SUP SUB DL DT DD DETAILS SUMMARY'.split(' '));
      const blocked = new Set('SCRIPT STYLE IFRAME OBJECT EMBED LINK META BASE FORM INPUT BUTTON TEXTAREA SELECT VIDEO AUDIO SVG TEMPLATE'.split(' '));
      function clean(node, depth = 0) {
        if (node.nodeType === Node.TEXT_NODE) return document.createTextNode(node.textContent);
        if (node.nodeType !== Node.ELEMENT_NODE || blocked.has(node.tagName)) return document.createDocumentFragment();
        if (depth > 64) return document.createTextNode(node.textContent);
        const result = allowed.has(node.tagName) ? document.createElement(node.tagName.toLowerCase()) : document.createDocumentFragment();
        if (node.tagName === 'IMG' && /^data:image\/(png|jpeg|gif|webp|svg\+xml);base64,/i.test(node.getAttribute('src') || '')) {
          result.setAttribute('src', node.getAttribute('src'));
          result.setAttribute('alt', node.getAttribute('alt') || 'Notebook output');
        }
        if (node.tagName === 'A') {
          const href = node.getAttribute('href') || '';
          if (/^(https?:|mailto:)/i.test(href)) { result.setAttribute('href', href); result.setAttribute('rel', 'noreferrer'); }
        }
        if (node.tagName === 'TD' || node.tagName === 'TH') {
          for (const name of ['colspan', 'rowspan']) {
            const value = Number(node.getAttribute(name));
            if (Number.isInteger(value) && value > 0 && value <= 1000) result.setAttribute(name, String(value));
          }
        }
        for (const child of node.childNodes) result.appendChild(clean(child, depth + 1));
        return result;
      }
      window.quantaExportReady = new Promise((resolve, reject) => {
        const deadline = setTimeout(() => reject(new Error('Notebook outputs did not finish rendering')), 25000);
        window.addEventListener('load', async () => {
          try {
            for (const frame of document.querySelectorAll('iframe[data-quanta-static]')) {
              const html = new TextDecoder().decode(Uint8Array.from(atob(frame.dataset.quantaStatic), c => c.charCodeAt(0)));
              const parsed = new DOMParser().parseFromString(html, 'text/html');
              const container = document.createElement('div');
              container.className = 'rich-output';
              for (const child of parsed.body.childNodes) container.appendChild(clean(child));
              frame.replaceWith(container);
            }
            await document.fonts.ready;
            await Promise.all(Array.from(document.images).map(img => img.decode().catch(() => {})));
            await new Promise((done, failed) => {
              checkPlots = () => {
                if (plotError) { failed(new Error('A plot could not be rendered')); return; }
                if (Array.from(document.querySelectorAll('iframe[data-quanta-plot]')).every(frame => ready.has(frame.contentWindow))) done();
              };
              checkPlots();
            });
            void document.body.offsetHeight;
            clearTimeout(deadline);
            resolve(true);
          } catch (error) { clearTimeout(deadline); reject(error); }
        }, {once:true});
      });
      window.quantaExportReady.catch(() => {});
    })();
    """#
}

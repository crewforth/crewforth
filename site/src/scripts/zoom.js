// A picture in a page opens at its full size when it is pressed, and closes on a press, Escape or its button.
//
// The pictures of the panel are drawn at 900 px in a column and are two to four times that wide: at the size of the
// column their text cannot be read. No library and no request to anywhere: the picture shown large is the file the
// page already loaded. A picture inside a link keeps its link.
(() => {
  const tr = document.documentElement.lang === 'tr';
  const WORD = tr ? { open: 'Görseli büyüt', close: 'Kapat' } : { open: 'Enlarge the picture', close: 'Close' };
  let dialog = null;

  function show(img) {
    if (!dialog) {
      dialog = document.createElement('dialog');
      dialog.className = 'cf-zoom';
      dialog.innerHTML = '<button type="button" class="cf-zoom-close"></button><img alt="">';
      dialog.querySelector('button').setAttribute('aria-label', WORD.close);
      dialog.querySelector('button').textContent = '×';
      // A press anywhere closes it: on the picture, beside it, or on the button.
      dialog.addEventListener('click', () => dialog.close());
      document.body.append(dialog);
    }
    const big = dialog.querySelector('img');
    big.src = img.currentSrc || img.src;
    big.alt = img.alt;
    dialog.showModal();
  }

  for (const img of document.querySelectorAll('.sl-markdown-content img')) {
    if (img.closest('a')) continue;
    img.classList.add('cf-zoomable');
    img.tabIndex = 0;
    img.setAttribute('role', 'button');
    img.setAttribute('aria-label', `${WORD.open}: ${img.alt}`);
    img.addEventListener('click', () => show(img));
    img.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); show(img); } });
  }
})();

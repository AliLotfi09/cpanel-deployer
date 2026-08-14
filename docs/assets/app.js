(() => {
  const root = document.documentElement;
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const themeToggle = document.getElementById('themeToggle');
  const themeMeta = document.querySelector('meta[name="theme-color"]');

  const setTheme = (theme) => {
    root.dataset.theme = theme;
    localStorage.setItem('rahsepar-theme-v3', theme);
    const light = theme === 'light';
    themeMeta?.setAttribute('content', light ? '#f7f8fa' : '#0d1015');
    if (themeToggle) {
      themeToggle.textContent = light ? '◐' : '☼';
      themeToggle.title = light ? 'پوسته تیره' : 'پوسته روشن';
      themeToggle.setAttribute('aria-label', light ? 'فعال کردن پوسته تیره' : 'فعال کردن پوسته روشن');
    }
  };

  const savedTheme = localStorage.getItem('rahsepar-theme-v3') || localStorage.getItem('rahsepar-theme-v2');
  setTheme(savedTheme === 'dark' ? 'dark' : 'light');
  themeToggle?.addEventListener('click', () => setTheme(root.dataset.theme === 'dark' ? 'light' : 'dark'));

  const sidebar = document.getElementById('sidebar');
  const menuToggle = document.getElementById('menuToggle');
  const closeMenu = () => sidebar?.classList.remove('open');
  menuToggle?.addEventListener('click', () => sidebar?.classList.toggle('open'));
  document.querySelectorAll('.sidebar a').forEach((link) => link.addEventListener('click', closeMenu));
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') closeMenu();
  });
  document.addEventListener('pointerdown', (event) => {
    if (!sidebar?.classList.contains('open')) return;
    if (sidebar.contains(event.target) || menuToggle?.contains(event.target)) return;
    closeMenu();
  });

  document.querySelectorAll('.copy-btn').forEach((button) => {
    button.addEventListener('click', async () => {
      const code = button.closest('.code-card')?.querySelector('pre code')?.innerText || '';
      if (!code) return;
      try {
        await navigator.clipboard.writeText(code);
      } catch {
        const textarea = document.createElement('textarea');
        textarea.value = code;
        textarea.style.cssText = 'position:fixed;opacity:0;pointer-events:none';
        document.body.appendChild(textarea);
        textarea.select();
        document.execCommand('copy');
        textarea.remove();
      }
      button.textContent = 'کپی شد';
      button.classList.add('copied');
      window.setTimeout(() => {
        button.textContent = 'کپی';
        button.classList.remove('copied');
      }, 1100);
    });
  });

  const sections = [...document.querySelectorAll('.doc-section')];
  const sideLinks = [...document.querySelectorAll('.sidebar a[href^="#"]')];
  if ('IntersectionObserver' in window) {
    const sectionObserver = new IntersectionObserver((entries) => {
      const current = entries
        .filter((entry) => entry.isIntersecting)
        .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
      if (!current) return;
      const hash = `#${current.target.id}`;
      sideLinks.forEach((link) => link.classList.toggle('active', link.getAttribute('href') === hash));
    }, { rootMargin: '-12% 0px -72% 0px', threshold: [0, .08, .35] });
    sections.forEach((section) => sectionObserver.observe(section));
  }

  const modal = document.getElementById('searchModal');
  const trigger = document.getElementById('searchTrigger');
  const input = document.getElementById('searchInput');
  const results = document.getElementById('searchResults');
  const searchData = sections.map((section) => ({
    id: section.id,
    title: section.dataset.title || section.querySelector('h2,h1')?.innerText || '',
    text: section.innerText.replace(/\s+/g, ' ').trim()
  }));
  let selected = 0;

  const closeSearch = () => {
    if (!modal) return;
    modal.hidden = true;
    input?.blur();
  };

  const renderSearch = (query = '') => {
    if (!results) return;
    const q = query.trim().toLocaleLowerCase('fa');
    const matches = searchData
      .filter((item) => !q || `${item.title} ${item.text}`.toLocaleLowerCase('fa').includes(q))
      .slice(0, 10);
    selected = Math.min(selected, Math.max(0, matches.length - 1));
    results.replaceChildren();
    if (!matches.length) {
      const empty = document.createElement('div');
      empty.className = 'search-result';
      empty.innerHTML = '<small>نتیجه‌ای پیدا نشد.</small>';
      results.appendChild(empty);
      return;
    }
    matches.forEach((item, index) => {
      const link = document.createElement('a');
      link.href = `#${item.id}`;
      link.className = `search-result${index === selected ? ' selected' : ''}`;
      const title = document.createElement('b');
      title.textContent = item.title;
      const excerpt = document.createElement('small');
      excerpt.textContent = `${item.text.slice(0, 150)}…`;
      link.append(title, excerpt);
      link.addEventListener('click', closeSearch);
      results.appendChild(link);
    });
  };

  const openSearch = () => {
    if (!modal || !input) return;
    modal.hidden = false;
    selected = 0;
    renderSearch(input.value);
    requestAnimationFrame(() => input.focus());
  };

  trigger?.addEventListener('click', openSearch);
  modal?.addEventListener('click', (event) => {
    if (event.target === modal) closeSearch();
  });
  input?.addEventListener('input', () => {
    selected = 0;
    renderSearch(input.value);
  });
  document.addEventListener('keydown', (event) => {
    const typing = /input|textarea/i.test(document.activeElement?.tagName || '');
    if (event.key === '/' && modal?.hidden && !typing) {
      event.preventDefault();
      openSearch();
      return;
    }
    if (event.key === 'Escape' && modal && !modal.hidden) {
      closeSearch();
      return;
    }
    if (!modal || modal.hidden || !results) return;
    const links = [...results.querySelectorAll('a')];
    if ((event.key === 'ArrowDown' || event.key === 'ArrowUp') && links.length) {
      event.preventDefault();
      selected = (selected + (event.key === 'ArrowDown' ? 1 : -1) + links.length) % links.length;
      renderSearch(input?.value || '');
    } else if (event.key === 'Enter' && links[selected]) {
      event.preventDefault();
      links[selected].click();
    }
  });

  const tokenEl = document.getElementById('deployToken');
  const tokenCopy = document.getElementById('deployTokenCopy');
  const tokenRegenerate = document.getElementById('deployTokenRegenerate');
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

  const generateToken = () => {
    if (!tokenEl) return;
    const bytes = new Uint8Array(64);
    crypto.getRandomValues(bytes);
    tokenEl.textContent = [...bytes].map((byte) => alphabet[byte & 63]).join('');
  };

  tokenRegenerate?.addEventListener('click', generateToken);
  tokenCopy?.addEventListener('click', async () => {
    const token = tokenEl?.textContent?.trim();
    if (!token) return;
    try {
      await navigator.clipboard.writeText(token);
    } catch {
      const textarea = document.createElement('textarea');
      textarea.value = token;
      textarea.style.cssText = 'position:fixed;opacity:0;pointer-events:none';
      document.body.appendChild(textarea);
      textarea.select();
      document.execCommand('copy');
      textarea.remove();
    }
    const label = tokenCopy.querySelector('span');
    tokenCopy.classList.add('copied');
    if (label) label.textContent = 'کپی شد';
    window.setTimeout(() => {
      tokenCopy.classList.remove('copied');
      if (label) label.textContent = 'کپی';
    }, 1100);
  });
  generateToken();

  const terminal = document.getElementById('terminalLive');
  const terminalLines = [
    ['20:17:31', 'info', 'INFO', 'Running build command…'],
    ['20:17:36', 'ok', 'OK', 'Build completed in 5s.'],
    ['20:17:37', 'info', 'INFO', 'Creating ZIP archive…'],
    ['20:17:38', 'ok', 'OK', 'Archive ready · 4.82 MB'],
    ['20:17:39', 'info', 'INFO', 'Uploading release via FTP…'],
    ['20:17:44', 'ok', 'OK', 'Upload completed.'],
    ['20:17:47', 'ok', 'OK', 'Release is healthy.']
  ];
  if (terminal) {
    let lineIndex = 0;
    const tick = () => {
      if (lineIndex === 0) terminal.replaceChildren();
      const [time, state, label, message] = terminalLines[lineIndex];
      const line = document.createElement('div');
      line.className = 'terminal-line';
      line.innerHTML = `<span class="t">[${time}]</span> <span class="${state}">${label}</span> <span class="label">${message}</span>`;
      terminal.appendChild(line);
      lineIndex = (lineIndex + 1) % terminalLines.length;
      window.setTimeout(tick, lineIndex === 0 ? 1700 : 460);
    };
    tick();
  }

  const progress = document.createElement('div');
  progress.className = 'reading-progress';
  progress.setAttribute('aria-hidden', 'true');
  progress.innerHTML = '<i></i>';
  document.body.appendChild(progress);
  const progressBar = progress.firstElementChild;

  const scrollTopButton = document.createElement('button');
  scrollTopButton.type = 'button';
  scrollTopButton.className = 'scroll-top';
  scrollTopButton.setAttribute('aria-label', 'بازگشت به ابتدای صفحه');
  scrollTopButton.innerHTML = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m6 15 6-6 6 6"/></svg>';
  document.body.appendChild(scrollTopButton);
  scrollTopButton.addEventListener('click', () => window.scrollTo({ top: 0, behavior: reducedMotion.matches ? 'auto' : 'smooth' }));

  let scrolling = false;
  const updateScrollUi = () => {
    const max = Math.max(1, document.documentElement.scrollHeight - innerHeight);
    if (progressBar) progressBar.style.width = `${Math.min(100, Math.max(0, (scrollY / max) * 100))}%`;
    scrollTopButton.classList.toggle('is-visible', scrollY > Math.min(650, innerHeight * .75));
    scrolling = false;
  };
  addEventListener('scroll', () => {
    if (scrolling) return;
    scrolling = true;
    requestAnimationFrame(updateScrollUi);
  }, { passive: true });
  addEventListener('resize', updateScrollUi, { passive: true });
  updateScrollUi();

  if (!reducedMotion.matches && 'IntersectionObserver' in window) {
    root.classList.add('motion-ready');
    const revealTargets = document.querySelectorAll('.doc-section > .section-kicker, .doc-section > h2, .doc-section > p, .step-card, .code-card, .table-wrap, .faq details, .download-grid a');
    const revealObserver = new IntersectionObserver((entries, observer) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('is-visible');
        observer.unobserve(entry.target);
      });
    }, { threshold: .06, rootMargin: '0px 0px -5% 0px' });
    revealTargets.forEach((element, index) => {
      element.classList.add('reveal-item');
      element.style.setProperty('--reveal-delay', `${Math.min(index % 4, 3) * 35}ms`);
      revealObserver.observe(element);
    });
  }
})();

/*
 * R2D WebDAV 目录界面。
 *
 * 页面本身是静态文件（lighttpd 没有 PCRE，无法把任意目录请求重写到 CGI），
 * 目录内容通过同源 PROPFIND 读取：WebDAV 的 GET/PUT/PROPFIND 行为完全不变，
 * 页面只是 PROPFIND 的一个可视化前端。
 *
 * 路径一律放在 ?p= 里，因此任何一层目录都可以直接收藏、刷新。
 */
(function () {
  'use strict';

  var TITLE = '文件浏览';
  var PROPFIND_BODY =
    '<?xml version="1.0" encoding="utf-8"?>' +
    '<d:propfind xmlns:d="DAV:"><d:prop>' +
    '<d:resourcetype/><d:getcontentlength/><d:getlastmodified/>' +
    '</d:prop></d:propfind>';

  var el = {
    crumbs: document.getElementById('crumbs'),
    list: document.getElementById('list'),
    count: document.getElementById('count'),
    title: document.getElementById('dirTitle'),
    sub: document.getElementById('sub'),
    state: document.getElementById('state'),
    hint: document.getElementById('hint')
  };

  if (el.sub) el.sub.textContent = 'R2D 文件服务 · ' + location.host;

  // 挂载/上传提示按客户端只给一条：macOS 访达、Windows 资源管理器、其他（手机/平板/Linux）。
  // iPadOS 的 UA 带 Macintosh，先按触屏设备排除，否则会把「访达」显示给 iPad。
  function clientHint(origin) {
    var ua = navigator.userAgent || '';
    var other = {
      text: '可在浏览器里直接浏览和下载；需要上传、改名、删除时，用任意 WebDAV 客户端连接 ' +
        origin + '。'
    };
    if (/iPhone|iPad|iPod|Android/i.test(ua)) return other;
    if (/Windows/i.test(ua)) {
      return {
        text: '上传、改名、删除：资源管理器 →「映射网络驱动器」→ 输入 ' + origin +
          '，提示时选「使用其他凭据」重填一次密码。',
        note: 'Windows 自带客户端对 http + Basic 支持有限，连不上可改用第三方 WebDAV 客户端。'
      };
    }
    if (/Macintosh|Mac OS X/i.test(ua)) {
      return { text: '上传、改名、删除：访达按 ⌘K → 输入 ' + origin + ' → 用当前账号密码连接。' };
    }
    return other;
  }

  if (el.hint) {
    var hint = clientHint(location.origin);
    el.hint.textContent = hint.text;
    if (hint.note) {
      var note = document.createElement('span');
      note.className = 'foot-note';
      note.textContent = hint.note;
      el.hint.appendChild(note);
    }
  }

  var collator = new Intl.Collator('zh-Hans-CN', { numeric: true, sensitivity: 'base' });

  var ICONS = {
    dir: '<path d="M3 7.5A1.5 1.5 0 0 1 4.5 6h4l2 2.5h7A1.5 1.5 0 0 1 19 10v7.5A1.5 1.5 0 0 1 17.5 19h-13A1.5 1.5 0 0 1 3 17.5z"/>',
    up: '<path d="M12 19V5"/><path d="M5 12l7-7 7 7"/>',
    image: '<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="10" r="1.6"/><path d="M4 17l5-5 4 4 3-3 4 4"/>',
    video: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M10 9.5v5l4.5-2.5z"/>',
    audio: '<path d="M9 18V6l10-2v12"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="16.5" cy="16" r="2.5"/>',
    archive: '<path d="M4 7h16v13H4z"/><path d="M4 7V4h16v3"/><path d="M10 11h4"/>',
    text: '<path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4"/><path d="M9 12h6M9 16h6"/>',
    file: '<path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4"/>'
  };

  function svg(name) {
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" ' +
      'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + ICONS[name] + '</svg>';
  }

  function iconFor(name, isDir) {
    if (isDir) return 'dir';
    var ext = (name.indexOf('.') >= 0 ? name.split('.').pop() : '').toLowerCase();
    if (/^(jpg|jpeg|png|gif|webp|heic|heif|bmp|svg|tif|tiff)$/.test(ext)) return 'image';
    if (/^(mp4|mov|mkv|avi|m4v|webm|ts|flv|wmv)$/.test(ext)) return 'video';
    if (/^(mp3|flac|m4a|aac|wav|ogg|ape|wma)$/.test(ext)) return 'audio';
    if (/^(zip|rar|7z|tar|gz|tgz|bz2|xz|iso)$/.test(ext)) return 'archive';
    if (/^(txt|md|log|json|xml|csv|ini|conf|sh|js|css|html|htm|pdf|doc|docx|xls|xlsx|ppt|pptx)$/.test(ext)) return 'text';
    return 'file';
  }

  function normalizePath(p) {
    if (!p) return '/';
    p = String(p).replace(/\/{2,}/g, '/');
    if (p.charAt(0) !== '/') p = '/' + p;
    if (p.charAt(p.length - 1) !== '/') p += '/';
    return p;
  }

  function stripSlash(p) {
    return String(p).replace(/\/+$/, '');
  }

  function encodePath(p) {
    return p.split('/').map(function (s) { return encodeURIComponent(s); }).join('/');
  }

  function decodeHref(href) {
    var path = href;
    try {
      path = new URL(href, location.origin).pathname;
    } catch (e) { /* 已经是路径形式 */ }
    try {
      return decodeURIComponent(path);
    } catch (e) {
      return path;
    }
  }

  function baseName(p) {
    var s = stripSlash(p);
    var i = s.lastIndexOf('/');
    return i >= 0 ? s.slice(i + 1) : s;
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function formatSize(bytes) {
    if (bytes === null || isNaN(bytes) || bytes < 0) return '—';
    if (bytes < 1024) return bytes + ' B';
    var units = ['KB', 'MB', 'GB', 'TB'];
    var v = bytes / 1024;
    var i = 0;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
    return (v >= 10 ? Math.round(v) : Math.round(v * 10) / 10) + ' ' + units[i];
  }

  function pad(n) { return n < 10 ? '0' + n : String(n); }

  function formatDate(d) {
    if (!d || isNaN(d.getTime())) return '—';
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
      ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  function setState(text) {
    if (!text) {
      el.state.hidden = true;
      el.state.textContent = '';
      return;
    }
    el.state.textContent = text;
    el.state.hidden = false;
  }

  function httpMessage(status) {
    if (status === 401) return '需要登录后才能访问（401）';
    if (status === 403) return '没有权限访问这个目录（403）';
    if (status === 404) return '目录不存在（404）';
    return '读取失败（HTTP ' + status + '）';
  }

  function currentPath() {
    var q = new URLSearchParams(location.search).get('p');
    return normalizePath(q || '/');
  }

  function navigate(p) {
    p = normalizePath(p);
    var url = p === '/' ? '/' : '/?p=' + encodeURIComponent(p);
    history.pushState({ p: p }, '', url);
    load(p);
  }

  function renderCrumbs(p) {
    var parts = p.split('/').filter(Boolean);
    var html = '<a href="/">根目录</a>';
    var acc = '';
    for (var i = 0; i < parts.length; i++) {
      acc += '/' + parts[i];
      html += '<span class="sep">/</span>';
      if (i === parts.length - 1) {
        html += '<span class="current">' + escapeHtml(parts[i]) + '</span>';
      } else {
        html += '<a href="/?p=' + encodeURIComponent(acc + '/') + '">' +
          escapeHtml(parts[i]) + '</a>';
      }
    }
    el.crumbs.innerHTML = html;
  }

  function upRow(p) {
    if (p === '/') return '';
    var parent = p.replace(/[^/]+\/$/, '') || '/';
    return '<li class="row up"><a class="entry" href="/?p=' + encodeURIComponent(parent) +
      '" data-dir="1" data-path="' + escapeHtml(parent) + '">' +
      '<span class="ico">' + svg('up') + '</span>' +
      '<span class="name">返回上级</span>' +
      '<span class="size"></span><span class="mtime"></span></a></li>';
  }

  function rowHtml(e) {
    var attrs = ' href="' + encodePath(e.path) + '" title="' + escapeHtml(e.name) + '"';
    if (e.dir) {
      attrs += ' data-dir="1" data-path="' + escapeHtml(e.path) + '"';
    } else {
      attrs += ' target="_blank" rel="noopener"';
    }
    return '<li class="row"><a class="entry' + (e.dir ? ' is-dir' : '') + '"' + attrs + '>' +
      '<span class="ico' + (e.dir ? ' dir' : '') + '">' + svg(iconFor(e.name, e.dir)) + '</span>' +
      '<span class="name">' + escapeHtml(e.name) + '</span>' +
      '<span class="size">' + (e.dir ? '—' : formatSize(e.size)) + '</span>' +
      '<span class="mtime">' + formatDate(e.mtime) + '</span></a></li>';
  }

  function parseMultiStatus(text, p) {
    var doc = new DOMParser().parseFromString(text, 'application/xml');
    if (doc.getElementsByTagName('parsererror').length) {
      throw new Error('目录数据格式异常');
    }
    var out = [];
    var responses = doc.getElementsByTagNameNS('DAV:', 'response');
    for (var i = 0; i < responses.length; i++) {
      var r = responses[i];
      var hrefEl = r.getElementsByTagNameNS('DAV:', 'href')[0];
      if (!hrefEl) continue;

      var typeEl = r.getElementsByTagNameNS('DAV:', 'resourcetype')[0];
      var isDir = !!(typeEl && typeEl.getElementsByTagNameNS('DAV:', 'collection').length);

      var path = decodeHref(hrefEl.textContent || '');
      if (isDir) {
        path = normalizePath(path);
      } else {
        path = stripSlash(path);
        if (path === '') path = '/';
      }
      if (stripSlash(path) === stripSlash(p)) continue;

      var name = baseName(path);
      if (!name || name.charAt(0) === '.') continue;

      var sizeEl = r.getElementsByTagNameNS('DAV:', 'getcontentlength')[0];
      var dateEl = r.getElementsByTagNameNS('DAV:', 'getlastmodified')[0];
      var size = sizeEl ? parseInt(sizeEl.textContent, 10) : null;
      var mtime = dateEl ? new Date(dateEl.textContent) : null;

      out.push({
        name: name,
        path: path,
        dir: isDir,
        size: isNaN(size) ? null : size,
        mtime: mtime
      });
    }
    out.sort(function (a, b) {
      if (a.dir !== b.dir) return a.dir ? -1 : 1;
      return collator.compare(a.name, b.name);
    });
    return out;
  }

  function load(p) {
    setState('正在读取目录…');
    el.list.innerHTML = '';
    el.count.textContent = '加载中…';
    renderCrumbs(p);
    el.title.textContent = p === '/' ? '目录' : baseName(p);
    document.title = p === '/' ? TITLE : baseName(p) + ' · ' + TITLE;

    fetch(encodePath(p), {
      method: 'PROPFIND',
      headers: { 'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8' },
      body: PROPFIND_BODY,
      credentials: 'same-origin',
      cache: 'no-store'
    }).then(function (res) {
      if (!res.ok) throw new Error(httpMessage(res.status));
      return res.text();
    }).then(function (text) {
      var entries = parseMultiStatus(text, p);
      el.list.innerHTML = upRow(p) + entries.map(rowHtml).join('');
      el.count.textContent = '共 ' + entries.length + ' 项';
      if (entries.length) {
        setState('');
      } else {
        setState('这个目录是空的');
      }
    }).catch(function (err) {
      el.count.textContent = '';
      setState(err && err.message ? err.message : '无法读取此目录');
    });
  }

  el.list.addEventListener('click', function (ev) {
    var a = ev.target.closest ? ev.target.closest('a[data-dir]') : null;
    if (!a) return;
    ev.preventDefault();
    navigate(a.getAttribute('data-path'));
  });

  el.crumbs.addEventListener('click', function (ev) {
    var a = ev.target.closest ? ev.target.closest('a') : null;
    if (!a) return;
    ev.preventDefault();
    var q = new URL(a.href, location.origin).searchParams.get('p');
    navigate(q || '/');
  });

  window.addEventListener('popstate', function () {
    load(currentPath());
  });

  load(currentPath());
})();

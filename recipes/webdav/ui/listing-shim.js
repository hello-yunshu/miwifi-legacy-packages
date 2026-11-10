/*
 * 深层目录转跳：lighttpd 自带的列表页是英文的，且本构建没有 PCRE，
 * 无法把这些请求重写到 CGI。保留 mod_dirlisting 作为兜底，由这段脚本
 * 立刻把浏览器转到中文界面 /?p=<当前路径>。
 *
 * location.pathname 已经是百分号编码过的，先解码再编码，避免 %25 双重编码。
 */
(function () {
  'use strict';
  var p = location.pathname;
  if (!p || p === '/') return;
  try {
    p = decodeURIComponent(p);
  } catch (e) { /* 保持原样，交给服务端返回 404 */ }
  location.replace('/?p=' + encodeURIComponent(p));
})();

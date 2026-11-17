// Runs in every page and frame of the video finder. Reads Vimeo's player configuration (which
// lists a stream with picture + sound) and starts recorded videos muted so their files load.
const { ipcRenderer, contextBridge, webFrame } = require('electron');

contextBridge.exposeInMainWorld('__pareReport', (u) => { try { ipcRenderer.send('pare-found', String(u)); } catch (e) { /* closed */ } });

webFrame.executeJavaScript(`(function(){
  if (window.__pareReels) return; window.__pareReels = true;
  function report(u){ try { u = new URL(u, location.href).href; if (/^https?:/i.test(u)) window.__pareReport(u); } catch(e) {} }
  function fromVimeoConfig(cfg){
    try {
      var files = cfg && cfg.request && cfg.request.files;
      var hls = files && files.hls;
      if (hls && hls.cdns) {
        var order = [hls.default_cdn].concat(Object.keys(hls.cdns));
        for (var i = 0; i < order.length; i++) { var c = hls.cdns[order[i]]; if (c && c.url) { report(c.url); break; } }
      }
      (files && files.progressive || []).forEach(function(p){ if (p && p.url) report(p.url); });
    } catch(e) {}
  }
  function maybeConfig(url, text){
    if (!url || String(url).indexOf('vimeo') < 0 || String(url).indexOf('config') < 0) return;
    try { fromVimeoConfig(JSON.parse(text)); } catch(e) {}
  }
  var f = window.fetch;
  if (f) window.fetch = function(input){
    var u = typeof input === 'string' ? input : (input && input.url);
    var p = f.apply(this, arguments);
    try { p.then(function(r){ if (String(u).indexOf('config') >= 0) r.clone().text().then(function(t){ maybeConfig(u, t); }); }).catch(function(){}); } catch(e) {}
    return p;
  };
  var open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(method, url){
    var xhr = this;
    try { xhr.addEventListener('load', function(){ try { maybeConfig(String(url), xhr.responseText); } catch(e) {} }); } catch(e) {}
    return open.apply(this, arguments);
  };
  setInterval(function(){
    if (window.playerConfig) fromVimeoConfig(window.playerConfig);
    document.querySelectorAll('video,audio,source').forEach(function(el){ var s = el.currentSrc || el.src; if (s && !/^blob:/.test(s)) report(s); });
    if (!window.__pareReelsDone) document.querySelectorAll('video').forEach(function(v){
      try { v.muted = true; if (v.paused) { var p = v.play(); if (p && p.catch) p.catch(function(){}); } } catch(e) {}
    });
  }, 1500);
})();`).catch(() => {});

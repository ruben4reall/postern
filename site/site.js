// Postern website: scene timelines, reveal on scroll, the switch demo and copy buttons.
// No dependencies, no network requests.
(function () {
  'use strict';
  window.posternReady = true;

  var root = document.documentElement;
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
  var motion = function () { return root.classList.contains('motion'); };

  // A polite live region for short confirmations.
  var live = document.createElement('p');
  live.className = 'sr-only';
  live.setAttribute('aria-live', 'polite');
  document.body.appendChild(live);

  // Scenes: each step adds a class (s1, s2, ...) at its time; CSS draws the states.
  var scenes = Array.prototype.map.call(document.querySelectorAll('[data-scene]'), function (el) {
    return {
      el: el,
      times: el.getAttribute('data-timeline').split(',').map(Number),
      loop: Number(el.getAttribute('data-loop')) || 0,
      timers: [], played: false, visible: false, loops: 0
    };
  });
  var MAX_LOOPS = 3;

  function clear(scene) {
    scene.timers.forEach(clearTimeout);
    scene.timers = [];
    scene.el.classList.add('resetting');
    for (var i = 1; i <= scene.times.length; i++) scene.el.classList.remove('s' + i);
    scene.el.classList.remove('done');
    void scene.el.offsetWidth;
    scene.el.classList.remove('resetting');
  }

  function play(scene) {
    clear(scene);
    scene.played = true;
    scene.times.forEach(function (time, i) {
      scene.timers.push(setTimeout(function () { scene.el.classList.add('s' + (i + 1)); }, time));
    });
    var end = scene.times[scene.times.length - 1] + 400;
    scene.timers.push(setTimeout(function () { scene.el.classList.add('done'); }, end));
    // The hero plays again a few times while it stays in view, then rests.
    if (scene.loop) scene.timers.push(setTimeout(function () {
      if (scene.visible && !document.hidden && motion() && scene.loops < MAX_LOOPS) { scene.loops++; play(scene); }
    }, end + scene.loop));
  }

  function finish(scene) {
    scene.timers.forEach(clearTimeout);
    scene.timers = [];
    scene.times.forEach(function (_, i) { scene.el.classList.add('s' + (i + 1)); });
    scene.el.classList.add('done');
  }

  scenes.forEach(function (scene) {
    var button = scene.el.querySelector('.replay');
    if (button) button.addEventListener('click', function () { if (motion()) { scene.loops = MAX_LOOPS; play(scene); } });
  });

  var reveals = document.querySelectorAll('.reveal');

  if ('IntersectionObserver' in window) {
    var sceneWatch = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        var scene = scenes.find(function (s) { return s.el === entry.target; });
        if (!scene) return;
        scene.visible = entry.isIntersecting && entry.intersectionRatio >= 0.3;
        if (scene.visible && !scene.played && motion()) play(scene);
      });
    }, { threshold: 0.35 });
    scenes.forEach(function (scene) { sceneWatch.observe(scene.el); });

    var revealWatch = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('in');
        revealWatch.unobserve(entry.target);
      });
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.05 });
    reveals.forEach(function (el) { revealWatch.observe(el); });
  } else {
    root.classList.remove('motion');
  }

  // If the visitor turns on Reduce Motion while the page is open, show everything at rest.
  var onPreference = function () {
    if (!reduce.matches) return;
    root.classList.remove('motion');
    scenes.forEach(finish);
    reveals.forEach(function (el) { el.classList.add('in'); });
  };
  if (reduce.addEventListener) reduce.addEventListener('change', onPreference);

  // The switch demo: a tool that is off is absent from what the app sees.
  var switches = document.querySelectorAll('.switch[data-tier]');
  var items = document.querySelectorAll('.tool-list li');
  var count = document.querySelector('[data-count]');

  function update(changed) {
    var on = {};
    Array.prototype.forEach.call(switches, function (sw) {
      if (sw.getAttribute('aria-checked') === 'true') on[sw.getAttribute('data-tier')] = true;
    });
    var shown = 0;
    Array.prototype.forEach.call(items, function (li) {
      var visible = li.getAttribute('data-tier').split(' ').some(function (tier) { return on[tier]; });
      if (visible && li.hidden && changed) {
        li.classList.remove('enter');
        void li.offsetWidth;
        li.classList.add('enter');
      }
      li.hidden = !visible;
      if (visible) shown++;
    });
    if (count) count.textContent = shown;
  }

  Array.prototype.forEach.call(switches, function (sw) {
    sw.addEventListener('click', function () {
      if (sw.hasAttribute('data-pending')) return;
      var tier = sw.getAttribute('data-tier');
      var label = document.getElementById(sw.getAttribute('aria-labelledby')).textContent;
      if (sw.getAttribute('aria-checked') === 'true') {
        sw.setAttribute('aria-checked', 'false');
        update(tier);
        live.textContent = (document.documentElement.getAttribute('data-off') || '%s off. Its tools are gone from the list.').replace('%s', label);
        return;
      }
      var turnOn = function () {
        sw.removeAttribute('data-pending');
        sw.setAttribute('aria-checked', 'true');
        update(tier);
        live.textContent = (document.documentElement.getAttribute('data-on') || '%s on, after Touch ID.').replace('%s', label);
      };
      if (!motion()) { turnOn(); return; }
      sw.setAttribute('data-pending', '');
      setTimeout(turnOn, 650);
    });
  });
  update();

  // Copy buttons.
  Array.prototype.forEach.call(document.querySelectorAll('[data-copy]'), function (box) {
    var button = box.querySelector('.copy');
    var code = box.querySelector('code');
    if (!button || !code) return;
    var icon = button.querySelector('use');
    button.addEventListener('click', function () {
      var text = code.textContent.trim();
      var done = function () {
        button.classList.add('copied');
        if (icon) icon.setAttribute('href', '#i-check');
        live.textContent = document.documentElement.getAttribute('data-copied') || 'Copied';
        clearTimeout(button.copyTimer);
        button.copyTimer = setTimeout(function () {
          button.classList.remove('copied');
          if (icon) icon.setAttribute('href', '#i-copy');
        }, 1600);
      };
      var fallback = function () {
        var range = document.createRange();
        range.selectNodeContents(code);
        var selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        try { if (document.execCommand('copy')) done(); } catch (e) { /* the text stays selected */ }
      };
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(done, fallback);
      } else {
        fallback();
      }
    });
  });
})();

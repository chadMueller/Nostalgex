/* Nostalgex marketing homepage — global script.
   Loaded by index.html, web-tuner.html and support.html, which all share styles.css. */
(function () {
  "use strict";

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- Theme toggle ----------
     The <head> boot script owns the default + first paint; this just flips
     [data-theme] on <html> and remembers the choice. The button shows the
     theme you can switch TO: a sun while dark, a moon while light. */
  var THEME_KEY = "nostalgex-theme-v2";
  var rootEl = document.documentElement;
  var themeToggle = document.getElementById("themeToggle");

  function syncToggle() {
    var dark = rootEl.getAttribute("data-theme") === "dark";
    var label = dark ? "Switch to day mode" : "Switch to night mode";
    themeToggle.setAttribute("aria-pressed", String(dark));
    themeToggle.setAttribute("aria-label", label);
    themeToggle.setAttribute("title", label);
  }

  if (themeToggle) {
    themeToggle.addEventListener("click", function () {
      var next = rootEl.getAttribute("data-theme") === "dark" ? "light" : "dark";
      rootEl.setAttribute("data-theme", next);
      try { localStorage.setItem(THEME_KEY, next); } catch (e) {}
      syncToggle();
    });
    syncToggle();
  }

  /* ---------- Nav scroll state ---------- */
  var nav = document.getElementById("nav");
  if (nav) {
    var onScroll = function () {
      nav.classList.toggle("is-scrolled", window.scrollY > 8);
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    onScroll();
  }

  /* ---------- Announcement bar ----------
     The markup comes from content/announcements.json (scripts/announcements.mjs)
     and each message's text is in the page once. One message shows at a time.
     Several rotate every 7 seconds; under reduced motion nothing rotates, the first
     live one stays and closing it shows the next. A message wider than the bar
     pans slowly back and forth (the one copy of the text moves, it is never
     duplicated). Hover and focus pause both. Closed ids are kept in localStorage;
     every read and write is in try/catch, so the bar works with storage off, for
     the page at hand. */
  (function () {
    var bar = document.getElementById("announce");
    if (!bar || bar.hidden) return;
    var KEY = "nostalgex-announce-v1"; /* keep in step with DISMISS_KEY in scripts/announcements.mjs */
    var closed = [];
    try { closed = JSON.parse(localStorage.getItem(KEY) || "[]"); } catch (e) {}
    if (!Array.isArray(closed)) closed = [];

    var now = Date.now();
    var live = [].slice.call(bar.querySelectorAll(".announce-msg")).filter(function (m) {
      var starts = Date.parse(m.getAttribute("data-starts"));
      var ends = Date.parse(m.getAttribute("data-ends"));
      var show = closed.indexOf(m.getAttribute("data-id")) < 0 && !(starts > now) && !(ends <= now);
      m.hidden = true;
      return show;
    });
    if (!live.length) { bar.hidden = true; return; }

    var cur = 0, dwell = 7000, hold = false, timer = null;

    /* Pan only when the text is wider than the bar. Returns the length of one pass in seconds. */
    function fit(m) {
      var text = m.querySelector(".announce-text");
      m.classList.remove("is-pan");
      var over = text.offsetWidth - m.clientWidth;
      if (over < 2 || reduceMotion) return 0;
      var secs = Math.max(6, over / 25); /* about 35px a second between the two pauses */
      text.style.setProperty("--announce-shift", -over + "px");
      text.style.setProperty("--announce-dur", secs.toFixed(1) + "s");
      m.classList.add("is-pan");
      return secs;
    }

    function schedule() {
      clearTimeout(timer);
      if (live.length < 2 || reduceMotion) return;
      timer = setTimeout(function () {
        if (hold || document.hidden) return schedule(); /* wait while it is being read */
        show((cur + 1) % live.length, true);
      }, dwell);
    }

    function show(i, fade) {
      live.forEach(function (m, j) { m.hidden = j !== i; });
      cur = i;
      var m = live[i];
      dwell = Math.max(7000, fit(m) * 1000);
      if (fade && !reduceMotion) {
        m.classList.remove("is-entering");
        void m.offsetWidth;
        m.classList.add("is-entering");
      }
      schedule();
    }

    show(0, false);
    /* Widths change when the webfont arrives and when the window is resized. */
    function refit() { if (live.length) fit(live[cur]); }
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(refit);
    var resizeTimer;
    window.addEventListener("resize", function () {
      clearTimeout(resizeTimer);
      resizeTimer = setTimeout(refit, 150);
    });

    function hovering(e) { return e.pointerType === "mouse"; }
    bar.addEventListener("pointerenter", function (e) { if (hovering(e)) hold = true; });
    bar.addEventListener("pointerleave", function (e) { if (hovering(e)) hold = false; });
    bar.addEventListener("focusin", function () { hold = true; });
    bar.addEventListener("focusout", function () { hold = false; });

    var closeBtn = bar.querySelector(".announce-close");
    if (closeBtn) {
      closeBtn.addEventListener("click", function () {
        var id = live[cur].getAttribute("data-id");
        if (closed.indexOf(id) < 0) closed.push(id);
        try { localStorage.setItem(KEY, JSON.stringify(closed.slice(-40))); } catch (e) {}
        live[cur].hidden = true;
        live.splice(cur, 1);
        if (live.length) {
          show(cur % live.length, true);
        } else {
          clearTimeout(timer);
          bar.hidden = true;
          /* The button that had focus is gone; hand focus to the logo so it is not lost. */
          var brand = document.querySelector("#nav .brand");
          if (brand) brand.focus();
        }
      });
    }
  })();

  /* ---------- Mobile menu (hamburger) ----------
     Nav links and the social icons hide out of the bar at 1024px; this is
     where they live instead. */
  var navToggle = document.getElementById("navToggle");
  var mobileMenu = document.getElementById("mobileMenu");
  if (nav && navToggle && mobileMenu) {
    var closeMobileMenu = function () {
      nav.removeAttribute("data-menu-open");
      navToggle.setAttribute("aria-expanded", "false");
      document.body.style.overflow = "";
    };
    var openMobileMenu = function () {
      nav.setAttribute("data-menu-open", "true");
      navToggle.setAttribute("aria-expanded", "true");
      document.body.style.overflow = "hidden";
    };
    navToggle.addEventListener("click", function () {
      if (nav.getAttribute("data-menu-open") === "true") closeMobileMenu();
      else openMobileMenu();
    });
    mobileMenu.querySelectorAll("a, button").forEach(function (el) {
      el.addEventListener("click", closeMobileMenu);
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && nav.getAttribute("data-menu-open") === "true") closeMobileMenu();
    });
    document.addEventListener("click", function (e) {
      if (nav.getAttribute("data-menu-open") !== "true") return;
      if (!nav.contains(e.target)) closeMobileMenu();
    });
    window.addEventListener("resize", function () {
      if (window.innerWidth > 1024 && nav.getAttribute("data-menu-open") === "true") closeMobileMenu();
    });
  }

  /* ---------- Lineup: generated groups become collapsible bundles ----------
     render-lineup.mjs emits flat .lineup__group blocks (head + grid). Rather
     than fork the generator into <details>, progressively enhance them here. */
  var groups = document.querySelectorAll(".lineup-card .lineup__group");
  groups.forEach(function (group, i) {
    var head = group.querySelector(".lineup__group-head");
    var grid = group.querySelector(".lineup__grid");
    if (!head || !grid) return;

    // The bundle name is a link to that bundle's guide page, so the row itself
    // must not be the button: a link inside a role="button" is invalid nesting
    // and screen readers end up reading the link as part of the button's name.
    // The chevron is the real control; clicking anywhere else in the row still
    // toggles, which keeps the mouse behaviour people already have.
    var marker = document.createElement("button");
    marker.className = "faq-marker lineup__group-toggle";
    marker.type = "button";
    head.appendChild(marker);

    var open = i === 0;
    if (!grid.id) grid.id = "lineup-grid-" + (i + 1);
    marker.setAttribute("aria-controls", grid.id);

    var name = group.querySelector(".lineup__group-name");
    var label = name ? name.textContent.trim() : "this bundle";

    function apply() {
      group.classList.toggle("is-open", open);
      marker.setAttribute("aria-expanded", String(open));
      marker.setAttribute("aria-label", (open ? "Collapse " : "Expand ") + label + " channels");
      grid.hidden = !open;
    }
    apply();

    function toggle() {
      open = !open;
      apply();
    }

    marker.addEventListener("click", function (e) {
      e.stopPropagation();
      toggle();
    });
    head.addEventListener("click", function (e) {
      // Let the guide link and the chevron handle their own clicks.
      if (e.target.closest("a") || e.target.closest(".lineup__group-toggle")) return;
      toggle();
    });
  });

  /* Bundle / channel counts read from the generated markup, so they never drift. */
  var bundleCount = document.querySelector("[data-lineup-bundles]");
  var channelCount = document.querySelector("[data-lineup-channels]");
  if (bundleCount && groups.length) bundleCount.textContent = String(groups.length);
  if (channelCount) {
    var items = document.querySelectorAll(".lineup-card .lineup__item").length;
    if (items) channelCount.textContent = String(items);
  }

  /* ---------- Reveal on scroll ---------- */
  var revealEls = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && !reduceMotion) {
    var io = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            io.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.12, rootMargin: "0px 0px -40px 0px" }
    );
    revealEls.forEach(function (el) { io.observe(el); });
  } else {
    revealEls.forEach(function (el) { el.classList.add("is-visible"); });
  }

  /* ---------- Hero video: start after load, never for reduced motion ----------
     The <video> ships with preload="none" and no autoplay, so first paint only
     pays for the poster. Once the page has loaded, start it, unless the visitor
     asked for reduced motion or Save Data, in which case the poster stays up. */
  var heroVideos = document.querySelectorAll("video[data-autoplay]");
  var saveData = navigator.connection && navigator.connection.saveData;
  if (heroVideos.length && !reduceMotion && !saveData) {
    var startHeroVideos = function () {
      heroVideos.forEach(function (v) {
        v.preload = "auto";
        v.autoplay = true;
        var played = v.play();
        if (played && played.catch) played.catch(function () {});
      });
    };
    // Waiting for load keeps the video off the critical path, but the load
    // event waits for every subresource including the analytics script, and a
    // slow third party should not be able to hold the hero still. Start on
    // load, or two seconds after the DOM is ready, whichever comes first.
    var heroStarted = false;
    var startOnce = function () {
      if (heroStarted) return;
      heroStarted = true;
      startHeroVideos();
    };
    if (document.readyState === "complete") startOnce();
    else {
      window.addEventListener("load", startOnce, { once: true });
      setTimeout(startOnce, 2000);
    }
  }

  /* ---------- Inline clips: start when they scroll into view ----------
     Same deal as the hero (preload="none", no autoplay attribute), but these
     sit well down the page, so loading them at window.load would pull video
     nobody has scrolled to. Start on intersection, pause on the way out. */
  var clips = document.querySelectorAll("video[data-clip]");
  if (clips.length && !reduceMotion && !saveData && "IntersectionObserver" in window) {
    var clipObserver = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          var v = entry.target;
          if (entry.isIntersecting) {
            v.preload = "auto";
            var played = v.play();
            if (played && played.catch) played.catch(function () {});
          } else if (!v.paused) {
            v.pause();
          }
        });
      },
      { rootMargin: "200px 0px" },
    );
    clips.forEach(function (v) {
      clipObserver.observe(v);
    });
  }

  /* ---------- Copy buttons on command blocks ----------
     The self host page is mostly commands people have to retype into a shell.
     Added here rather than in the markup so a copy button only ever appears
     when the clipboard API is actually available. */
  if (navigator.clipboard && window.isSecureContext) {
    document.querySelectorAll("pre > code").forEach(function (code) {
      var pre = code.parentElement;
      if (pre.querySelector(".copy-btn")) return;
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "copy-btn";
      btn.textContent = "COPY";
      btn.setAttribute("aria-label", "Copy to clipboard");
      var reset;
      btn.addEventListener("click", function () {
        navigator.clipboard.writeText(code.textContent.trim()).then(
          function () {
            btn.textContent = "COPIED";
            btn.classList.add("is-copied");
            clearTimeout(reset);
            reset = setTimeout(function () {
              btn.textContent = "COPY";
              btn.classList.remove("is-copied");
            }, 1600);
          },
          function () {
            btn.textContent = "PRESS CTRL C";
            clearTimeout(reset);
            reset = setTimeout(function () {
              btn.textContent = "COPY";
            }, 2400);
          },
        );
      });
      pre.classList.add("has-copy");
      pre.appendChild(btn);
    });
  }

  /* ---------- FAQ: close others when one opens ---------- */
  var faqs = document.querySelectorAll(".faq-list details");
  faqs.forEach(function (d) {
    d.addEventListener("toggle", function () {
      if (d.open) {
        faqs.forEach(function (other) {
          if (other !== d) other.open = false;
        });
      }
    });
  });

  /* ---------- What's new (changelog dialog) ----------
     Native <dialog>: Escape closes for free; we add backdrop-click close
     and a body scroll lock while it's open. */
  var changelog = document.getElementById("changelogDialog");
  if (changelog) {
    document.querySelectorAll("[data-changelog-open]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        document.body.style.overflow = "hidden";
        changelog.showModal();
        var body = changelog.querySelector(".changelog-body");
        if (body) body.scrollTop = 0;
      });
    });
    document.querySelectorAll("[data-changelog-close]").forEach(function (btn) {
      btn.addEventListener("click", function () { changelog.close(); });
    });
    changelog.addEventListener("click", function (e) {
      /* a click on the dialog element itself (not its children) is the backdrop */
      if (e.target === changelog) changelog.close();
    });
    changelog.addEventListener("close", function () {
      document.body.style.overflow = "";
    });
  }

  /* ---------- Email signup (Resend, via /api/subscribe) ----------
     Same-origin now that this page ships on nostalgex.app. Binds the page's own
     forms (.js-subscribe-form) AND the newsletter form the lineup generator
     drops into the bundle list (.newsletter-form). This is the only subscribe
     handler on this page — scripts/newsletter.js is NOT loaded here. */
  var SUBSCRIBE_URL = "/api/subscribe";
  var UTM_KEY = "nostalgex_signup_utm";
  var TOKEN_RE = /^[a-z0-9_]{1,40}$/;

  function cleanToken(value) {
    var v = String(value || "").trim().toLowerCase();
    return TOKEN_RE.test(v) ? v : "";
  }

  /* Normalized path of this page: "/", "/web-tuner", "/support"... */
  function pagePath() {
    return (window.location.pathname.replace(/\.html$/, "").replace(/\/index$/, "") || "/").toLowerCase();
  }

  /* UTMs from the landing URL, kept for the tab so they survive in-page
     navigation. Only whitelisted tokens are kept; anything else is ignored. */
  var landingUtm = (function () {
    var params = new URLSearchParams(window.location.search);
    var found = {};
    var any = false;
    ["source", "medium", "campaign", "content"].forEach(function (key) {
      var v = cleanToken(params.get("utm_" + key));
      if (v) { found[key] = v; any = true; }
    });
    try {
      if (any) sessionStorage.setItem(UTM_KEY, JSON.stringify(found));
      else found = JSON.parse(sessionStorage.getItem(UTM_KEY) || "null") || {};
    } catch (e) {}
    return found;
  })();

  /* Which form or QR a signup came from. Apple TV QR codes win (that's the
     attribution we can't get any other way); otherwise the form says where it is. */
  function signupSource(form) {
    if (landingUtm.source === "appletv" && landingUtm.campaign === "qr_signup" && landingUtm.content) {
      var qr = cleanToken("appletv_qr_" + landingUtm.content);
      if (qr) return qr;
    }
    var declared = cleanToken(form.getAttribute("data-signup-source"));
    if (declared) return declared;
    if (form.classList.contains("newsletter-form")) return "lineup";
    var slug = pagePath() === "/" ? "home" : pagePath().replace(/^\//, "").replace(/[^a-z0-9]+/g, "_");
    return cleanToken((form.closest(".footer-signup") ? "footer_" : "form_") + slug) || "unknown";
  }

  document.querySelectorAll(".js-subscribe-form, .newsletter-form").forEach(function (form) {
    var input = form.querySelector("input[type='email']");
    var button = form.querySelector("button[type='submit']");
    var msg = form.parentElement.querySelector(".subscribe-msg, .newsletter-msg");
    if (!input || !button) return;

    function say(text, isError) {
      if (!msg) return;
      msg.textContent = text;
      msg.classList.toggle("is-error", !!isError);
    }

    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var email = (input.value || "").trim();
      if (!email || email.indexOf("@") < 1) {
        say("That email doesn't look right. One more try.", true);
        input.focus();
        return;
      }
      var source = signupSource(form);
      button.disabled = true;
      say("Sending...");
      fetch(SUBSCRIBE_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email: email, source: source, page: pagePath(), utm: landingUtm })
      })
        .then(function (res) {
          if (!res.ok) throw new Error("bad status " + res.status);
          say("You're in. Talk soon.");
          form.reset();
          /* StatsNGraphs custom event: a real subscribe, not just a button click.
             Only the fixed source token goes along. */
          try {
            if (window.sng && typeof window.sng.track === "function") {
              window.sng.track("signup_success", { source: source });
            }
          } catch (e) {}
        })
        .catch(function () {
          say("That didn't go through. Give it another shot in a minute.", true);
        })
        .finally(function () {
          button.disabled = false;
        });
    });
  });
})();

// ==UserScript==
// @name         Usenet Archives sampler
// @namespace    news-setup
// @version      0.1.0
// @description  Download a small sample of the best-known threads of the biggest groups on usenetarchives.com as plain-text mbox files (quotes and signatures stripped), for news-import.
// @match        https://usenetarchives.com/*
// @match        https://www.usenetarchives.com/*
// @grant        none
// @run-at       document-idle
// @noframes
// ==/UserScript==

/*
 * What it does, when YOU press Run (nothing happens by itself):
 *   - reads the group list on the page you are looking at, takes the top GROUPS by posts,
 *   - for each group opens its page, takes the top THREADS by size,
 *   - for each thread keeps the first MESSAGES messages, with the quoted text and signatures taken out,
 *   - saves one  usenet-<group>.mbox  per group as soon as the group is done (the browser may ask once
 *     to allow several downloads), and remembers which groups are done, so a stop or a reload resumes.
 * Defaults 20 x 20 x 20: 8000 messages at most.  It waits between requests (DELAY ms, plus a random
 * extra) and stops at the first 403 / 429 / 503 - if the site says no, it is no.  Be kind: a sample
 * for yourself, not a copy of the site.
 *
 * It runs in your own browser session, so the site sees you, not a robot; it only does what you could
 * do with the mouse, slower.  Read the site's terms first.
 *
 * Use:  open a page that lists groups (e.g. https://usenetarchives.com/groups.php), click the POSTS
 * heading to sort the biggest first (or pick the collection you want, such as Utzoo), then press Run in
 * the box at the bottom right.  Then:  bin/news-import --groups groups.d/classic.list usenet-*.mbox
 *
 * The pieces that know what the site looks like are marked SITE below - they are best guesses from a
 * screenshot, and were NOT tested against the real pages.  If Run cannot find what it needs it says
 * what is missing; press "Probe" on that page and send the copied text to whoever maintains this, and
 * the SITE functions get fixed.  Everything else (quote stripping, mbox writing, ranking, resuming) is
 * tested: node news-setup/tests/test_usenet_sample.js
 */
(function (root) {
  "use strict";

  // ------------------------------------------------------------------ core (tested) ---
  const SIG_SEARCH = 12;      // a signature separator ("-- ") is looked for in the last this-many lines

  function parseCount(s) {
    const n = parseInt(String(s || "").replace(/[^0-9]/g, ""), 10);
    return isNaN(n) ? 0 : n;
  }

  function rankTop(items, key, n) {
    return items
      .map((it, i) => ({ it, i }))
      .sort((a, b) => (b.it[key] - a.it[key]) || (a.i - b.i))
      .slice(0, n)
      .map(x => x.it);
  }

  // The text of an article without what it quotes: lines that start with ">" or "|", the "X writes:" /
  // "In article <...>" line that introduces a quote, "[quoted text deleted]" markers, and the signature
  // (from a "-- " line near the end).  Blank runs shrink to one blank line.
  function stripQuotes(text, opts) {
    opts = Object.assign({ signature: true }, opts || {});
    let lines = String(text == null ? "" : text).replace(/\r\n?/g, "\n").split("\n");
    if (opts.signature) {
      for (let i = Math.max(0, lines.length - SIG_SEARCH); i < lines.length; i++) {
        if (/^-- ?$/.test(lines[i])) { lines = lines.slice(0, i); break; }
      }
    }
    const isQuote = l => /^\s{0,3}(>|\|)/.test(l);
    const nextNonBlank = i => { for (let j = i + 1; j < lines.length; j++) if (lines[j].trim()) return j; return -1; };
    const drop = new Array(lines.length).fill(false);
    for (let i = 0; i < lines.length; i++) {
      const l = lines[i];
      if (isQuote(l)) { drop[i] = true; continue; }
      if (/^\s*[\[(*]?\s*(quoted text|text) (deleted|omitted)|^\s*\[.*\b(deleted|snip(ped)?)\b.*\]\s*$/i.test(l)) { drop[i] = true; continue; }
      const intro = /^\s*in article\b/i.test(l) || /\b(writes|wrote|said|says)\s*:\s*$/i.test(l);
      if (intro) {
        const j = nextNonBlank(i);
        if (j >= 0 && isQuote(lines[j])) { drop[i] = true; continue; }
        // "In article <id>, Bob Smith" / "wrote:" on two lines
        if (/^\s*in article\b/i.test(l) && j >= 0 && /\b(writes|wrote|said|says)\s*:\s*$/i.test(lines[j])) {
          const k = nextNonBlank(j);
          if (k >= 0 && isQuote(lines[k])) { drop[i] = true; drop[j] = true; }
        }
      }
    }
    const out = [];
    let blank = true;                           // true at the start: no leading blank lines
    lines.forEach((l, i) => {
      if (drop[i]) return;
      if (!l.trim()) {
        if (!blank) out.push("");
        blank = true;
      } else {
        out.push(l.replace(/\s+$/, ""));
        blank = false;
      }
    });
    while (out.length && !out[out.length - 1]) out.pop();
    return out.join("\n");
  }

  // true when nothing but quotes (or nothing) was said
  function isEmptyBody(text) {
    return !/[A-Za-z0-9]/.test(String(text || ""));
  }

  function cleanHeader(v) {
    return String(v == null ? "" : v).replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 500);
  }

  function mboxEscape(body) {
    return String(body).split("\n").map(l => (/^>*From /.test(l) ? ">" + l : l)).join("\n");
  }

  const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const ISO_DATE = /(\d{4})-(\d\d)-(\d\d)[ T]+(\d\d):(\d\d)(?::(\d\d))?\s*(?:UTC|GMT|Z)?/;

  // The site writes dates as "1992-01-15 11:32UTC"; the news server wants "Wed, 15 Jan 1992 11:32:00 +0000".
  // Anything else is passed through (news-import repairs what the server would not take).
  function normalizeDate(s) {
    const m = ISO_DATE.exec(String(s || ""));
    if (!m) return String(s || "").trim();
    const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0)));
    if (isNaN(d.getTime())) return String(s).trim();
    const p2 = n => (n < 10 ? "0" : "") + n;
    return DAYS[d.getUTCDay()] + ", " + p2(d.getUTCDate()) + " " + MONTHS[d.getUTCMonth()] + " " + d.getUTCFullYear() + " " +
      p2(d.getUTCHours()) + ":" + p2(d.getUTCMinutes()) + ":" + p2(d.getUTCSeconds()) + " +0000";
  }

  // "#1 my 1992-01-15 11:32UTC" -> {n: 1, author: "my", date: "1992-01-15 11:32UTC"}, or null
  function parseMessageHead(text) {
    const t = String(text || "").replace(/\s+/g, " ").trim();
    const m = /^#(\d+)\s+(.*?)\s*(\d{4}-\d\d-\d\d[ T]+\d\d:\d\d(?::\d\d)?\s*(?:UTC|GMT|Z)?)\s*$/.exec(t);
    return m ? { n: +m[1], author: m[2].trim(), date: m[3].trim() } : null;
  }

  // A From: a news server takes: the site shows an author as a bare name ("my") or with its address hidden
  // ("m..@ber..c.com"); a header with no usable address gets a made-up one, the name kept as the display name.
  function fromHeader(s) {
    const f = cleanHeader(s);
    if (/[^\s<>@]+@[^\s<>@]+\.[A-Za-z]{2,}/.test(f) && !/[\u00b7\u2026]/.test(f)) return f;
    const name = f.replace(/<[^>]*>/g, "").replace(/[\u00b7\u2026]+/g, "").replace(/["\\()<>@]/g, "").replace(/\s+/g, " ").trim();
    return (name ? '"' + name + '" ' : "") + "<anonymous@archive.invalid>";
  }
  // "From sender Day Mon  D HH:MM:SS YYYY" - the date of the article if JS can read it, else 1 Jan 1980
  // (news-import takes the real Date: header; this is only its fallback)
  function fromLine(dateStr) {
    let d = new Date(normalizeDate(dateStr));
    if (isNaN(d.getTime()) || d.getUTCFullYear() < 1970 || d.getUTCFullYear() > 2100) d = new Date(Date.UTC(1980, 0, 1));
    const p2 = n => (n < 10 ? "0" : "") + n;
    return "From usenetarchives " + DAYS[d.getUTCDay()] + " " + MONTHS[d.getUTCMonth()] + " " +
      (d.getUTCDate() < 10 ? " " : "") + d.getUTCDate() + " " + p2(d.getUTCHours()) + ":" + p2(d.getUTCMinutes()) + ":" +
      p2(d.getUTCSeconds()) + " " + d.getUTCFullYear();
  }

  // An mbox of articles: {from, subject, date, newsgroups, msgId, refs, url, body}.  Headers the site did
  // not give are left out; news-import makes up what it needs (a Message-ID from a hash, a Path, ...).
  function buildMbox(msgs) {
    return msgs.map(m => {
      const h = [fromLine(m.date)];
      const add = (k, v) => { v = cleanHeader(v); if (v) h.push(k + ": " + v); };
      add("From", fromHeader(m.from));
      add("Newsgroups", m.newsgroups);
      add("Subject", m.subject || "(none)");
      add("Date", normalizeDate(m.date));
      add("Message-ID", m.msgId);
      add("References", m.refs);
      add("X-Archive-URL", m.url);
      return h.join("\n") + "\n\n" + mboxEscape(m.body) + "\n\n";
    }).join("");
  }

  function safeFileName(group) {
    return "usenet-" + String(group).replace(/[^A-Za-z0-9._+-]+/g, "_") + ".mbox";
  }

  // The thread lists of this site are one page per group and YEAR (threads.php?id=GROUP&y=1991), so a group's
  // biggest threads are found by looking at every year in range.  "1980-1995", "1991" or "" (every year).
  function parseYears(text) {
    const m = /^\s*(\d{4})?\s*(?:[-–:]\s*(\d{4})?)?\s*$/.exec(String(text || ""));
    if (!m) return null;
    const from = m[1] ? +m[1] : 0;
    const to = m[2] ? +m[2] : (m[1] && !/[-–:]/.test(text) ? +m[1] : 9999);
    return from <= to ? { from, to } : null;
  }

  // the year a page address names (&y=1991), 0 when it names none
  function yearOf(url) {
    const m = /[?&]y=(\d{4})\b/.exec(String(url || ""));
    return m ? +m[1] : 0;
  }

  // true when the sizes never grow down the list.  A year's thread list is paged (100 a page) and comes sorted by
  // Posts, biggest first, so its first page holds the year's biggest threads; if a list is not in that order the
  // first page may not, and the run says so.
  function sortedDescending(sizes) {
    for (let i = 1; i < sizes.length; i++) if (sizes[i] > sizes[i - 1]) return false;
    return true;
  }

  function inYears(year, range) {
    return !year || (year >= range.from && year <= range.to);     // a page whose year is unknown is not left out
  }

  // How many requests a run makes at most, for the "are you sure" box: per group its page, one page per further
  // year, and one page per thread (the whole thread is on one page).
  function estimate(groups, threads, years) {
    return groups * (1 + Math.max(0, years - 1) + threads);
  }

  const core = { parseCount, rankTop, stripQuotes, isEmptyBody, cleanHeader, mboxEscape, normalizeDate, parseMessageHead, fromHeader,
                 fromLine, buildMbox, safeFileName, parseYears, yearOf, inYears, sortedDescending, estimate };
  if (typeof module !== "undefined" && module.exports) { module.exports = core; return; }

  // ============================================================== browser only from here ===
  const doc = root.document;
  const STORE = "usenetSample.v1";
  const sleep = ms => new Promise(r => setTimeout(r, ms));

  // ------------------------------------------------------------------ SITE (not tested) ---
  // Everything that knows what usenetarchives.com looks like.  Guesses from a screenshot of the group
  // list (columns GROUP, DESCRIPTION, THREADS, POSTS); fix here when Probe shows what the pages really are.
  const SITE = {
    // the tables of a document, as {head: [lower-case header texts], rows: [tr elements]}
    tables(d) {
      return Array.from(d.querySelectorAll("table")).map(t => {
        const trs = Array.from(t.querySelectorAll("tr"));
        const headRow = trs.find(tr => tr.querySelector("th")) || trs[0];
        const head = headRow ? Array.from(headRow.children).map(c => c.textContent.trim().toLowerCase()) : [];
        return { head, rows: trs.filter(tr => tr !== headRow && tr.querySelector("td")) };
      });
    },
    col(head, ...names) {
      return head.findIndex(h => names.some(n => h.indexOf(n) >= 0));
    },
    abs(href, base) {
      try { return new URL(href, base).href; } catch (e) { return ""; }
    },
    // groups listed in a document: [{name, url, threads, posts}]
    groups(d, base) {
      for (const t of SITE.tables(d)) {
        const g = SITE.col(t.head, "group"), th = SITE.col(t.head, "thread"), po = SITE.col(t.head, "post");
        if (g < 0 || (th < 0 && po < 0)) continue;
        const out = [];
        t.rows.forEach(tr => {
          const cells = Array.from(tr.children), a = cells[g] && cells[g].querySelector("a[href]");
          if (!a) return;
          out.push({ name: a.textContent.trim(), url: SITE.abs(a.getAttribute("href"), base),
                     threads: th >= 0 ? parseCount(cells[th] && cells[th].textContent) : 0,
                     posts: po >= 0 ? parseCount(cells[po] && cells[po].textContent) : 0 });
        });
        if (out.length) return out;
      }
      // no table: links that look like group names, in page order (nothing to rank by)
      const seen = new Set(), out = [];
      d.querySelectorAll("a[href]").forEach(a => {
        const n = a.textContent.trim();
        if (/^[a-z0-9+_-]+(\.[a-z0-9+_-]+)+$/i.test(n) && !seen.has(n)) { seen.add(n); out.push({ name: n, url: SITE.abs(a.getAttribute("href"), base), threads: 0, posts: 0 }); }
      });
      return out;
    },
    // The years a group's threads are split into, from the page's year buttons ("1991 (2,731)"): [{year, count, url}].
    // The year being shown may be a button that is not a link; the caller counts the page itself.
    years(d, base) {
      const out = [], seen = new Set();
      d.querySelectorAll("a[href]").forEach(a => {
        const m = /^(\d{4})\s*\((\d[\d,]*)\)$/.exec(a.textContent.trim());
        const u = SITE.abs(a.getAttribute("href"), base);
        if (m && u && !seen.has(u)) { seen.add(u); out.push({ year: +m[1], count: parseCount(m[2]), url: u }); }
      });
      return out;
    },
    // threads listed on a group page: [{subject, url, size}]
    threads(d, base) {
      for (const t of SITE.tables(d)) {
        const s = SITE.col(t.head, "subject", "thread", "title"), z = SITE.col(t.head, "post", "repl", "message", "count");
        if (s < 0) continue;
        const out = [];
        t.rows.forEach((tr, i) => {
          const cells = Array.from(tr.children), a = cells[s] && cells[s].querySelector("a[href]");
          if (!a) return;
          out.push({ subject: a.textContent.trim(), url: SITE.abs(a.getAttribute("href"), base),
                     size: z >= 0 ? parseCount(cells[z] && cells[z].textContent) : 0 });
        });
        if (out.length) return out;
      }
      const out = [], seen = new Set();
      d.querySelectorAll("a[href]").forEach(a => {
        const u = SITE.abs(a.getAttribute("href"), base);
        if (/view\.php|thread|message|article|post|msg/i.test(a.getAttribute("href")) && !seen.has(u) && a.textContent.trim()) {
          seen.add(u); out.push({ subject: a.textContent.trim(), url: u, size: 0 });
        }
      });
      return out;
    },
    // The subject of a thread page: the heading that is neither the site's name nor the group's.
    subject(d, url) {
      let group = ""; try { group = new URL(url).searchParams.get("id") || ""; } catch (e) { /* no url */ }
      for (const h of Array.from(d.querySelectorAll("h1, h2, h3"))) {
        const t = h.textContent.trim();
        if (t && t.toLowerCase() !== "usenet archives" && t.toLowerCase() !== group.toLowerCase()) return t;
      }
      return "";
    },
    // the messages of a thread page, in order: [{from, subject, date, msgId, refs, body}].
    // The layout seen on view.php (from a screenshot): a card per message, its header "#1 author 1992-01-15 11:32UTC",
    // the text in the element after it.  The whole thread is on the page, and "Thread Overview" (a list of
    // "author date" with no "#N") is not a message.
    messages(d, url) {
      const heads = Array.from(d.querySelectorAll("body *")).filter(e => {
        const t = (e.textContent || "").trim();
        return t.length < 200 && parseMessageHead(t) !== null &&
          !Array.from(e.children).some(c => parseMessageHead((c.textContent || "").trim()) !== null);   // the innermost
      });
      if (heads.length) {
        const subject = SITE.subject(d, url);
        const out = [];
        heads.forEach(h => {
          const info = parseMessageHead(h.textContent);
          let body = h.nextElementSibling;
          if (!body || !(body.textContent || "").trim()) body = h.parentElement && h.parentElement.nextElementSibling;
          const text = body ? (body.innerText || body.textContent) : "";
          if (text.trim()) out.push({ from: info.author, subject, date: info.date, msgId: "", refs: "", body: text });
        });
        if (out.length) return out;
      }
      return SITE.messagesGeneric(d);
    },
    // the fallback for a page laid out some other way: containers with RFC 822 style header lines, or <pre> blocks
    messagesGeneric(d) {
      let boxes = Array.from(d.querySelectorAll("article, .post, .message, .msg, [id^='msg'], [id^='post'], [class*='message']"));
      boxes = boxes.filter(b => !boxes.some(o => o !== b && b.contains(o)));       // innermost only
      if (!boxes.length) {
        boxes = Array.from(d.querySelectorAll("pre")).map(pre => pre.parentElement);
      }
      const field = (text, name) => { const m = new RegExp("^\\s*" + name + ":[ \\t]*(.*)$", "im").exec(text); return m ? m[1].trim() : ""; };
      const out = [];
      boxes.forEach(b => {
        const pre = b.querySelector("pre");
        const text = (b.innerText || b.textContent || "");
        const head = text.split(/\n\s*\n/)[0] + "\n" + text.slice(0, 600);
        const body = pre ? (pre.innerText || pre.textContent) : text.replace(/^(?:\s*(?:From|Date|Subject|Newsgroups|Message-ID|References|To|Organization):.*\n)+/i, "");
        if (!body.trim()) return;
        out.push({ from: field(head, "From"), subject: field(head, "Subject"), date: field(head, "Date"),
                   msgId: field(head, "Message-ID"), refs: field(head, "References"), body });
      });
      return out;
    },
    // a link to the next page of a long thread, or ""
    next(d, base) {
      const a = d.querySelector("a[rel='next']") || Array.from(d.querySelectorAll("a[href]")).find(x => /^(next|older|more)\b|»|›/i.test(x.textContent.trim()));
      return a ? SITE.abs(a.getAttribute("href"), base) : "";
    },
  };

  // ------------------------------------------------------------------ probe ---
  // A few hundred lines of the page's structure (tags, ids, classes, the start of the text), to be pasted to
  // whoever fixes SITE.  Public page text only; nothing from your account.
  function skeleton(d, limit) {
    const lines = [];
    const sig = e => e.tagName.toLowerCase() + (e.id ? "#" + e.id : "") + (e.className && typeof e.className === "string" ? "." + e.className.trim().split(/\s+/).join(".") : "");
    (function walk(e, depth) {
      if (lines.length >= limit || depth > 8) return;
      const kids = Array.from(e.children);
      let i = 0;
      while (i < kids.length && lines.length < limit) {
        const k = kids[i];
        let j = i;
        while (j + 1 < kids.length && sig(kids[j + 1]) === sig(k)) j++;
        const own = Array.from(k.childNodes).filter(n => n.nodeType === 3).map(n => n.textContent.trim()).join(" ").slice(0, 50);
        const href = k.tagName === "A" ? " href=" + (k.getAttribute("href") || "").slice(0, 70) : "";
        lines.push("  ".repeat(depth) + sig(k) + href + (own ? "  \"" + own + "\"" : "") + (j > i ? "   (x" + (j - i + 1) + ")" : ""));
        walk(k, depth + 1);
        i = j + 1;
      }
    })(d.body, 0);
    return lines.join("\n");
  }

  function probeText() {
    const tabs = SITE.tables(doc).map(t => "table head: " + JSON.stringify(t.head) + "  rows: " + t.rows.length).join("\n");
    return ["URL: " + location.href, "TITLE: " + doc.title, tabs, "---", skeleton(doc, 300)].join("\n");
  }

  // ------------------------------------------------------------------ run ---
  class Halt extends Error {}

  async function getDoc(url, ui) {
    const r = await fetch(url, { credentials: "same-origin" });   // allowlist secret: a fetch option, not a credential
    if ([403, 429, 503].indexOf(r.status) >= 0) throw new Halt("The site answered " + r.status + " - stopping, as it asked. Try again later, slower.");
    if (!r.ok) { ui.log("skipped " + url + " (" + r.status + ")"); return null; }
    return new DOMParser().parseFromString(await r.text(), "text/html");
  }

  function load() { try { return JSON.parse(localStorage.getItem(STORE)) || { doneGroups: [] }; } catch (e) { return { doneGroups: [] }; } }
  function save(s) { try { localStorage.setItem(STORE, JSON.stringify(s)); } catch (e) { /* no storage: no resume */ } }

  function download(name, text) {
    const a = doc.createElement("a");
    a.href = URL.createObjectURL(new Blob([text], { type: "text/plain;charset=utf-8" }));
    a.download = name;
    doc.body.appendChild(a);
    a.click();
    setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 2000);
  }

  async function run(cfg, ui) {
    const state = load();
    const found = SITE.groups(doc, location.href);
    if (!found.length) throw new Halt("No group list on this page. Open a page that lists groups (with a GROUP column) and press Run again - or press Probe and send what it copies.");
    const groups = rankTop(found, found.some(g => g.posts) ? "posts" : "threads", cfg.groups);
    const todo = groups.filter(g => state.doneGroups.indexOf(g.name) < 0);
    const nYears = cfg.years.to >= 9999 ? 15 : Math.min(40, cfg.years.to - (cfg.years.from || cfg.years.to - 14) + 1);   // a guess, for the estimate only
    const reqs = estimate(todo.length, cfg.threads, nYears);
    if (!root.confirm("Sample " + groups.map(g => g.name).join(", ") + "\n\n" + (groups.length - todo.length) + " already done.\n" +
        "Years " + (cfg.years.from || "first") + " - " + (cfg.years.to >= 9999 ? "last" : cfg.years.to) + ".\n" +
        "Up to " + reqs + " requests, one every ~" + (cfg.delay / 1000).toFixed(1) + " s (about " + Math.ceil(reqs * cfg.delay / 60000) + " minutes), " +
        "one mbox file per group.\n\nStart?")) return;
    const pause = () => sleep(cfg.delay + Math.random() * cfg.delay * 0.5);
    for (const g of todo) {
      if (ui.stopped) break;
      ui.say("group " + g.name);
      const gd = await getDoc(g.url, ui); await pause();
      if (!gd) continue;
      // the thread lists are per year: this page's, then each other year's in range
      const lists = [];                                   // one list of threads per page read
      const here = yearOf(g.url);
      if (inYears(here, cfg.years)) lists.push(SITE.threads(gd, g.url));
      for (const y of SITE.years(gd, g.url)) {
        if (ui.stopped) break;
        if (y.url === g.url || (here && y.year === here) || !inYears(y.year, cfg.years)) continue;
        ui.say(g.name + ": year " + y.year);
        const yd = await getDoc(y.url, ui); await pause();
        if (yd) lists.push(SITE.threads(yd, y.url));
      }
      let threads = [].concat(...lists);
      const seenT = new Set();
      threads = threads.filter(t => !seenT.has(t.url) && seenT.add(t.url));
      // each year's first page (100 threads) is read, which is the year's biggest only while the list is sorted by Posts
      if (threads.some(t => t.size) && lists.some(l => l.length > 1 && !sortedDescending(l.map(t => t.size)))) {
        ui.log(g.name + ": a thread list is not sorted by Posts, biggest first - its first page may miss big threads");
      }
      if (!threads.length) { ui.log(g.name + ": no threads found on " + g.url + " (or none in those years) - Probe that page"); continue; }
      const pick = threads.some(t => t.size) ? rankTop(threads, "size", cfg.threads) : threads.slice(0, cfg.threads);
      const msgs = [];
      for (const t of pick) {
        if (ui.stopped) break;
        ui.say(g.name + ": " + t.subject.slice(0, 40) + " (" + msgs.length + " messages)");
        let url = t.url, got = [], pages = 0;
        while (url && got.length < cfg.messages && pages < 6) {
          const td = await getDoc(url, ui); await pause();
          if (!td) break;
          got = got.concat(SITE.messages(td, url).map(m => Object.assign({ url }, m)));
          pages++;
          url = got.length < cfg.messages ? SITE.next(td, url) : "";
        }
        if (!got.length) ui.log(g.name + ": no messages found in \"" + t.subject.slice(0, 40) + "\" (" + t.url + ")");
        got.slice(0, cfg.messages).forEach(m => {
          const body = stripQuotes(m.body, { signature: cfg.signature });
          if (isEmptyBody(body)) return;                       // nothing but quoting
          msgs.push({ from: m.from, subject: m.subject || t.subject, date: m.date, newsgroups: g.name, msgId: m.msgId, refs: m.refs, url: m.url, body });
        });
      }
      if (ui.stopped) { ui.log("stopped inside " + g.name + " - it is not saved; Run again to redo it"); break; }
      if (msgs.length) { download(safeFileName(g.name), buildMbox(msgs)); ui.log(g.name + ": " + msgs.length + " messages saved"); }
      state.doneGroups.push(g.name); save(state);
    }
    ui.say(ui.stopped ? "stopped" : "done");
  }

  // ------------------------------------------------------------------ the box ---
  function ui() {
    const box = doc.createElement("div");
    box.style.cssText = "position:fixed;right:12px;bottom:12px;z-index:99999;width:300px;font:12px system-ui,sans-serif;background:#fff;color:#111;border:1px solid #888;border-radius:6px;padding:8px;box-shadow:0 2px 8px #0004";
    box.innerHTML = '<b>Usenet sampler</b> <span id="us-st" style="color:#555">ready</span>' +
      '<div style="margin:6px 0">groups <input id="us-g" size=2 value=20> threads <input id="us-t" size=2 value=20> messages <input id="us-m" size=2 value=20>' +
      '<br>years <input id="us-y" size=9 value="1980-2000"> (blank = all)' +
      '<br>delay ms <input id="us-d" size=4 value=1500> <label><input id="us-s" type=checkbox checked> strip signatures</label></div>' +
      '<button id="us-run">Run</button> <button id="us-stop">Stop</button> <button id="us-probe">Probe</button> <button id="us-reset">Forget done</button>' +
      '<pre id="us-log" style="max-height:120px;overflow:auto;margin:6px 0 0;white-space:pre-wrap"></pre>';
    doc.body.appendChild(box);
    const $ = id => box.querySelector("#" + id);
    const o = { stopped: false,
      say(t) { $("us-st").textContent = t; },
      log(t) { const p = $("us-log"); p.textContent += t + "\n"; p.scrollTop = p.scrollHeight; } };
    const num = (id, dflt, min) => Math.max(min, parseInt($(id).value, 10) || dflt);
    $("us-run").onclick = async () => {
      o.stopped = false;
      const cfg = { groups: num("us-g", 20, 1), threads: num("us-t", 20, 1), messages: num("us-m", 20, 1), years: parseYears($("us-y").value) || { from: 0, to: 9999 }, delay: num("us-d", 1500, 500), signature: $("us-s").checked };
      try { await run(cfg, o); } catch (e) { o.say("stopped"); o.log(e instanceof Halt ? e.message : "error: " + e); }
    };
    $("us-stop").onclick = () => { o.stopped = true; o.say("stopping..."); };
    $("us-reset").onclick = () => { save({ doneGroups: [] }); o.log("done-list cleared"); };
    $("us-probe").onclick = async () => {
      const t = probeText();
      try { await navigator.clipboard.writeText(t); o.log("page structure copied (" + t.length + " chars) - paste it to the maintainer"); }
      catch (e) { const ta = doc.createElement("textarea"); ta.value = t; ta.style.cssText = "width:100%;height:80px"; box.appendChild(ta); ta.select(); o.log("copy this text (Ctrl-C) and paste it to the maintainer"); }
    };
  }

  if (doc && doc.body) ui();
})(typeof window !== "undefined" ? window : globalThis);

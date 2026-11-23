#!/usr/bin/env node
// Tests for the tested core of bin/usenetarchives-sample.user.js (quote stripping, mbox writing, ranking).
// The SITE part of that script (what usenetarchives.com looks like) needs a browser and is not tested here.
//
//   node news-setup/tests/test_usenet_sample.js [OUT.mbox]     (OUT.mbox: also write a sample mbox, for news-import)
"use strict";
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const c = require(path.join(__dirname, "..", "bin", "usenetarchives-sample.user.js"));

let passed = 0;
function t(name, fn) { fn(); passed++; console.log("  ok    " + name); }

t("parseCount reads the site's numbers", () => {
  assert.strictEqual(c.parseCount("30,661"), 30661);
  assert.strictEqual(c.parseCount(" 3 "), 3);
  assert.strictEqual(c.parseCount(""), 0);
  assert.strictEqual(c.parseCount(undefined), 0);
});

t("rankTop: biggest first, ties keep page order, n respected, input untouched", () => {
  const g = [{ n: "a", p: 5 }, { n: "b", p: 9 }, { n: "c", p: 5 }, { n: "d", p: 1 }];
  assert.deepStrictEqual(c.rankTop(g, "p", 3).map(x => x.n), ["b", "a", "c"]);
  assert.deepStrictEqual(g.map(x => x.n), ["a", "b", "c", "d"]);
  assert.deepStrictEqual(c.rankTop(g, "p", 20).length, 4);
});

t("stripQuotes: layers of > and the line that introduces them", () => {
  const text = [
    "In article <123@utzoo.UUCP>, henry@utzoo.UUCP (Henry Spencer) writes:",
    "> > I think C is fine.",
    "> No, it isn't.",
    "",
    "It is, though.  Consider the alternatives.",
    "",
    "bob wrote:",
    "> and more",
    "so there.",
  ].join("\n");
  assert.strictEqual(c.stripQuotes(text), "It is, though.  Consider the alternatives.\n\nso there.");
});

t("stripQuotes: an attribution split over two lines, other quote marks, deleted-text markers", () => {
  const text = "In article <1@x>, Alan Turing\nwrites:\n> hello\n|pipe quoted\n  > indented quote\n[quoted text deleted]\nReal text.\n";
  assert.strictEqual(c.stripQuotes(text), "Real text.");
});

t("stripQuotes: ordinary lines that merely mention writing are kept", () => {
  const text = "He said: the answer is 42.\nShe wrote: nothing, and then\nthe list:\n  - a > b\n  - c\n";
  assert.strictEqual(c.stripQuotes(text), "He said: the answer is 42.\nShe wrote: nothing, and then\nthe list:\n  - a > b\n  - c");
});

t("stripQuotes: the signature goes, a dashes line early in the text stays", () => {
  assert.strictEqual(c.stripQuotes("Body.\n\n-- \nHenry Spencer\nU of Toronto\n"), "Body.");
  assert.strictEqual(c.stripQuotes("Body.\n\n-- \nSig\n", { signature: false }), "Body.\n\n--\nSig");   // trailing blanks go from every line
  const long = ["-- ", ...Array.from({ length: 30 }, (_, i) => "line " + i)].join("\n");
  assert.ok(c.stripQuotes(long).startsWith("--"), "a '-- ' line not near the end is not a signature");
});

t("stripQuotes: blank runs shrink, CRLF is read, nothing left is empty", () => {
  assert.strictEqual(c.stripQuotes("\n\na\r\n\r\n\r\n\r\nb\n\n\n"), "a\n\nb");
  assert.strictEqual(c.stripQuotes("> only a quote\n> another\n"), "");
  assert.strictEqual(c.stripQuotes(null), "");
});

t("isEmptyBody", () => {
  assert.ok(c.isEmptyBody(""));
  assert.ok(c.isEmptyBody("\n -- \n"));
  assert.ok(!c.isEmptyBody("ok"));
});

t("mboxEscape protects From lines, as mbox does", () => {
  assert.strictEqual(c.mboxEscape("a\nFrom here\n>From there\nFromage"), "a\n>From here\n>>From there\nFromage");
});

t("normalizeDate: the site's ISO form becomes an RFC 5322 date, anything else is left alone", () => {
  assert.strictEqual(c.normalizeDate("1992-01-15 11:32UTC"), "Wed, 15 Jan 1992 11:32:00 +0000");
  assert.strictEqual(c.normalizeDate("1981-02-03T04:05:06Z"), "Tue, 03 Feb 1981 04:05:06 +0000");
  assert.strictEqual(c.normalizeDate("Sat, 7 Mar 87 10:00:00 PST"), "Sat, 7 Mar 87 10:00:00 PST");
  assert.strictEqual(c.normalizeDate(""), "");
  assert.strictEqual(c.normalizeDate(undefined), "");
});

t("parseMessageHead: '#1 my 1992-01-15 11:32UTC' is a message header, the overview line is not", () => {
  assert.deepStrictEqual(c.parseMessageHead("#1 my 1992-01-15 11:32UTC"), { n: 1, author: "my", date: "1992-01-15 11:32UTC" });
  assert.deepStrictEqual(c.parseMessageHead("  #12\n  Linus Torvalds   1991-08-25 20:57UTC "),
                         { n: 12, author: "Linus Torvalds", date: "1991-08-25 20:57UTC" });
  assert.strictEqual(c.parseMessageHead("my 1992-01-15 11:32UTC"), null);
  assert.strictEqual(c.parseMessageHead("#1 my wrote something"), null);
  assert.strictEqual(c.parseMessageHead("#3 no date"), null);
  assert.deepStrictEqual(c.parseMessageHead("#2  1992-01-15 11:32UTC"), { n: 2, author: "", date: "1992-01-15 11:32UTC" });
});

t("fromHeader: a name alone or a hidden address gets a made-up one; a real one stays", () => {
  assert.strictEqual(c.fromHeader("my"), '"my" <anonymous@archive.invalid>');
  assert.strictEqual(c.fromHeader("m··@ber··c.com"), '"mberc.com" <anonymous@archive.invalid>');
  assert.strictEqual(c.fromHeader("Henry Spencer <henry@utzoo.UUCP>"), "Henry Spencer <henry@utzoo.UUCP>");
  assert.strictEqual(c.fromHeader("bob@example.org (Bob)"), "bob@example.org (Bob)");
  assert.strictEqual(c.fromHeader(""), "<anonymous@archive.invalid>");
  assert.strictEqual(c.fromHeader('A "quoted" <weird>\nname'), '"A quoted name" <anonymous@archive.invalid>');
});

t("fromLine: a readable date, else 1 Jan 1980", () => {
  assert.strictEqual(c.fromLine("Mon, 01 Sep 1986 10:00:00 +0000"), "From usenetarchives Mon Sep  1 10:00:00 1986");
  assert.strictEqual(c.fromLine("whenever"), "From usenetarchives Tue Jan  1 00:00:00 1980");
  assert.strictEqual(c.fromLine(""), "From usenetarchives Tue Jan  1 00:00:00 1980");
  assert.strictEqual(c.fromLine("1992-01-15 11:32UTC"), "From usenetarchives Wed Jan 15 11:32:00 1992");
});

const sample = [
  { from: "Henry Spencer <henry@utzoo.UUCP>", subject: "Re: C is fine", date: "Mon, 01 Sep 1986 10:00:00 +0000",
    newsgroups: "net.lang.c", msgId: "<123@utzoo.UUCP>", refs: "<100@utzoo.UUCP>", url: "https://usenetarchives.com/x/1",
    body: "It is, though.\nFrom the start.\n" },
  { from: "bob@x\nBcc: evil@x", subject: "line\twith\ttabs", date: "", newsgroups: "net.lang.c", msgId: "", refs: "", url: "", body: "second" },
];

t("buildMbox: headers cleaned, empty ones left out, From_ line, escaped body", () => {
  const m = c.buildMbox(sample);
  const msgs = m.split(/\n\n(?=From usenetarchives )/);
  assert.strictEqual(msgs.length, 2);
  assert.ok(msgs[0].startsWith("From usenetarchives Mon Sep  1 10:00:00 1986\nFrom: Henry Spencer <henry@utzoo.UUCP>\nNewsgroups: net.lang.c\n"));
  assert.ok(m.includes("Message-ID: <123@utzoo.UUCP>\nReferences: <100@utzoo.UUCP>\nX-Archive-URL: https://usenetarchives.com/x/1\n\nIt is, though.\n>From the start.\n"));
  assert.ok(!/^Bcc:/m.test(m), "a header cannot be injected through a field");
  assert.ok(m.includes("Subject: line with tabs\n"));
  assert.ok(!/^Date: ?$/m.test(m) && !/^Message-ID: ?$/m.test(msgs[1]), "empty fields are not written");
});

t("parseYears: a range, one year, open ends, nonsense", () => {
  assert.deepStrictEqual(c.parseYears("1980-2000"), { from: 1980, to: 2000 });
  assert.deepStrictEqual(c.parseYears("1991"), { from: 1991, to: 1991 });
  assert.deepStrictEqual(c.parseYears(" 1985 - "), { from: 1985, to: 9999 });
  assert.deepStrictEqual(c.parseYears("-1995"), { from: 0, to: 1995 });
  assert.deepStrictEqual(c.parseYears(""), { from: 0, to: 9999 });
  assert.strictEqual(c.parseYears("2000-1980"), null);
  assert.strictEqual(c.parseYears("the eighties"), null);
});

t("yearOf, inYears: a page with no year is never left out", () => {
  assert.strictEqual(c.yearOf("https://usenetarchives.com/threads.php?id=comp.os.minix&y=1991&p=2"), 1991);
  assert.strictEqual(c.yearOf("https://usenetarchives.com/threads.php?id=comp.os.minix"), 0);
  assert.strictEqual(c.yearOf("https://usenetarchives.com/threads.php?id=x&yy=1991"), 0);
  const r = { from: 1980, to: 1995 };
  assert.ok(c.inYears(1991, r) && c.inYears(0, r));
  assert.ok(!c.inYears(1996, r) && !c.inYears(1979, r));
});

t("sortedDescending: Posts, biggest first", () => {
  assert.ok(c.sortedDescending([7, 7, 6, 6, 5, 4, 4, 4, 1]));
  assert.ok(c.sortedDescending([]) && c.sortedDescending([3]));
  assert.ok(!c.sortedDescending([7, 8, 6]));
});

t("safeFileName, estimate", () => {
  assert.strictEqual(c.safeFileName("comp.os.minix"), "usenet-comp.os.minix.mbox");
  assert.strictEqual(c.safeFileName("a/b c"), "usenet-a_b_c.mbox");
  assert.strictEqual(c.estimate(20, 20, 15), 20 * (1 + 14 + 20));
});

if (process.argv[2]) {
  fs.writeFileSync(process.argv[2], c.buildMbox(sample));
}
console.log("usenetarchives-sample core: " + passed + " passed");

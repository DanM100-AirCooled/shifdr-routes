// Events checks (spec §9). Run: npm install, then
//   EVENT_CODES='{"open":"…","closed":"…","cancelled":"…","draft":"…"}' ROUTE_ID=<uuid> npm test
// Make the drives with tests/fixture.sql (it prints both values) and remove them with tests/cleanup.sql.
// Optional: BASE=https://<preview>.vercel.app to test a deployed copy instead of a local server,
// BROWSER=chrome to use Chrome instead of Edge.
//
// What this covers: the drive-time maths (lunch clock, second meetup), the REST API as a signed-out
// visitor, and the pages a signed-out visitor sees: invite links, the event page at phone size,
// plus a pass over the builder and Discover. Signed-in roles are covered by tests/rls.sql.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";
import { serve } from "./serve.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");
const codes = JSON.parse(process.env.EVENT_CODES || "null");
const routeId = process.env.ROUTE_ID;
if (!codes?.open || !codes.closed || !codes.cancelled || !codes.draft || !routeId) {
  console.error("Set EVENT_CODES and ROUTE_ID from tests/fixture.sql first.");
  process.exit(2);
}
const SUPABASE_URL = html.match(/SUPABASE_URL = "([^"]+)"/)[1], SUPABASE_KEY = html.match(/SUPABASE_KEY = "([^"]+)"/)[1];

let failed = 0;
async function check(name, fn) {
  try { const note = await fn(); console.log(`PASS ${name}${note ? `: ${note}` : ""}`); }
  catch (err) { failed++; console.log(`FAIL ${name}: ${err.message.split("\n")[0]}`); }
}
function ok(cond, msg) { if (!cond) throw new Error(msg); }

/* ---------- the app's own functions, lifted out of index.html ---------- */
function source(name) {
  const at = html.search(new RegExp(`\\n\\s*function ${name}\\(`));
  if (at < 0) {
    const line = html.match(new RegExp(`\\nconst ${name} = [^\\n]+`));
    if (!line) throw new Error(`${name} not found in index.html`);
    return line[0];
  }
  let i = html.indexOf("{", html.indexOf(")", at)), depth = 0;
  for (; i < html.length; i++) {
    if (html[i] === "{") depth++;
    else if (html[i] === "}" && --depth === 0) break;
  }
  return html.slice(at, i + 1);
}
const names = ["tzOffsetMs", "zonedToUtc", "utcToZoned", "fmtClock", "etaAtMile", "evArrival", "lunchClock", "codeFromUrl", "carText", "rosterCsv"];
const app = new Function("location", `"use strict";${names.map(source).join("\n")}\nreturn { ${names.join(", ")} };`);
const fn = app({ pathname: "/", search: "" });
const codeFrom = (pathname, search = "") => app({ pathname, search }).codeFromUrl();

/* ---------- 6, 7. drive-time maths ---------- */
const mi = 1609.344;
const toy = { segments: [{ distance: mi, duration: 60 }, { distance: 2 * mi, duration: 240 }] };
await check("6 etaAtMile, toy route", () => {
  ok(fn.etaAtMile(toy, 1) === 60 && fn.etaAtMile(toy, 2) === 180 && fn.etaAtMile(toy, 9) === 300, "expected 60, 180, 300 s");
});
const route = (await (await fetch(`${SUPABASE_URL}/rest/v1/routes?id=eq.${routeId}&select=name,data`, { headers: { apikey: SUPABASE_KEY } })).json())[0];
await check("6 etaAtMile at the pit stop matches a hand sum of segment times", () => {
  const pit = route.data.stops.find(s => s.type === "pit");
  ok(pit, "the fixture route has no pit stop");
  let acc = 0, t = 0, hand = null;
  for (const s of route.data.segments) {
    if (hand === null && acc + s.distance >= pit.mile * mi) hand = t + (pit.mile * mi - acc) / s.distance * s.duration;
    acc += s.distance; t += s.duration;
  }
  const got = fn.etaAtMile(route.data, pit.mile);
  ok(Math.abs(got - hand) < 60, `${got} vs ${hand}`);
  return `mile ${pit.mile.toFixed(1)}, ${Math.round(got / 60)} min`;
});
const start = fn.zonedToUtc("2026-11-14", "08:30", "America/Chicago");
const ev = { tz: "America/Chicago", snap: toy, meetups: [{ mile: 0 }], regroups: [{ mile: 1 }], meal: { ll: [0, 0], mile: 2 } };
await check("7 group 1's ETA adds 10 min per regroup", () => {
  const at = fn.fmtClock(fn.evArrival(ev, start, 2), ev.tz);
  ok(at === "8:43 AM", at);   // 3 min of driving + 10 min regroup
});
await check("7 second meetup default is group 1's ETA there", () => {
  const e2 = { ...ev, regroups: [] }, at = fn.fmtClock(fn.evArrival(e2, start, 1), ev.tz);
  ok(at === "8:31 AM", at);
});
await check("6 lunch clock thresholds", () => {
  const seat = min => new Date(new Date(start).getTime() + min * 60000).toISOString();
  const lv = min => fn.lunchClock(ev, start, seat(min));
  ok(lv(13 + 36).level === "" && lv(13 + 21).level === "amber" && lv(13 + 10).level === "red" && lv(13 - 5).level === "red", "levels");
  ok(/21 min before last seating/.test(lv(13 + 21).text) && /5 min after last seating/.test(lv(13 - 5).text), lv(13 - 5).text);
});
await check("8 codes in links", () => {
  ok(codeFrom("/e/K7Q4MZ") === "K7Q4MZ" && codeFrom("/e/k7q-4mz") === "K7Q4MZ" && codeFrom("/", "?e=k7q-4mz") === "K7Q4MZ" && codeFrom("/", "?r=x") === null, "parse");
});
await check("4 roster CSV quotes commas and quotes", () => {
  const csv = fn.rosterCsv({ meetups: [{ name: "Buc-ee's, Katy" }] }, [{ id: 1, display_name: 'Al "Big" Smith', phone: "555", role: "driver",
    car: { year: 1973, make: "Porsche", model: "911" }, extra_people: 1, seats_open: 2, meetup_index: 0, rsvp: "in", source: "web" }]);
  ok(csv.startsWith("﻿Name,Phone") && csv.includes('"Al ""Big"" Smith",555,driver,1973 Porsche 911,1,2,,,"Buc-ee\'s, Katy",In,Web\r\n'), csv);
});

/* ---------- 2, 5. REST API as a signed-out visitor ---------- */
const rest = (p, init = {}) => fetch(`${SUPABASE_URL}/rest/v1/${p}`, { ...init, headers: { apikey: SUPABASE_KEY, "Content-Type": "application/json", Prefer: "return=representation", ...init.headers } });
const rpc = async code => (await rest("rpc/event_by_code", { method: "POST", body: JSON.stringify({ code }) })).json();
await check("2 anon select events returns nothing", async () => { const r = await (await rest("events?select=*")).json(); ok(Array.isArray(r) && !r.length, JSON.stringify(r)); });
await check("2 anon select event_people returns nothing", async () => { const r = await (await rest("event_people?select=*")).json(); ok(Array.isArray(r) && !r.length, JSON.stringify(r)); });
await check("2 anon event_by_code: counts, no names or phones", async () => {
  const r = await rpc(codes.open);
  ok(r && r.counts && r.roster === null && !("organizer_notes" in r && r.organizer_notes), JSON.stringify(r).slice(0, 200));
});
await check("2 invalid and draft codes return nothing", async () => { ok(await rpc("ZZZZZZ") === null && await rpc(codes.draft) === null, "got a drive"); });
await check("5 anon cannot edit an event or join", async () => {
  const up = await (await rest(`events?code=eq.${codes.open}`, { method: "PATCH", body: JSON.stringify({ title: "hacked" }) })).json();
  ok(Array.isArray(up) && !up.length, JSON.stringify(up));
  ok((await rpc(codes.open)).title !== "hacked", "title changed");
  const ins = await rest("event_people", { method: "POST", body: JSON.stringify({ event_id: "00000000-0000-0000-0000-000000000000", display_name: "x" }) });
  ok(ins.status === 401 || ins.status === 403, `status ${ins.status}`);
});
await check("5 profiles.phone hidden from anon", async () => { const r = await rest("profiles?select=phone&limit=1"); ok(r.status >= 400, `status ${r.status}`); });

/* ---------- 8, 9, 10. pages in a browser ---------- */
const server = process.env.BASE ? null : await serve(8799);
const BASE = (process.env.BASE || "http://127.0.0.1:8799").replace(/\/$/, "");
const browser = await chromium.launch({ channel: process.env.BROWSER === "chrome" ? "chrome" : "msedge" });
const errors = [];
async function page(url, size = { width: 1280, height: 800 }) {
  const ctx = await browser.newContext({ viewport: size, acceptDownloads: true });
  const p = await ctx.newPage();
  p.on("pageerror", e => errors.push(`${url}: ${e.message}`));
  await p.goto(BASE + url);
  return p;
}
const openRow = await rpc(codes.open);
const evText = async p => { await p.waitForSelector("#evPage:not([hidden]) h2", { timeout: 20000 }); return p.locator("#evPage").textContent(); };   // textContent: headings are uppercased by CSS

try {
  for (const [label, url] of [["/e/CODE", `/e/${codes.open}`], ["/e/code-with-dash", `/e/${codes.open.slice(0, 3).toLowerCase()}-${codes.open.slice(3).toLowerCase()}`], ["?e=CODE", `/?e=${codes.open}`]]) {
    await check(`8 ${label} opens the drive`, async () => {
      const p = await page(url), t = await evText(p);
      ok(t.includes("[test] Open drive"), t.slice(0, 120));
      const m1 = openRow.meetups[1], want = `Group 2 waits at ${m1.name}, about ${fn.fmtClock(m1.depart_at, openRow.time_zone)}.`;
      ok(t.includes(want), `no "${want}"`);
      ok(await p.getByRole("button", { name: "Join on the web" }).isVisible(), "no join button");
      await p.context().close();
    });
  }
  await check("8 ?r=<route id> opens the route page", async () => {
    const p = await page(`/?r=${routeId}`);
    await p.waitForSelector("#pubDetail:not([hidden]) h2", { timeout: 20000 });
    ok((await p.locator("#pubDetail h2").textContent()).includes(route.name), "wrong route");
    await p.context().close();
  });
  for (const [label, code] of [["unknown", "ZZZZZZ"], ["draft", codes.draft]]) {
    await check(`8 ${label} code shows the friendly message`, async () => {
      const p = await page(`/e/${code}`), t = await evText(p);
      ok(t.includes("Drive not found") && t.includes("Check the code with the organizer"), t.slice(0, 120));
      await p.context().close();
    });
  }
  await check("4 closed sign-ups: no join button", async () => {
    const p = await page(`/e/${codes.closed}`), t = await evText(p);
    ok(t.includes("Sign-ups are closed.") && !(await p.getByRole("button", { name: "Join on the web" }).count()), "join still offered");
    await p.context().close();
  });
  await check("4 cancelled drive shows Cancelled", async () => {
    const p = await page(`/e/${codes.cancelled}`), t = await evText(p);
    ok(/Cancelled/.test(t) && t.includes("Test reason"), t.slice(0, 160));
    await p.context().close();
  });
  for (const [label, url] of [["event page", `/e/${codes.open}`], ["route page", `/?r=${routeId}`]]) {
    await check(`9 ${label} at 360×740: no sideways scroll, buttons 40 px+`, async () => {
      const p = await page(url, { width: 360, height: 740 });
      await p.waitForSelector(url.startsWith("/e/") ? "#evPage:not([hidden]) h2" : "#pubDetail:not([hidden]) h2", { timeout: 20000 });
      await p.waitForTimeout(500);
      const r = await p.evaluate(() => {
        const wide = [...document.querySelectorAll("body *")].filter(n => n.getBoundingClientRect().right > innerWidth + 1 && n.offsetParent && !n.closest(".maplibregl-map"));
        const small = [...document.querySelectorAll("#evPage .btn, #evPage button:not(.linkbtn)")]   // the event page; route pages keep their older, smaller buttons
          .filter(b => b.offsetParent && b.getBoundingClientRect().height < 40).map(b => `${b.textContent.trim()} ${Math.round(b.getBoundingClientRect().height)}px`);
        return { sw: document.scrollingElement.scrollWidth, wide: wide.slice(0, 3).map(n => n.className || n.tagName), small };
      });
      ok(r.sw <= 360 && !r.wide.length, `scrollWidth ${r.sw}, wide: ${r.wide.join(", ")}`);
      ok(!r.small.length, `short buttons: ${r.small.join("; ")}`);
      await p.context().close();
    });
  }

  /* 10. nothing broken: Discover, route page, reverse, GPX out and back in, builder, road check */
  const p = await page(`/?r=${routeId}`);
  await p.waitForSelector("#pubDetail:not([hidden]) h2", { timeout: 20000 });
  let gpxFile = null;
  await check("10 ratings show for a signed-out visitor", async () => { ok(await p.getByRole("button", { name: "Sign in to rate this route" }).isVisible(), "no rating prompt"); });
  await check("10 reverse on the route page", async () => {
    await p.getByRole("button", { name: /^Reverse/ }).click();
    ok(await p.getByRole("button", { name: "Reversed: tap to restore" }).isVisible(), "not reversed");
  });
  await check("10 export GPX from the route page", async () => {
    const [dl] = await Promise.all([p.waitForEvent("download"), p.getByRole("button", { name: "Export GPX" }).click()]);
    gpxFile = await dl.path();
    const gpx = fs.readFileSync(gpxFile, "utf8");
    ok(gpx.includes("<trkpt") && gpx.includes("<wpt"), "no track or waypoints");
    return dl.suggestedFilename();
  });
  await check("10 road check runs on the route page", async () => {
    await p.getByRole("button", { name: "Check road work on this route" }).click();
    await p.waitForFunction(() => /possible issue|Nothing found|didn't finish/.test(document.getElementById("roadDiscover")?.innerText || ""), null, { timeout: 90000 });
    const t = await p.locator("#roadDiscover").innerText();
    ok(!/didn't finish/.test(t), "the check didn't finish");
    return t.match(/(\d+ possible issues?|Nothing found)[^.]*/)?.[0];
  });
  await check("10 Discover lists routes in view", async () => {
    await p.getByRole("button", { name: "← All routes" }).click();
    await p.waitForSelector("#pubList li", { timeout: 20000 });
    return `${await p.locator("#pubList li").count()} routes`;
  });
  await check("10 open in builder, reverse, export JSON", async () => {
    await p.locator("#pubList li").filter({ hasText: route.name }).first().click();
    await p.waitForSelector("#pubDetail:not([hidden]) h2");
    await p.getByRole("button", { name: /in builder$/ }).click();
    await p.waitForSelector("#tBuild[aria-pressed=true]");
    await p.click("#bReverse");
    ok(/Reversed/.test(await p.locator("#status").innerText()), "no reversed note");
    const [dl] = await Promise.all([p.waitForEvent("download"), p.click("#bExport")]);
    const rec = JSON.parse(fs.readFileSync(await dl.path(), "utf8"));
    ok(rec.format === "shifdr.route/v1" || rec.segments?.length, "not a route file");
  });
  await check("10 import the exported GPX", async () => {
    ok(gpxFile, "no GPX from the earlier step");
    const named = path.join(path.dirname(gpxFile), "events-test.gpx");
    fs.copyFileSync(gpxFile, named);
    await p.setInputFiles("#fImport", named);
    await p.waitForFunction(() => /Imported/.test(document.getElementById("status").innerText), null, { timeout: 60000 });
    return (await p.locator("#status").innerText()).split("\n")[0];
  });
  await p.context().close();
  await check("10 no page errors", () => { ok(!errors.length, errors.join(" | ")); });
} finally {
  await browser.close();
  server?.close();
}
console.log(failed ? `\n${failed} failed` : "\nAll passed");
process.exit(failed ? 1 : 0);

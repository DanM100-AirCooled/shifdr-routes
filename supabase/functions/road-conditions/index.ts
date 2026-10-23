// Road conditions along a route: construction, closures and other hazards.
// POST { line: [[lng, lat], ...], date: "YYYY-MM-DD", osm?: OverpassElement[] }
// Returns issues that sit on the route, each with its mile along the route and links to the source.
//
// Sources
//  - TxDOT DriveTexas conditions (construction, closures, flooding, damage). Needs the DRIVETEXAS_KEY secret.
//  - Work Zone Data Exchange (WZDx) feeds that need no key: City of Austin, Louisiana, Oklahoma, New Mexico.
//    Only fetched when the route passes through that feed's area.
//  - OpenStreetMap roads tagged as under construction. The browser fetches these from Overpass
//    and passes them in as `osm` (Overpass elements with geometry); they're matched here.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

type LL = [number, number];
type Issue = {
  source: string; source_label: string; kind: string; severity: "high" | "medium" | "low";
  title: string; description: string; where: string; start: string | null; end: string | null;
  mile_from: number; mile_to: number; at: LL; on_route: "along" | "at";
  links: { label: string; url: string }[];
};

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

/* ---------- geometry ---------- */
const R = 6371008.8, RAD = Math.PI / 180;
function hav(a: LL, b: LL) {
  const dLat = (b[1] - a[1]) * RAD, dLng = (b[0] - a[0]) * RAD;
  const s = Math.sin(dLat / 2) ** 2 + Math.cos(a[1] * RAD) * Math.cos(b[1] * RAD) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(s));
}
const CELL = 0.005; // ~500 m grid for finding nearby route segments
class Route {
  pts: LL[]; cum: number[]; grid = new Map<string, number[]>(); bbox: [number, number, number, number];
  kx: number;
  constructor(pts: LL[]) {
    this.pts = pts; this.cum = [0];
    for (let i = 1; i < pts.length; i++) this.cum.push(this.cum[i - 1] + hav(pts[i - 1], pts[i]));
    let [x0, y0, x1, y1] = [180, 90, -180, -90];
    for (const [x, y] of pts) { x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y); }
    this.bbox = [x0, y0, x1, y1];
    this.kx = Math.cos(((y0 + y1) / 2) * RAD);
    for (let i = 0; i < pts.length - 1; i++) {
      const [a, b] = [pts[i], pts[i + 1]];
      for (let cx = Math.floor(Math.min(a[0], b[0]) / CELL); cx <= Math.floor(Math.max(a[0], b[0]) / CELL); cx++)
        for (let cy = Math.floor(Math.min(a[1], b[1]) / CELL); cy <= Math.floor(Math.max(a[1], b[1]) / CELL); cy++) {
          const k = cx + ":" + cy; (this.grid.get(k) ?? this.grid.set(k, []).get(k)!).push(i);
        }
    }
  }
  get length() { return this.cum[this.cum.length - 1]; }
  inBox(p: LL, pad = 0.01) {
    const [x0, y0, x1, y1] = this.bbox;
    return p[0] >= x0 - pad && p[0] <= x1 + pad && p[1] >= y0 - pad && p[1] <= y1 + pad;
  }
  /** Distance (m) from p to the route, and how far along the route (m) the nearest point is. */
  nearest(p: LL): { d: number; along: number } {
    const cx = Math.floor(p[0] / CELL), cy = Math.floor(p[1] / CELL);
    const seen = new Set<number>(); let best = { d: Infinity, along: 0 };
    const mx = 111320 * this.kx, my = 110540;
    for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) {
      for (const i of this.grid.get((cx + dx) + ":" + (cy + dy)) ?? []) {
        if (seen.has(i)) continue; seen.add(i);
        const a = this.pts[i], b = this.pts[i + 1];
        const ax = (a[0] - p[0]) * mx, ay = (a[1] - p[1]) * my, bx = (b[0] - p[0]) * mx, by = (b[1] - p[1]) * my;
        const vx = bx - ax, vy = by - ay, l2 = vx * vx + vy * vy;
        const t = l2 ? Math.max(0, Math.min(1, -(ax * vx + ay * vy) / l2)) : 0;
        const d = Math.hypot(ax + t * vx, ay + t * vy);
        if (d < best.d) best = { d, along: this.cum[i] + t * (this.cum[i + 1] - this.cum[i]) };
      }
    }
    return best;
  }
}
/** Points every ~40 m along a line, so long straight pieces are tested along their length. */
function densify(line: LL[]): LL[] {
  const out: LL[] = [];
  for (let i = 0; i < line.length; i++) {
    if (i) {
      const a = line[i - 1], b = line[i], n = Math.min(200, Math.floor(hav(a, b) / 40));
      for (let k = 1; k < n; k++) out.push([a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n]);
    }
    out.push(line[i]);
  }
  return out;
}
function linesOf(g: any): LL[][] {
  if (!g) return [];
  switch (g.type) {
    case "Point": return [[g.coordinates]];
    case "MultiPoint": return [g.coordinates];
    case "LineString": return [g.coordinates];
    case "MultiLineString": return g.coordinates;
    case "Polygon": return [g.coordinates[0]];
    case "MultiPolygon": return g.coordinates.map((p: any) => p[0]);
    case "GeometryCollection": return g.geometries.flatMap(linesOf);
    default: return [];
  }
}
/** Does this geometry run along the route, or sit right on it? Returns where, or null. */
function match(route: Route, geom: any, tolAlong = 50, tolAt = 70) {
  const lines = linesOf(geom).filter((l) => l.length && l.some((p) => route.inBox(p)));
  if (!lines.length) return null;
  const isPoint = lines.every((l) => l.length === 1);
  let lo = Infinity, hi = -Infinity, hits = 0, minD = Infinity, minAlong = 0;
  for (const l of lines) for (const p of densify(l)) {
    if (!route.inBox(p)) continue;
    const n = route.nearest(p);
    if (n.d < minD) { minD = n.d; minAlong = n.along; }
    if (n.d <= tolAlong) { hits++; lo = Math.min(lo, n.along); hi = Math.max(hi, n.along); }
  }
  if (isPoint) return minD <= tolAt ? { from: minAlong, to: minAlong, kind: "at" as const } : null;
  // Along the route: several matching points spanning at least ~120 m of the route.
  if (hits >= 3 && hi - lo >= 120) return { from: lo, to: hi, kind: "along" as const };
  return null; // only crosses the route (a cross street or overpass), so it's not an issue for this drive
}
const pointAt = (route: Route, along: number): LL => {
  const c = route.cum; let i = 0;
  while (i < c.length - 2 && c[i + 1] < along) i++;
  const t = c[i + 1] > c[i] ? (along - c[i]) / (c[i + 1] - c[i]) : 0;
  const a = route.pts[i], b = route.pts[i + 1] ?? a;
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
};
const mapLink = (p: LL) => `https://www.openstreetmap.org/?mlat=${p[1].toFixed(5)}&mlon=${p[0].toFixed(5)}#map=16/${p[1].toFixed(5)}/${p[0].toFixed(5)}`;
const clean = (s: unknown) => String(s ?? "").replace(/<br\s*\/?>/gi, " ").replace(/<[^>]+>/g, "").replace(/\s+/g, " ").replace(/^[-\s]+/, "").trim();
/** Is the event in effect at any time on the drive day? Missing dates count as ongoing. */
function activeOn(start: string | null, end: string | null, day: string) {
  const d0 = new Date(day + "T00:00:00-06:00").getTime(), d1 = d0 + 86400000;
  const s = start ? Date.parse(start) : -Infinity, e = end ? Date.parse(end) : Infinity;
  return (isNaN(s) ? -Infinity : s) < d1 && (isNaN(e) ? Infinity : e) > d0;
}
async function getJSON(url: string, init: RequestInit = {}, ms = 20000) {
  const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), ms);
  try {
    const r = await fetch(url, { ...init, signal: ctl.signal, headers: { "User-Agent": "ShifdrRoutes/1.0 (road-conditions)", ...(init.headers || {}) } });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return await r.json();
  } finally { clearTimeout(t); }
}
const cache = new Map<string, { t: number; data: any }>();
async function cached(key: string, ttlMs: number, load: () => Promise<any>) {
  const hit = cache.get(key);
  if (hit && Date.now() - hit.t < ttlMs) return hit.data;
  const data = await load(); cache.set(key, { t: Date.now(), data }); return data;
}

/* ---------- TxDOT DriveTexas ---------- */
async function txdot(route: Route, day: string): Promise<Issue[]> {
  const key = Deno.env.get("DRIVETEXAS_KEY");
  if (!key) throw new Error("not_configured");
  const data = await cached("txdot", 10 * 60000, () => getJSON(`https://api.drivetexas.org/api/conditions.geojson?key=${encodeURIComponent(key)}`));
  const out: Issue[] = [];
  for (const f of data.features ?? []) {
    const p = f.properties ?? {};
    if (!activeOn(p.startTime ?? null, p.endTime ?? null, day)) continue;
    const m = match(route, f.geometry); if (!m) continue;
    const type = String(p.type || p.condition || "Condition");
    const kind = type.toLowerCase();
    const severity = /closure|closed|flood|damage/.test(kind) || p.detourFlag ? "high" : p.delayFlag || /construction/.test(kind) ? "medium" : "low";
    const road = [p.RTE_NM, p.RDWAY_NM].filter(Boolean).join(" / ").replace(/^(FM|SH|US|IH|RM|BS|SL|SS|PR)0*(\d+)/, "$1 $2");
    const at = pointAt(route, m.from);
    out.push({
      source: "txdot", source_label: "TxDOT DriveTexas", kind, severity,
      title: `${type}${road ? " on " + road : ""}`,
      description: clean(p.description) + (p.detourFlag ? " Detour in place." : ""),
      where: [p.COND_LMT_FROM_DSCR, p.COND_LMT_TO_DSCR].filter(Boolean).join(" to "),
      start: p.startTime ?? null, end: p.endTime ?? null,
      mile_from: m.from / 1609.344, mile_to: m.to / 1609.344, at, on_route: m.kind,
      links: [{ label: "DriveTexas map", url: "https://drivetexas.org/" }, { label: "Map location", url: mapLink(at) }],
    });
  }
  return out;
}

/* ---------- WZDx feeds that need no key ---------- */
const WZDX = [
  { id: "austin", label: "City of Austin work zones", bbox: [-98.1, 30.0, -97.4, 30.65], url: "https://data.austintexas.gov/download/d9mm-cjw9", site: "https://data.austintexas.gov/d/d9mm-cjw9" },
  { id: "louisiana", label: "Louisiana DOTD work zones", bbox: [-94.05, 28.9, -88.8, 33.02], url: "https://wzdx.e-dot.com/la_dot_d_feed_wzdx_v4.1.geojson", site: "https://511la.org" },
  { id: "oklahoma", label: "Oklahoma DOT work zones", bbox: [-103.0, 33.6, -94.4, 37.0], url: "https://oktraffic.org/api/Geojsons/workzones?&access_token=feOPynfHRJ5sdx8tf3IN5yOsGz89TAUuzHsN3V0jo1Fg41LcpoLhIRltaTPmDngD", site: "https://oktraffic.org" },
  { id: "newmexico", label: "New Mexico DOT work zones", bbox: [-109.05, 31.33, -103.0, 37.0], url: "https://ai.blyncsy.io/wzdx/nmdot/feed", site: "https://nmroads.com" },
];
const overlaps = (a: number[], b: number[]) => a[0] <= b[2] && a[2] >= b[0] && a[1] <= b[3] && a[3] >= b[1];
async function wzdx(feed: typeof WZDX[number], route: Route, day: string): Promise<Issue[]> {
  const data = await cached("wzdx:" + feed.id, 10 * 60000, () => getJSON(feed.url));
  const out: Issue[] = [];
  for (const f of data.features ?? []) {
    const p = f.properties ?? {}, core = p.core_details ?? p;
    if (core.event_type && !/work-zone|detour|restriction|incident|road-event/.test(core.event_type)) continue;
    const start = p.start_date ?? p.start_time ?? null, end = p.end_date ?? p.end_time ?? null;
    if (!activeOn(start, end, day)) continue;
    const m = match(route, f.geometry); if (!m) continue;
    const impact = String(p.vehicle_impact ?? "unknown");
    const severity = impact === "all-lanes-closed" || core.event_type === "detour" ? "high" : /some-lanes|alternating|shift|reduced/.test(impact) ? "medium" : "low";
    const road = (core.road_names ?? (core.road_name ? [core.road_name] : [])).join(" / ");
    const at = pointAt(route, m.from);
    out.push({
      source: feed.id, source_label: feed.label, kind: core.event_type || "work-zone", severity,
      title: `${impact === "all-lanes-closed" ? "Road closed" : "Work zone"}${road ? " on " + road : ""}${core.direction && core.direction !== "unknown" ? " (" + core.direction + ")" : ""}`,
      description: clean(core.description || core.name || "").slice(0, 400),
      where: impact.replace(/-/g, " "), start, end,
      mile_from: m.from / 1609.344, mile_to: m.to / 1609.344, at, on_route: m.kind,
      links: [{ label: "Source", url: feed.site }, { label: "Map location", url: mapLink(at) }],
    });
  }
  return out;
}

/* ---------- OpenStreetMap: roads tagged as under construction ----------
   Overpass doesn't answer requests from this server, so the browser fetches the OSM ways
   (construction-tagged roads in boxes along the route) and sends them here for matching. */
async function osm(route: Route, elements: any[]): Promise<Issue[]> {
  const data = { elements };
  const out: Issue[] = [];
  for (const el of data.elements ?? []) {
    if (!el.geometry) continue;
    const geom = { type: "LineString", coordinates: el.geometry.map((g: any) => [g.lon, g.lat]) };
    const m = match(route, geom, 30); if (!m) continue;
    const t = el.tags ?? {};
    const name = t.name || t.ref || "";
    const building = t.highway === "construction";
    const at = pointAt(route, m.from);
    out.push({
      source: "osm", source_label: "OpenStreetMap", kind: "construction", severity: "low",
      title: building ? `Road under construction next to the route${name ? ": " + name : ""}` : `Construction mapped on ${name || "this road"}`,
      description: [t.construction && `Construction: ${t.construction}`, t.opening_date && `Expected to open ${t.opening_date}`, t.note || t.description].filter(Boolean).join(". ") +
        ". Mapped by volunteers; it may be out of date.",
      where: "", start: null, end: t.opening_date ?? null,
      mile_from: m.from / 1609.344, mile_to: m.to / 1609.344, at, on_route: m.kind,
      links: [{ label: "OpenStreetMap", url: `https://www.openstreetmap.org/way/${el.id}` }, { label: "Map location", url: mapLink(at) }],
    });
  }
  return out;
}

/* ---------- handler ---------- */
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "Send JSON" }, 400); }
  const line: LL[] = Array.isArray(body?.line) ? body.line.filter((p: any) => Array.isArray(p) && isFinite(p[0]) && isFinite(p[1])) : [];
  if (line.length < 2 || line.length > 6000) return json({ error: "Send a route line with 2 to 6000 points." }, 400);
  const day = /^\d{4}-\d{2}-\d{2}$/.test(body?.date ?? "") ? body.date : new Date().toISOString().slice(0, 10);
  const route = new Route(line);

  const jobs: [string, string, Promise<Issue[]>][] = [["txdot", "TxDOT DriveTexas", txdot(route, day)]];
  for (const f of WZDX) if (overlaps(f.bbox, route.bbox)) jobs.push([f.id, f.label, wzdx(f, route, day)]);
  if (Array.isArray(body?.osm)) jobs.push(["osm", "OpenStreetMap", osm(route, body.osm.slice(0, 5000))]);

  const settled = await Promise.allSettled(jobs.map((j) => j[2]));
  const sources = jobs.map(([id, label], i) => {
    const s = settled[i];
    if (s.status === "fulfilled") return { id, label, status: "ok", count: s.value.length };
    const msg = String((s.reason as Error)?.message ?? s.reason);
    return { id, label, status: msg === "not_configured" ? "not_configured" : "error", detail: msg === "not_configured" ? undefined : msg.slice(0, 120) };
  });
  const rank = { high: 0, medium: 1, low: 2 };
  // The same work zone is often listed once per direction: merge those into one entry.
  const merged = new Map<string, Issue & { dirs: string[] }>();
  for (const i of settled.flatMap((s) => (s.status === "fulfilled" ? s.value : []))) {
    const dir = i.title.match(/\((\w+bound|both directions)\)$/)?.[1];
    const base = dir ? i.title.replace(/\s*\([^)]*\)$/, "") : i.title;
    const key = [i.source, base, i.description.slice(0, 80), i.mile_from.toFixed(2), i.mile_to.toFixed(2)].join("|");
    const prev = merged.get(key);
    if (!prev) merged.set(key, { ...i, title: base, dirs: dir ? [dir] : [] });
    else {
      if (dir && !prev.dirs.includes(dir)) prev.dirs.push(dir);
      if (rank[i.severity] < rank[prev.severity]) prev.severity = i.severity;
    }
  }
  const issues = [...merged.values()].map(({ dirs, ...i }) => ({
    ...i, title: dirs.length > 1 ? `${i.title} (both directions)` : dirs.length ? `${i.title} (${dirs[0]})` : i.title,
  })).sort((a, b) => a.mile_from - b.mile_from || rank[a.severity] - rank[b.severity]);
  return json({ date: day, route_miles: route.length / 1609.344, sources, issues });
});

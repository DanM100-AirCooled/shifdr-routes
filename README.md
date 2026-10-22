# Shifdr Routes

Map-first driving routes for car clubs. One static page (`index.html`, deployed on Vercel) plus a Supabase project for accounts and the shared route library.

## Route library (Phase 2)
- **Build / Discover tabs.** Discover shows public routes that cross the map view, with search and a distance filter. Click a card or a line on the map for the route's page: stops with mile markers, roads, Export GPX, Copy link, and Open in builder.
- **Share links:** `?r=<route id>` opens straight to a route.
- **Accounts:** sign in with Google or a 6-digit email code. The Google button shows only when the Google provider is on in Supabase. Saving while signed in stores the route in your library; tick **Public** to list it in Discover. Opening someone else's route and saving makes your own copy.
- **Backend:** Supabase project *Shifdr Routes*. Schema in `supabase/migrations/`. Row-level security lets anyone read public routes; only the owner can read private ones or change anything. A PostGIS trigger stores each route's line so `routes_in_view` can find routes by map area.

## How to use it
- **Opens on your location** if the browser allows it; otherwise on your last view, or Marble Falls. The target button jumps back to you.
- **Satellite** button (top right) switches between the street map and satellite imagery with road names. The choice is remembered.
- **Draw mode (default):** click a starting point, then hold and drag along the roads you want. The route snaps to the road network as you go.
- **Click** anywhere to extend the route to that point.
- **Drag an anchor** to move it; only the two segments touching it re-route.
- **Drag the route line** onto a different road; a new anchor is inserted there.
- **Pan:** right-click and drag, switch to Pan mode, or hold Space while drawing. Scroll or pinch to zoom.
- **Undo / Redo:** buttons or Ctrl/Cmd+Z and Shift+Ctrl/Cmd+Z.
- **Reverse** flips direction using the stored geometry, so the chosen roads don't change.
- **Loop** routes the end back to the start.
- **Clean up detours** drops points that pulled the route onto side streets. It only removes a point if the simpler path still passes where your finger was and isn't any longer. Undo restores the original.
- **Stops:** name the Start and Finish, and add numbered pit stops. *Find* searches places and addresses near the map view, or you can tap the map instead. Searching a Start or Finish moves that end of the route there. A pit stop is routed through and shows its mile marker. Clean up and loop trimming never remove a pit stop.
- **Test drive:** a car drives the route at the router's speed for each stretch, sped up 15–300×. It shows the current road, mile, clock and speed, pauses at pit stops, and flags possible U-turns, gaps and unsnapped pieces in red. Drag the slider to scrub; *next* jumps to the next issue. Drag the map to stop following.
- **Save** keeps routes in this browser; **Export GPX** saves the exact path as a GPX track for nav apps, with the named stops as waypoints; **Export JSON** gives the full Shifdr route file. **Import** opens a GPX (tracks keep their exact path; route-point files are routed between the points; waypoints on the route become Start, Finish and pit stops) or a Shifdr JSON file. A reopened route uses its stored geometry and is never re-routed.

## Search
- With a Mapbox token: Mapbox geocoding. Without: Photon (OpenStreetMap), with Nominatim as a backup. You can also paste coordinates like `30.5752, -98.2731`.

## Routing
- Without a key it uses Esri street map tiles and the free OSRM demo router. Good enough to test the interaction, but slow and rate-limited.
- Paste a Mapbox public token under *Map & routing settings* to switch to Mapbox Directions and Mapbox Outdoors tiles.
- The map is drawn with MapLibre GL, the open-source fork of Mapbox GL JS. The API is the same, so moving to Mapbox GL JS later is a small change.

## How it preserves road choice
- Tracing drops an anchor roughly every 40 screen pixels. Each anchor pair is routed separately, so the router never gets a long enough gap to substitute a faster road.
- Where an anchor snaps just past an intersection, the router produces a short out-and-back spur. Those spurs are trimmed at the joints before distance is calculated.
- Small detour loops (the route leaving and returning to the same spot within 500 m) are cut out automatically.
- Distance comes from the final trimmed geometry. Drive time is the router's estimate, scaled to match.

## Saved route format (`shifdr.route/v1`)
`anchors` (the ordered road-selection constraints), `segments` (per-segment geometry, distance, time, road names), `geometry` (MultiLineString, ready for a PostGIS column), plus `start_name`, `finish_name`, `stops` (type, name, location, mile), `distance_m`, `duration_s`, `roads`, `is_loop`, and `router`. Pit stops are anchors with a `pit` name.

## Things to test in the Hill Country
- RR 1431 between Marble Falls and Kingsland: winding road with lake-side side streets.
- US 281 through Marble Falls: frontage roads and the bridge.
- Park Road 4 and the roads around Inks Lake.
- Deliberately take a slower road where a faster one runs parallel, then save, reload, and confirm the same path comes back.

## Known limits
- Fast tracing on the OSRM demo server lags behind the cursor. Mapbox is noticeably quicker.
- Reverse keeps the original geometry, so on a divided highway it will show the opposite lane.
- Routes saved locally live only in that browser. Supabase storage comes in Phase 2.

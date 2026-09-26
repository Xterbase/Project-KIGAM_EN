// web/assets/app.js — dashboard behaviour.
// The file layout comes embedded in the page (boot); curves, SAR, dose response and models come from api.php → R (run.R).
// R only returns data; the drawing happens here.
'use strict';

const B = JSON.parse(document.getElementById('boot').textContent);
const I = B.inspect;
const SG = I.single_grain;

const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
const C = {
  ink: css('--forest-ink'), pass: css('--pass'), fail: css('--fail'), fit: css('--muted-sage'), data: css('--emerald'),
  natural: css('--indigo-accent'), muted: css('--slate-smoke'), line: css('--lichen'), moss: css('--moss'), font: css('--font'),
};
// The default toolbar is hidden. Controls: drag = box zoom, double-click = reset; the only tools are the magnifier and expand buttons at the chart box's top right.
const PC = { responsive: true, displaylogo: false, displayModeBar: false, doubleClick: 'reset', showTips: false };
const AX = { gridcolor: C.line, griddash: 'dot', zeroline: false, linecolor: C.ink, linewidth: 0.5 };
// Axis titles sit 30px from the tick labels (the zoom guide line goes in that gap). The left and bottom margins are wider to match.
const ax = o => ({ ...AX, ...o, ...(typeof o.title === 'string' ? { title: { text: o.title, standoff: 30 } } : {}) });
const BASE = {
  margin: { l: 86, r: 18, t: 40, b: 70 }, font: { family: C.font, size: 12, color: C.ink },
  paper_bgcolor: 'rgba(0,0,0,0)', plot_bgcolor: 'rgba(0,0,0,0)', legend: { orientation: 'h', y: -0.22 },
};
const title = text => ({ text, font: { size: 14 }, x: 0, xanchor: 'left' });

const SIGMAB = { single_grain: 0.20, single_aliquot: 0.15 };  // 0.20: literature-backed, 0.15: legacy default (unconfirmed)
const MODE_LABEL = { single_grain: 'Single grain', single_aliquot: 'Single aliquot' };

const fmt = (v, d = 1) => v == null ? '—' : Number(v).toFixed(d);
const arr = v => v == null ? [] : [].concat(v);
const $ = id => document.getElementById(id);
function el(tag, text, cls) { const e = document.createElement(tag); if (text != null) e.textContent = text; if (cls) e.className = cls; return e; }
const parseRange = s => { const m = /^\s*(\d+)\s*:\s*(\d+)\s*$/.exec(s || ''); return m ? [+m[1], +m[2]] : null; };

// ---- R calls. While a request is pending, the chip at the lower left says so.
let pending = 0;
function busy(d) { pending += d; $('chip').textContent = 'R computing'; $('chip').classList.toggle('show', pending > 0); }
async function api(action, args) {
  busy(1);
  try {
    const res = await fetch('api.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id: B.id, action, args }) });
    let j;
    try { j = await res.json(); } catch { throw new Error(`Could not read the server response (HTTP ${res.status})`); }
    if (!j.ok) throw new Error(j.error || 'Unknown error');
    return j;
  } finally { busy(-1); }
}
// Curves and dose responses are identical for identical inputs, so each is fetched once (removed on failure so it can be retried).
const cache = new Map();
function cached(action, args) {
  const k = action + JSON.stringify(args);
  if (!cache.has(k)) cache.set(k, api(action, args).catch(e => { cache.delete(k); throw e; }));
  return cache.get(k);
}
function plotMessage(div, msg) {
  const d = $(div); if (window.Plotly) Plotly.purge(d);   // purge also removes event handlers, so the next plot() attaches them again
  d._events = false; hideAxes(d); d.replaceChildren(el('div', msg, 'empty'));
}

// ---- Charts, shared: every draw goes through plot(). A new draw resets the zoom, so the ranges at that moment are remembered as the 'full range'.
const ICON = {
  zin: '<svg viewBox="0 0 24 24"><circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5 21 21M10.5 7.5v6M7.5 10.5h6"/></svg>',
  zout: '<svg viewBox="0 0 24 24"><circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5 21 21M7.5 10.5h6"/></svg>',
  exp: '<svg viewBox="0 0 24 24"><path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7"/></svg>',   // ↗↙ expand
  shr: '<svg viewBox="0 0 24 24"><path d="M4 14h6v6M20 10h-6V4M14 10l7-7M3 21l7-7"/></svg>',    // ↙↗ restore size
};
const gdOf = d => typeof d === 'string' ? $(d) : d;
const isSide = gd => !!gd.closest('.dash.expanded') && !gd.closest('.big');   // a small cell on the right while one chart is expanded
// The legend goes below the x-axis title (78px from the axis). Plotly positions legends as a fraction of the plot height, so it is recomputed per height.
// In the small cells on the right the legend would overlap the axis title, so it is hidden.
function legendLayout(gd) {
  const on = gd._legend && !isSide(gd), b = on ? 124 : BASE.margin.b, h = Math.max(120, (gd.clientHeight || 380) - BASE.margin.t - b);
  return { showlegend: on, 'margin.b': b, 'legend.y': -78 / h, 'legend.yanchor': 'top' };
}
function plot(div, data, layout) {
  const gd = gdOf(div);
  gd._legend = layout.showlegend !== false;
  const L = legendLayout(gd);
  const p = Plotly.react(gd, data, { ...layout, showlegend: L.showlegend, margin: { ...BASE.margin, b: L['margin.b'] },
    legend: { ...BASE.legend, y: L['legend.y'], yanchor: 'top' } }, PC);
  gd._home = { x: [...gd._fullLayout.xaxis.range], y: [...gd._fullLayout.yaxis.range] };
  if (!gd._track) addTools(gd);
  if (!gd._events) {
    gd._events = true;
    gd.on('plotly_relayout', () => syncAxes(gd));
    gd.on('plotly_afterplot', () => { fitTitle(gd); syncAxes(gd); });   // re-measure tick and axis-title positions after a resize too
  }
  fitTitle(gd); syncAxes(gd);
  return p;
}
const rangeOf = (gd, a) => [...gd._fullLayout[a + 'axis'].range];
const isZoomed = (gd, a) => { const h = gd._home[a], c = rangeOf(gd, a), e = (h[1] - h[0]) * 1e-3; return c[0] > h[0] + e || c[1] < h[1] - e; };

// Adds the tool buttons (magnifier −/+, plus expand on the four dashboard cells) and the two axis zoom guides to a chart box, once.
function addTools(gd) {
  const box = gd.parentElement, tools = el('div', null, 'ptools');
  const btn = (k, tip, fn) => { const b = el('button', null, k); b.type = 'button'; b.innerHTML = ICON[k]; b.title = tip; b.onclick = fn; tools.append(b); return b; };
  btn('zout', 'Zoom out', () => zoomBy(gd, 1.6));
  btn('zin', 'Zoom in (around the centre)', () => zoomBy(gd, 1 / 1.6));
  if (box.parentElement.classList.contains('dash')) btn('exp', 'Expand', () => toggleBig(box));
  box.append(tools);
  gd._track = {};
  for (const a of ['x', 'y']) {
    const t = el('div', null, 'axtrack ' + a), th = el('div', null, 'axthumb'), tip = el('div', 'Drag to move', 'axtip');
    t.append(th); box.append(t, tip);
    gd._track[a] = { t, th, tip };
    dragThumb(gd, a);
  }
}
// If the title overlaps the tool buttons at the top right horizontally (narrow cell), widen the box top so the title drops below the button row.
// Only horizontal positions are compared, so changing the top padding cannot flip the result.
function fitTitle(gd) {
  const ttl = gd.querySelector('.gtitle'), tools = gd.parentElement.querySelector('.ptools');
  if (!ttl || !tools) return;
  gd.parentElement.classList.toggle('crowded', ttl.getBoundingClientRect().right > tools.getBoundingClientRect().left - 6);
}
function hideAxes(gd) { if (gd._track) Object.values(gd._track).forEach(({ t, tip }) => { t.classList.remove('show'); tip.classList.remove('show'); }); }

// Shows the guide (line + dot) only on a zoomed axis. Dot = the centre of the visible part within the full range.
// Line position = the middle of the gap between the axis title and the tick labels (measured from the drawn text).
function syncAxes(gd) {
  if (!gd._track) return;
  if (!gd._fullLayout || !gd._home || !gd.data) { hideAxes(gd); return; }
  const s = gd._fullLayout._size, ox = gd.offsetLeft, oy = gd.offsetTop, B = gd.parentElement.getBoundingClientRect();
  const rects = q => [...gd.querySelectorAll(q)].map(e => e.getBoundingClientRect()).filter(r => r.width);
  for (const a of ['x', 'y']) {
    const { t, th, tip } = gd._track[a], z = isZoomed(gd, a), was = t.classList.contains('show');
    t.classList.toggle('show', z);
    if (!z) { tip.classList.remove('show'); continue; }
    const h = gd._home[a], c = rangeOf(gd, a), span = h[1] - h[0];
    const mid = (Math.max(0, (c[0] - h[0]) / span) + Math.min(1, (c[1] - h[0]) / span)) / 2;
    if (a === 'y') {
      const ticks = rects('.ytick text'), ttl = rects('.g-ytitle text')[0];
      const tickL = ticks.length ? Math.min(...ticks.map(r => r.left)) - B.left : ox + s.l - 30;
      const cx = ((ttl ? ttl.right - B.left : tickL - 24) + tickL) / 2;
      Object.assign(t.style, { left: cx - 8 + 'px', top: oy + s.t + 'px', width: '16px', height: s.h + 'px' });
      Object.assign(th.style, { left: '8px', top: (1 - mid) * s.h + 'px' });
      Object.assign(tip.style, { left: cx + 14 + 'px', top: oy + s.t + (1 - mid) * s.h - 11 + 'px' });
    } else {
      const ticks = rects('.xtick text'), ttl = rects('.g-xtitle text')[0];
      const tickB = ticks.length ? Math.max(...ticks.map(r => r.bottom)) - B.top : oy + s.t + s.h + 22;
      const cy = (tickB + (ttl ? ttl.top - B.top : tickB + 24)) / 2;
      Object.assign(t.style, { left: ox + s.l + 'px', top: cy - 8 + 'px', width: s.w + 'px', height: '16px' });
      Object.assign(th.style, { left: mid * s.w + 'px', top: '8px' });
      Object.assign(tip.style, { left: ox + s.l + mid * s.w - 30 + 'px', top: cy - 36 + 'px' });
    }
    if (!was && !gd._tipShown) { gd._tipShown = true; tip.classList.add('show'); setTimeout(() => tip.classList.remove('show'), 2600); }   // only the first time
  }
}

// Dragging the dot shifts that axis's visible range at the same width. Clicking elsewhere on the line moves that spot to the centre.
function dragThumb(gd, a) {
  const { t, th } = gd._track[a];
  const len = () => a === 'y' ? t.clientHeight : t.clientWidth;
  const clampTo = (h, lo, w) => { lo = Math.min(Math.max(lo, h[0]), h[1] - w); return [lo, lo + w]; };
  let start = null, raf = 0;
  th.addEventListener('pointerdown', e => {
    e.preventDefault(); e.stopPropagation(); th.setPointerCapture(e.pointerId); th.classList.add('drag');
    start = { p: a === 'y' ? e.clientY : e.clientX, r: rangeOf(gd, a) };
  });
  th.addEventListener('pointermove', e => {
    if (!start) return;
    const h = gd._home[a], d = ((a === 'y' ? start.p - e.clientY : e.clientX - start.p) / len()) * (h[1] - h[0]);
    const next = clampTo(h, start.r[0] + d, start.r[1] - start.r[0]);
    cancelAnimationFrame(raf); raf = requestAnimationFrame(() => Plotly.relayout(gd, { [a + 'axis.range']: next }));
  });
  const end = () => { start = null; th.classList.remove('drag'); };
  th.addEventListener('pointerup', end); th.addEventListener('pointercancel', end);
  t.addEventListener('pointerdown', e => {
    if (e.target !== t) return;
    const r = t.getBoundingClientRect(), f = a === 'y' ? 1 - (e.clientY - r.top) / r.height : (e.clientX - r.left) / r.width;
    const h = gd._home[a], c = rangeOf(gd, a), w = c[1] - c[0];
    tween(gd, { [a]: clampTo(h, h[0] + f * (h[1] - h[0]) - w / 2, w) });
  });
}

// Changes ranges smoothly (ease-out, 280ms).
function tween(gd, to) {
  const from = {}; for (const a in to) from[a] = rangeOf(gd, a);
  const t0 = performance.now(), ease = k => 1 - (1 - k) ** 3;
  const step = now => {
    const k = ease(Math.min(1, (now - t0) / 280)), u = {};
    for (const a in to) u[a + 'axis.range'] = [0, 1].map(i => from[a][i] + (to[a][i] - from[a][i]) * k);
    Plotly.relayout(gd, u);
    if (k < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}

// Magnifier: scale by f around the centre of the visible area. Stops at the full range when it would go beyond it.
function zoomBy(gd, f) {
  if (!gd.data) return;
  const to = {};
  for (const a of ['x', 'y']) {
    const h = gd._home[a], c = rangeOf(gd, a), mid = (c[0] + c[1]) / 2, w = Math.min((c[1] - c[0]) * f, h[1] - h[0]);
    const lo = Math.min(Math.max(mid - w / 2, h[0]), h[1] - w);
    to[a] = [lo, lo + w];
  }
  tween(gd, to);
}

// Expand: one chart in the big left cell (three rows high), the other three in one column on the right. The rearrangement is animated with FLIP.
function toggleBig(box) {
  const dash = box.parentElement, boxes = [...dash.querySelectorAll(':scope > .plotbox')];
  const first = boxes.map(b => b.getBoundingClientRect()), on = !box.classList.contains('big');
  boxes.forEach(b => b.classList.toggle('big', on && b === box));
  dash.classList.toggle('expanded', on);
  boxes.forEach(b => {
    const e = b.querySelector('.ptools .exp'), big = b.classList.contains('big');
    if (e) { e.innerHTML = ICON[big ? 'shr' : 'exp']; e.title = big ? 'Restore size' : 'Expand'; }
    const gd = b.querySelector('.plot');
    if (gd.data) { Plotly.relayout(gd, legendLayout(gd)); Plotly.Plots.resize(gd); }
  });
  if (run) drawRadial(U()[sel]);   // radial arcs are recomputed for the area size
  boxes.forEach((b, i) => {
    const l = b.getBoundingClientRect(), f = first[i], gd = b.querySelector('.plot');
    b.animate([{ transformOrigin: 'top left', transform: `translate(${f.left - l.left}px, ${f.top - l.top}px) scale(${f.width / l.width}, ${f.height / l.height})` },
               { transformOrigin: 'top left', transform: 'none' }], { duration: 480, easing: 'cubic-bezier(.34, 1.2, .64, 1)' });
    gd.animate([{ opacity: .35 }, { opacity: 1 }], { duration: 480, easing: 'ease-out' }).finished.then(() => syncAxes(gd));   // positions measured mid-animation are wrong, so re-measure when it ends
  });
  if (on) box.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}
document.addEventListener('keydown', e => { if (e.key === 'Escape') { const b = document.querySelector('.plotbox.big'); if (b) toggleBig(b); } });

// Chart how-to (between the header and the charts)
document.querySelectorAll('.howto').forEach(h => h.innerHTML =
  '<span><b>Drag</b> zoom into that region</span>' +
  '<span>While zoomed, drag the <span class="dotdemo"></span> dot between the axis title and the ticks to move</span>' +
  '<span><b>Double-click</b> reset</span>' +
  `<span>${ICON.zout}${ICON.zin} zoom out / in around the centre</span>` +
  (h.nextElementSibling.classList.contains('dash') ? `<span>${ICON.exp} expand (the rest move to one column on the right · Esc to go back)</span>` : ''));

// ---- Things available directly from the file layout
const byDisc = {};
I.grains.forEach(g => (byDisc[g.position] ??= []).push(g.grain));
const recsOf = (p, g) => I.records.filter(r => r.position == p && r.grain == g);
const firstOsl = (p, g) => recsOf(p, g).find(r => r.ltype !== 'TL');   // SAR's natural signal (first OSL/IRSL record)
const NCH = Math.max(...I.records.filter(r => r.ltype !== 'TL').map(r => r.npoints));

let run = null;   // the last SAR run: { mode, sig, bg, sar, age, meta }
let sel = 0, selToken = 0;

// ---- Tabs: driven by the address #name (back button and shared links work). Sub-items (#file, #sigrun …) open their tab, then scroll there.
const TABS = ['upload', 'signal', 'dash', 'model'], OLD = { file: 'upload', dist: 'dash' };   // old addresses (#file, #dist) are still accepted
const tabItems = [...document.querySelectorAll('#tree > li[data-v]')];
let tab = null;
function go(id) {
  const target = id && !TABS.includes(id) && !OLD[id] ? document.getElementById(id) : null;
  const v = TABS.includes(id) ? id : OLD[id] || target?.closest('.view')?.id || 'upload';
  const i = TABS.indexOf(v);
  tabItems.forEach((li, k) => { li.classList.toggle('on', k === i); li.classList.toggle('done', k !== i && (k === 0 || (k === 1 && !!run))); });
  // Selection box: every tab above is collapsed, so top = i × (tab height + gap), height = tab + its expanded sub-items
  const step = tabItems[0].querySelector('.tab').offsetHeight + 10;
  $('pill').style.transform = `translateY(${i * step}px)`;
  $('pill').style.height = (tabItems[0].querySelector('.tab').offsetHeight + tabItems[i].querySelector('.sub > ul').scrollHeight) + 'px';
  document.querySelectorAll('.view').forEach(s => s.classList.toggle('on', s.id === v));
  document.querySelectorAll('.sub a').forEach(a => a.classList.toggle('cur', a.getAttribute('href') === '#' + id));
  if (v === 'signal') requestAnimationFrame(syncSeg);   // the button widths could not be measured while hidden
  if (v !== tab) {
    tab = v;
    requestAnimationFrame(() => document.querySelectorAll('#' + v + ' .plot').forEach(p => { if (window.Plotly && p.data) Plotly.Plots.resize(p); }));
    if (v === 'dash' && run) drawRadial(U()[sel]);   // the radial plot must recompute its arcs for the area size
  }
  if (target) target.scrollIntoView({ behavior: 'smooth', block: 'start' });
}
window.addEventListener('hashchange', () => go(location.hash.slice(1)));

// ---- Analysis conditions at the top (always shows the conditions a result came from)
function renderContext() {
  const m = run ? run.meta : B.meta, box = $('context'); box.replaceChildren();
  [['Sample file', B.file], ['Measurement mode', run ? MODE_LABEL[run.mode] : 'not analysed'],
   ['Signal integral', run ? run.sig + ' (channels)' : '—'], ['Background integral', run ? run.bg + ' (channels)' : '—'],
   ['sigmab', run ? SIGMAB[run.mode] : '—'], ['Run time', run ? run.secs + ' s' : '—'], ['Unit', 'seconds (s) · no dose rate entered'],
   ['Analysis package', `Luminescence ${m.luminescence_version} · R ${m.r_version}`]]
    .forEach(([k, v]) => { const s = el('span', k + ' '); s.append(el('b', v)); box.append(s); });
}

// ---- 01 File
function renderFile() {
  const facts = [[B.file, 'File'], [SG ? 'single-grain' : 'single-aliquot', 'Measurement mode'], [I.n_positions, 'Discs'],
    [SG ? I.grains.length : '—', 'Grains'], [I.records.length, 'Records'], [arr(I.record_types).join(', '), 'Record types'], [NCH, 'Channels (OSL)']];
  if (I.object_name) facts.push([I.object_name, 'RDA object']);
  facts.forEach(([v, k]) => { const d = el('div'); d.append(el('span', k), el('b', v)); $('facts').append(d); });
  if (arr(I.ignored_objects).length) $('facts').append(el('p', `Other objects in the RDA (${arr(I.ignored_objects).join(', ')}) are not used.`, 'note'));

  const t = $('discs'), h = el('tr'); ['Disc', 'Grains', 'Grain numbers'].forEach(x => h.append(el('th', x))); t.append(h);
  Object.entries(byDisc).forEach(([p, gs]) => {
    const r = el('tr');
    [p, SG ? gs.length : '—', SG ? gs.join(', ') : 'Measured per disc'].forEach(x => r.append(el('td', x)));
    t.append(r);
  });
}

// ---- Shared: draw a curve (signal integral as a moss-green band, background as a grey band)
function drawCurve(div, c, text, sig, bg) {
  const x = c.x, dx = x.length > 1 ? (x[1] - x[0]) / 2 : 0.5, shapes = [], annotations = [];
  // The top of the signal band is where the decay curve peaks, so a label there sits on the curve. Put the signal label just outside the band's right edge (where the curve has dropped).
  const band = (r, color, name, outside) => {
    if (!r || r[0] < 1 || r[1] > x.length || r[0] > r[1]) return;
    const x0 = x[r[0] - 1] - dx, x1 = x[r[1] - 1] + dx, font = { size: 11, color: C.ink };
    shapes.push({ type: 'rect', xref: 'x', yref: 'paper', x0, x1, y0: 0, y1: 1, fillcolor: color, opacity: 0.3, line: { width: 0 },
      ...(outside ? {} : { label: { text: name, textposition: 'top right', font } }) });   // aligned to the band's right end so a band narrower than the text is not clipped at the chart edge
    if (outside) annotations.push({ xref: 'x', yref: 'paper', x: x1, y: 1, xanchor: 'left', yanchor: 'top', xshift: 4, text: name, showarrow: false, font });
  };
  band(sig, C.moss, 'Signal', true); band(bg, C.muted, 'Background');
  const tl = /^TL/.test(c.record_type);
  plot(div, [{ x, y: c.y, customdata: x.map((_, i) => i + 1), mode: 'lines', line: { color: C.ink, width: 1.5 },
    hovertemplate: `Channel %{customdata} · %{x:.2f} ${tl ? '°C' : 's'}<br>%{y} counts<extra></extra>` }],
  { ...BASE, title: title(text), xaxis: ax({ title: tl ? 'Temperature (°C)' : 'Stimulation time (s)' }), yaxis: ax({ title: 'Counts' }), shapes, annotations, showlegend: false }, PC);
}

// ---- 02 Signal: viewing record curves
const selPos = $('selPos'), selGrain = $('selGrain'), selRec = $('selRec');
let sigCurve = null, sigToken = 0;
Object.keys(byDisc).forEach(p => selPos.append(new Option(p, p)));
$('grainLabel').hidden = !SG;
function fillGrains() { selGrain.replaceChildren(); byDisc[selPos.value].forEach(g => selGrain.append(new Option(g, g))); fillRecs(); }
function fillRecs() {
  selRec.replaceChildren();
  recsOf(selPos.value, selGrain.value).forEach(r => selRec.append(new Option(`#${r.record_index} ${r.ltype} · ${r.dtype} · dose ${r.irr_time} s`, r.record_index)));
  const f = firstOsl(selPos.value, selGrain.value); if (f) selRec.value = f.record_index;
  showSignal();
}
async function showSignal() {
  const token = ++sigToken, p = +selPos.value, g = +selGrain.value, i = +selRec.value;
  const rec = recsOf(p, g).find(r => r.record_index === i);
  try {
    const c = (await cached('curve', { position: p, record_index: i, ...(SG ? { grain: g } : {}) })).result;
    if (token !== sigToken) return;
    sigCurve = { c, text: `Disc ${p}` + (SG ? ` · grain ${g}` : '') + ` · #${i} ${rec.ltype}` };
    drawSignal();
    $('curveInfo').textContent = `Measurement temperature ${rec.temperature}°C · regeneration dose ${rec.irr_time} s · ${c.x.length} channels. Hover over the curve to see channel numbers.`;
  } catch (e) { if (token === sigToken) plotMessage('curvePlot', 'Could not load the curve: ' + e.message); }
}
// Show the integrals being typed as coloured bands on the curve right away.
// Integrals are entered as two numbers (start · end). R still receives the "start:end" string.
const rangeVal = id => $(id + '1').value + ':' + $(id + '2').value;
function drawSignal() { if (sigCurve) drawCurve('curvePlot', sigCurve.c, sigCurve.text, parseRange(rangeVal('sig')), parseRange(rangeVal('bg'))); }
selPos.onchange = fillGrains; selGrain.onchange = fillRecs; selRec.onchange = showSignal;
['sig1', 'sig2', 'bg1', 'bg2'].forEach((id, k, ids) => {
  const inp = $(id); inp.max = NCH; inp.oninput = drawSignal;
  // Typing ':' (or space) out of habit moves to the end field
  if (k % 2 === 0) inp.onkeydown = e => { if (e.key === ':' || e.key === ' ') { e.preventDefault(); $(ids[k + 1]).focus(); } };
});

// ---- 02 Analysis settings: measurement mode + integrals → SAR → age model
let formMode = SG ? 'single_grain' : 'single_aliquot';
Object.entries(MODE_LABEL).forEach(([m, label]) => {
  const b = el('button', label); b.type = 'button'; b.dataset.mode = m;
  if (m === 'single_grain' && !SG) { b.disabled = true; b.title = 'No GRAIN numbers in this file, so Single grain analysis is unavailable'; }
  b.onclick = () => { formMode = m; syncSeg(); };
  $('modeSeg').append(b);
});
function syncSeg() {
  document.querySelectorAll('#modeSeg button').forEach(b => b.classList.toggle('on', b.dataset.mode === formMode));
  const b = document.querySelector('#modeSeg button.on'), t = document.querySelector('#modeSeg .thumb');
  if (b && b.offsetWidth) { t.style.width = b.offsetWidth + 'px'; t.style.transform = `translateX(${b.offsetLeft - 3}px)`; }
}
$('runHint').textContent = `Channels 1–${NCH}. Enter only the start and end channel numbers (e.g. 6 : 10). Typed values show as coloured bands on the curve above. `
  + 'Single grain gives one De per grain; Single aliquot sums the grain signals of a disc and gives one De per disc.'
  + (SG ? '' : ' This file allows Single aliquot only.');

$('runForm').onsubmit = async e => {
  e.preventDefault();
  const sig = rangeVal('sig'), bg = rangeVal('bg'), mode = formMode;
  const bad = [parseRange(sig), parseRange(bg)].some(r => !r || r[0] < 1 || r[1] > NCH || r[0] > r[1]);
  if (bad) { $('runStatus').textContent = `Integrals must lie within 1–${NCH}, with start not greater than end.`; return; }

  $('runBtn').disabled = true;
  const t0 = Date.now(), tick = setInterval(() => { $('runStatus').textContent = `Running SAR · ${Math.round((Date.now() - t0) / 1000)} s`; }, 500);
  try {
    const s = await api('sar', { positions: arr(I.positions), signal_integral: sig, background_integral: bg, mode });
    const acc = s.result.units.filter(u => u.rc_status === 'OK' && u.de != null);
    let age;
    try {
      age = { ok: true, ...(await api('age_model', { de: acc.map(u => u.de), de_error: acc.map(u => u.de_error), sigmab: SIGMAB[mode] })).result };
    } catch (err) { age = { ok: false, error: err.message }; }
    // Run time: from the button press until the SAR + age-model responses arrive (includes R start-up on the server; the time the user waited)
    run = { mode, sig, bg, sar: s.result, age, meta: s.meta, secs: ((Date.now() - t0) / 1000).toFixed(1) };
    $('runStatus').textContent = `Done · ${s.result.n_success}/${s.result.n_requested} analysed, ${acc.length} passed QC · ${run.secs} s`;
    renderRun();
    location.hash = '#dash';
  } catch (err) {
    $('runStatus').textContent = 'SAR failed: ' + err.message;
  } finally { clearInterval(tick); $('runBtn').disabled = false; }
};

// ---- 03 De distribution: choosing one unit updates the four charts, the map and the table together
const U = () => run.sar.units;
const unitLabel = u => run.mode === 'single_grain' ? `Disc ${u.position} · grain ${u.grain}` : `Disc ${u.position}`;

function renderRun() {
  renderContext();
  $('distEmpty').hidden = true; $('distBody').hidden = false;
  const md = $('mapDisc'); md.replaceChildren();
  if (run.mode === 'single_grain') [...new Set(U().map(u => u.position))].forEach(p => md.append(new Option('Disc ' + p, p)));
  md.hidden = run.mode !== 'single_grain';
  const f = arr(run.sar.failed);
  $('failedNote').textContent = f.length ? `${f.length} failed to analyse (not in the table): ` + f.map(x => (run.mode === 'single_grain' ? `disc ${x.position} grain ${x.grain}` : `disc ${x.position}`) + ` — ${x.reason}`).join(' / ') : '';
  renderModel();
  const first = U().findIndex(u => u.rc_status === 'OK');
  sel = first >= 0 ? first : 0;
  renderTable();
  select(sel);
}

function select(i) {
  const units = U(); if (!units.length) return;
  sel = Math.max(0, Math.min(units.length - 1, i));
  const u = units[sel], pass = u.rc_status === 'OK', token = ++selToken;
  $('selTitle').textContent = unitLabel(u);
  $('selDetail').replaceChildren(el('span', `De ${fmt(u.de)} ± ${fmt(u.de_error)} s · `), el('span', pass ? '● Pass' : '✕ Fail', pass ? 'ok' : 'no'),
    el('span', ` · Recycling ${fmt(u.recycling_ratio, 3)}` + (u.warning ? ' · has warning' : '')));
  $('prevBtn').disabled = sel === 0;
  $('nextBtn').disabled = sel === units.length - 1;
  document.querySelectorAll('#units tr.pick').forEach(r => r.classList.toggle('sel', +r.dataset.i === sel));
  renderMap(); renderQC(u); drawHist(u); drawRadial(u);
  drawUnitCurve(u, token); drawDR(u, token);
}

async function drawUnitCurve(u, token) {
  const sgMode = run.mode === 'single_grain', g = sgMode ? u.grain : byDisc[u.position][0], rec = firstOsl(u.position, g);
  const args = sgMode ? { position: u.position, record_index: rec.record_index, grain: u.grain }
                      : { position: u.position, record_index: rec.record_index, mode: 'single_aliquot' };
  try {
    const c = (await cached('curve', args)).result;
    if (token !== selToken) return;
    drawCurve('dCurve', c, 'Signal curve · ' + (!sgMode && SG ? 'disc sum · ' : '') + 'natural signal', parseRange(run.sig), parseRange(run.bg));
  } catch (e) { if (token === selToken) plotMessage('dCurve', 'Could not load the curve: ' + e.message); }
}

async function drawDR(u, token) {
  const args = { position: u.position, signal_integral: run.sig, background_integral: run.bg, mode: run.mode,
    ...(run.mode === 'single_grain' ? { grain: u.grain } : {}) };
  let d;
  try { d = (await cached('dose_response', args)).result; } catch (e) { if (token === selToken) plotMessage('dDR', 'Could not load the dose-response curve: ' + e.message); return; }
  if (token !== selToken) return;
  const P = d.points;
  const regen = P.filter(p => p.name !== 'Natural' && !p.repeated && p.dose > 0), rep = P.filter(p => p.repeated),
        zero = P.filter(p => p.name !== 'Natural' && p.dose === 0), nat = P.find(p => p.name === 'Natural');
  const pts = (a, name, marker) => ({ x: a.map(p => p.dose), y: a.map(p => p.lxtx), mode: 'markers', name, marker: { size: 8, ...marker },
    error_y: { type: 'data', array: a.map(p => p.lxtx_error), color: marker.line?.color || marker.color, thickness: 1 },
    hovertemplate: 'Dose %{x} s<br>Lx/Tx %{y:.3f}<extra>' + name + '</extra>' });
  const traces = [{ x: arr(d.curve_x), y: arr(d.curve_y), mode: 'lines', name: 'Fitted curve', line: { color: C.fit, width: 2 }, hoverinfo: 'skip' },
    pts(regen, 'Regeneration dose', { color: C.data }),
    pts(rep, 'Repeat', { symbol: 'diamond-open', color: C.ink, line: { color: C.ink, width: 1 } }),
    pts(zero, 'Zero dose', { symbol: 'square-open', color: C.muted, line: { color: C.muted, width: 1 } })];
  const shapes = [];
  if (nat && d.de != null) {
    traces.push({ x: [d.de], y: [nat.lxtx], mode: 'markers', name: 'Natural signal → De', marker: { color: C.natural, size: 13, symbol: 'star' },
      error_y: { type: 'data', array: [nat.lxtx_error], color: C.natural }, hovertemplate: `De ${fmt(d.de)} s<extra></extra>` });
    shapes.push({ type: 'line', x0: 0, x1: d.de, y0: nat.lxtx, y1: nat.lxtx, line: { color: C.natural, dash: 'dot', width: 1 } },
                { type: 'line', x0: d.de, x1: d.de, y0: 0, y1: nat.lxtx, line: { color: C.natural, dash: 'dot', width: 1 } });
  }
  plot('dDR', traces, { ...BASE, shapes, title: title('Dose-response curve' + (d.de == null ? ' · De not computable' : '')),
    xaxis: ax({ title: 'Regeneration dose (s)', rangemode: 'tozero' }), yaxis: ax({ title: 'Lx/Tx', rangemode: 'tozero' }) }, PC);
}

function drawHist(u) {
  // Count the bins by hand (Plotly's automatic histogram sometimes left the last value outside the visible range).
  const units = U(), all = units.filter(x => x.de != null).map(x => x.de);
  if (!all.length) { plotMessage('dHist', 'No unit has a computed De'); return; }
  const lo = Math.min(...all), hi = Math.max(...all);
  const NB = 15, size = (hi - lo) / NB || 1, edges = [...Array(NB)].map((_, k) => lo + k * size);
  const count = a => { const c = Array(NB).fill(0); a.forEach(x => c[Math.min(NB - 1, Math.floor((x.de - lo) / size))]++); return c; };
  const ok = units.filter(x => x.de != null && x.rc_status === 'OK'), no = units.filter(x => x.de != null && x.rc_status !== 'OK');
  const noDe = units.length - all.length;
  const bar = (a, name, color) => ({ type: 'bar', name, x: edges.map(e => e + size / 2), y: count(a), width: size,
    marker: { color, line: { color: '#fff', width: 1 } }, customdata: edges.map(e => `${e.toFixed(0)}–${(e + size).toFixed(0)}`),
    hovertemplate: '%{customdata} s: %{y}<extra>' + name + '</extra>' });
  const shapes = u.de == null ? [] : [{ type: 'line', x0: u.de, x1: u.de, y0: 0, y1: 1, yref: 'paper', line: { color: C.ink, width: 1.5, dash: 'dash' } }];
  plot('dHist', [bar(no, `Fail (${no.length})` + (noDe ? ` · ${noDe} without De excluded` : ''), C.fail), bar(ok, `Pass (${ok.length})`, C.pass)],
    { ...BASE, barmode: 'stack', shapes, title: title('De distribution · dashed = selected unit'), xaxis: ax({ title: 'De (s)' }), yaxis: ax({ title: 'Count' }) }, PC);
}

// Radial plot. Each line from the origin is one De value (slope = log De − log central value).
// The two axes have different units, so the arc must be a circle in screen pixels (R draws it that way too). Draw once, measure the area, then redraw.
function drawRadial(u) {
  const A = run.age, gd = $('dRadial');
  if (!A.ok) { plotMessage('dRadial', 'Cannot draw the radial plot: ' + A.error); return; }
  if (!gd.data) gd.replaceChildren();
  const P = A.distribution.points, z0 = Math.log(A.distribution.central_de), des = P.map(p => p.de);
  const X = Math.max(...P.map(p => p.radial_x)) * 1.3;
  const lo = Math.min(...des), hi = Math.max(...des);
  const raw = (hi - lo) / 4 || lo / 4, mag = 10 ** Math.floor(Math.log10(raw)), step = [1, 2, 2.5, 5, 10].map(m => m * mag).find(m => m >= raw);
  const ticks = []; for (let v = Math.max(step, Math.floor(lo / step) * step); v <= Math.ceil(hi / step) * step + 1e-9; v += step) ticks.push(v);
  const selPt = u.rc_status === 'OK' ? P.findIndex(p => Math.abs(p.de - u.de) < 1e-6) : -1;
  const note = selPt < 0 ? ' · selected unit failed, so not shown' : '';
  const layout = Y => ({ ...BASE, title: title('Radial plot (arc: De scale, s)' + note),
    xaxis: ax({ title: 'Precision (1/relative error)', range: [0, X] }), yaxis: ax({ title: 'Standardized distance', range: [-Y, Y] }) });
  const pts = { x: P.map(p => p.radial_x), y: P.map(p => p.radial_y), mode: 'markers', name: 'Passing De', marker: { color: C.pass, size: 9 },
    text: P.map(p => `De ${fmt(p.de)} ± ${fmt(p.de_error)} s`), hovertemplate: '%{text}<extra></extra>' };
  let Y = Math.max(3, ...P.map(p => Math.abs(p.radial_y))) * 1.15;
  plot(gd, [pts], layout(Y));
  const W = gd._fullLayout._size.w, H = gd._fullLayout._size.h, r = W * 0.78;
  const arcPt = (s, rad, Yv) => { const m = s * (H / (2 * Yv)) / (W / X), px = rad / Math.sqrt(1 + m * m); return [px * X / W, m * px * 2 * Yv / H]; };
  const sOf = v => Math.log(v) - z0, sMax = Math.max(...ticks.map(v => Math.abs(sOf(v))));
  for (let i = 0; i < 40 && Math.abs(arcPt(sMax, r * 1.1, Y)[1]) > Y * 0.95; i++) Y *= 1.1;
  const sLo = sOf(ticks[0]), sHi = sOf(ticks[ticks.length - 1]);
  const arc = [...Array(81)].map((_, i) => arcPt(sLo + (sHi - sLo) * i / 80, r, Y));
  const seg = f => ({ x: ticks.flatMap(v => [...f(v).map(q => q[0]), null]), y: ticks.flatMap(v => [...f(v).map(q => q[1]), null]) });
  const grey = { color: C.muted, width: 1 }, end0 = arcPt(0, r, Y)[0];
  const traces = [
    { x: [0, end0, end0, 0], y: [2, 2, -2, -2], mode: 'lines', fill: 'toself', fillcolor: 'rgba(108,122,121,0.15)', line: { width: 0 }, hoverinfo: 'skip', name: '±2' },
    { ...seg(v => [[0, 0], arcPt(sOf(v), r, Y)]), mode: 'lines', line: { color: C.line, width: 1 }, hoverinfo: 'skip', showlegend: false },
    { x: [0, end0], y: [0, 0], mode: 'lines', line: { color: C.fit, dash: 'dash' }, name: `Central value ${fmt(A.distribution.central_de)} s`, hoverinfo: 'skip' },
    { x: arc.map(a => a[0]), y: arc.map(a => a[1]), mode: 'lines', line: grey, hoverinfo: 'skip', showlegend: false },
    { ...seg(v => [arcPt(sOf(v), r, Y), arcPt(sOf(v), r * 1.025, Y)]), mode: 'lines', line: grey, hoverinfo: 'skip', showlegend: false },
    { x: ticks.map(v => arcPt(sOf(v), r * 1.045, Y)[0]), y: ticks.map(v => arcPt(sOf(v), r * 1.045, Y)[1]), mode: 'text', text: ticks.map(String),
      textposition: 'middle right', textfont: { size: 11, color: C.muted }, hoverinfo: 'skip', showlegend: false },
    pts];
  if (selPt >= 0) traces.push({ x: [P[selPt].radial_x], y: [P[selPt].radial_y], mode: 'markers', name: 'Selected', hoverinfo: 'skip',
    marker: { size: 18, color: 'rgba(0,0,0,0)', line: { color: C.ink, width: 1.5 } } });
  plot(gd, traces, layout(Y));
}

// Disc map. A: the 10×10 holes of the selected disc (numbering assumed row by row from the top left). B: all discs.
function renderMap() {
  const units = U(), u = units[sel], map = $('map'); map.replaceChildren();
  const cell = (label, k) => {
    const c = el('div', label, 'cell');
    if (k >= 0) {
      const x = units[k];
      c.classList.add(x.rc_status === 'OK' ? 'pass' : 'fail');
      c.title = `${unitLabel(x)} · De ${fmt(x.de)} s`; c.onclick = () => select(k);
      if (k === sel) c.classList.add('cur');
    }
    map.append(c);
  };
  if (run.mode === 'single_grain') {
    map.className = 'map';
    $('mapDisc').value = u.position;
    $('mapTitle').textContent = 'Disc map';
    $('mapNote').textContent = 'Holes are numbered row by row from the top left (to be confirmed against the real disc layout).';
    for (let g = 1; g <= 100; g++) cell(g, units.findIndex(x => x.position === u.position && x.grain === g));
  } else {
    map.className = 'map discs';
    $('mapTitle').textContent = 'All discs';
    $('mapNote').textContent = 'In mode B one disc is one analysis unit.';
    units.forEach((x, k) => cell(x.position, k));
  }
}
$('mapDisc').onchange = e => { const k = U().findIndex(x => x.position == e.target.value); if (k >= 0) select(k); };

// Per-criterion QC values of the selected unit (why it passed or failed)
function renderQC(u) {
  const t = $('qc'); t.replaceChildren();
  const h = el('tr'); ['Criterion', 'Value', 'Threshold', 'Verdict'].forEach(x => h.append(el('th', x))); t.append(h);
  arr(run.sar.qc).filter(q => q.position === u.position && (run.mode !== 'single_grain' || q.grain === u.grain)).forEach(q => {
    const r = el('tr'), ok = q.status === 'OK';
    r.append(el('td', q.criteria), el('td', fmt(q.value, 3), 'num'), el('td', q.threshold == null ? '—' : q.threshold, 'num'), el('td', ok ? '● Pass' : '✕ Fail', ok ? 'ok' : 'no'));
    t.append(r);
  });
}

function renderTable() {
  const t = $('units'), only = $('onlyPass').checked; t.replaceChildren();
  const sgMode = run.mode === 'single_grain';
  const h = el('tr'); [...(sgMode ? ['Disc', 'Grain'] : ['Disc']), 'De (s)', 'Verdict', 'Recycling', 'Fit', 'Warning'].forEach(x => h.append(el('th', x))); t.append(h);
  let n = 0;
  U().forEach((u, i) => {
    const pass = u.rc_status === 'OK'; if (only && !pass) return; n++;
    const r = el('tr', null, 'pick'); r.dataset.i = i;
    (sgMode ? [u.position, u.grain] : [u.position]).forEach(x => r.append(el('td', x, 'num')));
    const w = el('td', u.warning ? 'yes' : ''); if (u.warning) w.title = u.warning;
    r.append(el('td', `${fmt(u.de)} ± ${fmt(u.de_error)}`, 'num'), el('td', pass ? '● Pass' : '✕ Fail', pass ? 'ok' : 'no'),
             el('td', fmt(u.recycling_ratio, 3), 'num'), el('td', u.fit ?? ''), w);
    if (i === sel) r.classList.add('sel');
    r.onclick = () => select(i); t.append(r);
  });
  $('tableCount').textContent = `${n} shown / ${U().length} total`;
}
$('onlyPass').onchange = renderTable;
$('prevBtn').onclick = () => select(sel - 1);
$('nextBtn').onclick = () => select(sel + 1);
document.addEventListener('keydown', e => {
  if (!run || tab !== 'dash' || /INPUT|SELECT/.test(document.activeElement.tagName)) return;
  if (e.key === 'ArrowLeft') select(sel - 1); else if (e.key === 'ArrowRight') select(sel + 1);
});

// ---- 04 Model
function renderModel() {
  const A = run.age, box = $('modelBox'); box.replaceChildren();
  if (!A.ok) { box.append(el('p', 'Cannot compute: ' + A.error)); return; }
  const R = A.result, rec = A.recommendation;
  box.append(el('p', MODE_LABEL[run.mode] + ' · ' + (A.model_source === 'rule' ? 'rule recommendation' : 'user choice'), 'axis'),
             el('div', `Recommended model: ${rec.model}`, 'big'));
  const ul = el('ul'); arr(rec.reasons).forEach(x => ul.append(el('li', x))); box.append(ul);
  if (R.model === 'FMM') {
    const tt = el('table'), h = el('tr'); ['Component', 'Dose (s)', 'Proportion'].forEach(x => h.append(el('th', x))); tt.append(h);
    arr(R.components).forEach((c, k) => { const r = el('tr'); [k + 1, `${fmt(c.dose)} ± ${fmt(c.dose_error)}`, `${fmt(100 * c.proportion, 0)}%`].forEach(x => r.append(el('td', x, 'num'))); tt.append(r); });
    box.append(el('p', 'FMM does not choose which component dates the event (researcher judgment).'), tt);
  } else {
    box.append(el('p', `Representative dose: ${fmt(R.dose)} ± ${fmt(R.dose_error)} s`, 'big'));
  }
  box.append(el('p', `De used: ${R.n} · overdispersion ${fmt(A.distribution.od_rel)}% · sigmab ${R.sigmab == null ? 'not used' : R.sigmab}. Minimum-count threshold awaits the researchers.`, 'note'),
             el('p', `${R.package} ${R.package_version} · R ${run.meta.r_version}`, 'note'));
}

// ---- Start
if (!window.Plotly) document.querySelectorAll('.plot').forEach(p => p.replaceChildren(el('div', 'Could not load the chart library. Tables and text are still shown.', 'empty')));
renderContext();
renderFile();
fillGrains();
go(location.hash.slice(1));
document.fonts.ready.then(() => { syncSeg(); go(location.hash.slice(1)); });   // the font swap changes tab and button widths, so realign
let rt; window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(() => {
  syncSeg();
  document.querySelectorAll('.plot').forEach(gd => { if (gd.data) Plotly.relayout(gd, legendLayout(gd)); });   // recompute the legend position when the chart height changes
  if (run && tab === 'dash') drawRadial(U()[sel]);
}, 150); });

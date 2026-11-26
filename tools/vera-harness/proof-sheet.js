#!/usr/bin/env node
/**
 * Approximate SVG proof from the real decoded tree and resolved ETS theme.
 * Text width uses a character estimate, not ArkUI or font measurement.
 * Geometry uses theme tokens. This cannot verify device layout or animation.
 */
'use strict'
const {loadVera} = require('./source-loader')
const T = loadVera('VeraTheme')

function esc(value) {
  return String(value ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;')
}
function empty() { return {svg: '', width: 0, height: 0} }
function move(box, x, y) { return `<g transform="translate(${x},${y})">${box.svg}</g>` }
function rect(width, height, fill, radius = 0, stroke = 'none') {
  return `<rect width="${width}" height="${height}" rx="${radius}" fill="${fill}" stroke="${stroke}"/>`
}
function estimate(text, size) { return Array.from(String(text)).reduce((w, c) => w + size * (/\s/.test(c) ? 0.3 : /[ilI.,:!]/.test(c) ? 0.3 : /[MW@]/.test(c) ? 0.85 : c.codePointAt(0) > 255 ? 1 : 0.56), 0) }
function wrapText(text, size, width) {
  const lines = []
  for (const paragraph of String(text).split('\n')) {
    let line = ''
    for (const word of paragraph.split(/\s+/).filter(Boolean)) {
      if (line && estimate(line + ' ' + word, size) > width) { lines.push(line); line = '' }
      if (estimate(word, size) <= width) { line += (line ? ' ' : '') + word; continue }
      for (const char of Array.from(word)) {
        if (line && estimate(line + char, size) > width) { lines.push(line); line = '' }
        line += char
      }
    }
    lines.push(line)
  }
  return lines
}
// Mirrors formatVeraNumber in VeraUi.ets: decimals -1 is "as it is", without binary noise.
function formattedInt(node) {
  const value = node.numberValue || 0
  const decimals = node.decimals === undefined ? -1 : node.decimals
  const a = Math.abs(value)
  const text = decimals >= 0 ? a.toFixed(Math.min(Math.floor(decimals), 10))
    : (Number.isInteger(a) ? String(a) : String(parseFloat(a.toFixed(9))))
  const [whole, rest] = text.includes('.') ? [text.slice(0, text.indexOf('.')), text.slice(text.indexOf('.'))] : [text, '']
  const padded = whole.padStart(Math.max(1, Math.min(20, node.minimumDigits || 1)), '0')
  const zero = parseFloat(padded + rest) === 0
  return (node.prefix || '') + (value < 0 && !zero ? '-' : '') + padded + rest + (node.suffix || '')
}
function formattedTime(node) {
  const total = Math.max(0, node.numberValue || 0) % 1440
  return (node.prefix || '') + String(Math.floor(total / 60)).padStart(2, '0') + ':' +
    String(total % 60).padStart(2, '0') + (node.suffix || '')
}

function formattedDate(node) {
  const d = new Date(Math.floor(node.numberValue || 0) * 86400000)
  return d.getUTCDate() + ' ' + ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.getUTCMonth()] + ' ' + d.getUTCFullYear()
}

function createRenderer(theme, options) {
  const t = theme
  const insetParents = new Set(['hero', 'adaptivecolumns', 'section', 'card', 'column', 'scroll'])
  function text(value, style, width, ink, extra = {}) {
    if (value === '' || value === undefined || value === null) return empty()
    let size = T.textSize(t, style)
    // Pre-change theme snapshots predate the native widget size cap.
    const semanticType = t.headingFontFamily !== undefined && t.metricFontFamily !== undefined
    if (options.embedded && semanticType && (style === 'display' || style === 'metric')) size = Math.min(32, size)
    const family = extra.family !== undefined ? extra.family : style === 'metric' ? (t.metricFontFamily ?? t.fontFamily) :
      ['display', 'title', 'heading'].includes(style) ? (t.headingFontFamily ?? t.fontFamily) : t.fontFamily
    const lines = wrapText(value, size, Math.max(1, width))
    const leading = size * 1.3
    const spacing = extra.eyebrow ? t.eyebrowSpacing : 0
    const measured = Math.min(width, Math.max(...lines.map(line => estimate(line, size) + Math.max(0, line.length - 1) * spacing)))
    return {svg: `<text font-family="${esc(family || 'sans-serif')}" font-size="${size}" font-weight="${extra.weight || T.textWeight(t, style)}" fill="${ink || T.textInk(t, style)}" letter-spacing="${spacing}">` +
      lines.map((line, i) => `<tspan x="0" y="${size + i * leading}">${esc(line)}</tspan>`).join('') + '</text>',
      width: measured, height: lines.length * leading}
  }
  function stack(boxes, width, gap) {
    const visible = boxes.filter(b => b.height > 0 || b.width > 0)
    let svg = '', y = 0
    visible.forEach((box, i) => { if (i) y += gap; svg += move(box, 0, y); y += box.height })
    return {svg, width, height: y}
  }
  function frame(inner, width, px, top, bottom, fill = 'none', radius = 0, stroke = 'none', marginTop = 0, marginBottom = 0) {
    const height = top + inner.height + bottom
    return {svg: `<g transform="translate(0,${marginTop})">${rect(width, height, fill, radius, stroke)}${move(inner, px, top)}</g>`,
      width, height: marginTop + height + marginBottom}
  }
  function flow(boxes, width, gap, wrap = true, align = 'default') {
    const rows = []
    let row = [], used = 0
    for (const box of boxes.filter(b => b.height > 0)) {
      if (wrap && row.length && used + gap + box.width > width) { rows.push(row); row = []; used = 0 }
      used += (row.length ? gap : 0) + box.width; row.push(box)
    }
    if (row.length) rows.push(row)
    let y = 0, svg = '', widest = width
    rows.forEach((items, index) => {
      if (index) y += gap
      const used = items.reduce((sum, b) => sum + b.width, 0) + gap * (items.length - 1)
      let x = align === 'end' ? Math.max(0, width - used) : align === 'center' ? Math.max(0, (width - used) / 2) : 0
      const between = align === 'spread' && items.length > 1 ? Math.max(gap, (width - used + gap * (items.length - 1)) / (items.length - 1)) : gap
      for (const box of items) { svg += move(box, x, y); widest = Math.max(widest, x + box.width); x += box.width + between }
      y += Math.max(...items.map(b => b.height))
    })
    return {svg, width: widest, height: y}
  }
  function nodeBox(node, width, parent = '') {
    width = Math.max(1, width)
    if (!node || ['ticker', 'backhandler'].includes(node.kind)) return empty()
    const children = node.children || [], kind = node.kind, style = node.style || 'default'
    const childBoxes = (available, gap = t.gapBase) => stack(children.map(c => layout(c, available, kind)), available, gap)
    if (kind === 'apptheme') return childBoxes(width, 0)
    if (kind === 'hero') {
      const accent = style === 'accent'
      const px = accent ? t.padCard : insetParents.has(parent) ? 0 : t.padBase
      const innerWidth = Math.max(1, width - 2 * px)
      const inner = stack([text(node.label, 'caption', innerWidth, t.inkMuted, {eyebrow: true, weight: t.weightHeading}),
        text(node.text, 'display', innerWidth), text(node.value, 'body', innerWidth, t.inkSoft),
        ...children.map(c => layout(c, innerWidth, kind))], innerWidth, t.gapBase)
      return frame(inner, width, px, accent ? t.padCard : t.padLoose, accent ? t.padCard : 0,
        accent ? t.primaryFill : 'none', accent ? t.radiusCard : 0, 'none', 0, t.gapSection)
    }
    if (kind === 'adaptivecolumns') {
      const px = insetParents.has(parent) ? 0 : t.padBase
      const available = Math.max(1, width - 2 * px), gap = T.densityGap(t, style)
      const minimum = node.minimum > 0 ? Math.max(160, node.minimum) : 240
      const columns = available - gap >= minimum * 2 ? 2 : 1
      const childWidth = (available - gap * (columns - 1)) / columns
      let y = 0, svg = ''
      for (let i = 0; i < children.length; i += columns) {
        const boxes = children.slice(i, i + columns).map(c => layout(c, childWidth, kind))
        if (i) y += gap
        boxes.forEach((b, j) => { svg += move(b, j * (childWidth + gap), y) })
        y += Math.max(0, ...boxes.map(b => b.height))
      }
      return {svg: `<g data-columns="${columns}" data-content-width="${available}" transform="translate(${px},0)">${svg}</g>`, width, height: y}
    }
    if (kind === 'section') {
      const fill = {hero: t.primaryFill, summary: t.surface, warning: t.warningFill}[style] || 'none'
      const filled = fill !== 'none', px = filled ? t.padCard : insetParents.has(parent) ? 0 : t.padBase
      const w = Math.max(1, width - px * 2)
      const inner = stack([text(node.text, 'heading', w, style === 'warning' ? t.warningInk : style === 'supporting' ? t.inkSoft : t.ink),
        text(node.label, 'caption', w, t.inkMuted), ...children.map(c => layout(c, w, kind))], w, t.gapTight)
      return frame(inner, width, px, filled ? t.padCard : 0, filled ? t.padCard : 0,
        fill, filled ? t.radiusCard : 0, 'none', t.gapTight, t.gapSection)
    }
    if (kind === 'screen') return stack(children.map(c => layout(c, width, kind)), width, 0)
    if (['column', 'scroll', 'card', 'listgroup', 'timeline'].includes(kind)) {
      const card = kind === 'card' || kind === 'listgroup'
      const pad = card ? t.padCard : T.densityPad(t, style), w = Math.max(1, width - 2 * pad)
      const inner = stack([text(node.text, 'heading', w), ...children.map(c => layout(c, w, kind))], w, ['column', 'scroll'].includes(kind) ? 0 : T.densityGap(t, style))
      const boxed = frame(inner, width, pad, pad, pad, card ? T.toneFill(t, style, t.surface) : T.containerFill(t, style), card ? t.radiusCard : 0, card ? t.lineSoft : 'none')
      // ArkUI's .shadow: a blurred copy of the card under it.
      if (card && t.shadowRadius > 0) boxed.svg = `<rect width="${width}" height="${boxed.height}" rx="${t.radiusCard}" fill="#000" filter="url(#lift)"/>` + boxed.svg
      return boxed
    }
    if (kind === 'header' || kind === 'sectionheader') {
      const pad = kind === 'header' ? t.padBase : 0, w = Math.max(1, width - 2 * pad)
      const boxes = kind === 'header' ? [text(node.label, 'eyebrow', w), text(node.text, 'display', w), text(node.value, 'body', w, t.inkSoft)] :
        [text(node.text, 'heading', w), text(node.label, 'caption', w, t.inkMuted), text(node.value, 'caption', w, t.inkMuted)]
      const inner = stack(boxes, w, t.gapTight)
      return frame(inner, width, pad, kind === 'header' ? t.padLoose : pad, pad)
    }
    if (['text', 'numbertext', 'clocktext'].includes(kind)) {
      const value = kind === 'numbertext' ? formattedInt(node) : kind === 'clocktext' ? formattedTime(node) : node.text
      const box = text(value, style, width, undefined, {eyebrow: style === 'eyebrow'})
      return {...box, svg: move(box, 0, 2), height: box.height ? box.height + 4 : 0}
    }
    if (kind === 'button' || kind === 'iconbutton') {
      const label = node.text || node.label || node.icon || '', pad = t.padBase
      const w = Math.min(width, Math.max(t.controlHeight, estimate(label, t.sizeBody) + pad * 2))
      const disabled = node.enabled === false, quiet = style === 'quiet'
      const content = text(label, 'body', Math.max(1, w - pad * 2), disabled ? t.inkDisabled : quiet ? t.primaryInk : T.buttonInk(t, style))
      const height = Math.max(t.controlHeight, content.height + t.padTight * 2)
      return {svg: rect(w, height, disabled ? t.surfaceDisabled : quiet ? 'none' : T.buttonFill(t, style), style === 'secondary' ? t.radiusControl : height / 2) +
        move(content, (w - content.width) / 2, (height - content.height) / 2), width: w, height}
    }
    if (['row', 'actionbar', 'select', 'grid', 'metricgroup', 'kvgroup'].includes(kind)) {
      const items = kind === 'select' ? (node.options || []).map((label, i) => ({kind: 'button', text: label, style: i === node.eventValue ? 'primary' : 'secondary'})) : children
      const gap = T.densityGap(t, style)
      const columns = ['grid', 'metricgroup'].includes(kind) ? Math.max(1, node.columns || 1) : 0
      const cellWidth = columns ? Math.max(1, (width - gap * (columns - 1)) / columns) : width
      const boxes = items.map(c => { const b = layout(c, cellWidth, kind); return columns ? {...b, width: cellWidth} : b })
      const inner = flow(boxes, width, gap, kind !== 'select' || options.selectWrap, style)
      return stack([text(node.label, 'caption', width, t.inkMuted), inner], inner.width, t.gapTight)
    }
    if (kind === 'spacer') return {svg: '', width: 0, height: T.spacerSize(t, style)}
    if (kind === 'divider') return {svg: `<line x1="0" x2="${width}" y1="0" y2="0" stroke="${t.line}"/>`, width, height: 1}
    if (kind === 'table') {
      const rows = [{options: node.options || [], header: true}, ...children]
      let svg = '', y = 0, bodyRows = 0
      for (const row of rows) {
        const values = row.options || []
        if (!values.length) continue
        if (!row.header && bodyRows++ > 0) {
          svg += `<line x1="${t.padListX}" x2="${width - t.padListX}" y1="${y}" y2="${y}" stroke="${t.lineSoft}" stroke-width="${t.borderWidth}"/>`
          y += t.borderWidth
        }
        const cellWidth = Math.max(1, (width - t.padListX * 2) / values.length)
        const cells = values.map(c => text(c, row.header ? 'caption' : 'body', cellWidth,
          row.header ? t.inkMuted : t.ink, {weight: row.header ? t.weightHeading : t.weightBody}))
        const top = row.header ? t.gapBase : t.padListY
        const bottom = row.header ? t.gapTight : t.padListY
        const contentHeight = Math.max(...cells.map(c => c.height)), height = contentHeight + top + bottom
        const fill = row.header ? t.surfaceRaised : T.toneFill(t, row.style, t.surfaceRaised)
        svg += `<g transform="translate(0,${y})">${rect(width, height, fill)}${cells.map((c, i) => move(c, t.padListX + i * cellWidth, top + (contentHeight - c.height) / 2)).join('')}</g>`
        y += height
      }
      return {svg: svg + rect(width, y, 'none', t.radiusCard, t.line), width, height: y}
    }
    if (kind === 'numberfield') {
      // One pill: - value + inside a single field-coloured capsule.
      const control = t.controlHeight, pill = Math.min(width, control * 5)
      const value = text(formattedInt(node), 'heading', Math.max(1, pill - 2 * control), t.ink,
        {family: t.metricFontFamily ?? t.fontFamily, weight: t.weightHeading})
      function step(label, x, enabled) {
        const caption = text(label, 'heading', control, t.primaryInk)
        return `<g opacity="${enabled ? 1 : 0.4}" transform="translate(${x},0)">${move(caption, (control - caption.width) / 2, (control - caption.height) / 2)}</g>`
      }
      const svg = rect(pill, control, t.secondaryFill, control / 2) +
        step('-', 0, node.enabled !== false && node.numberValue > node.minimum) +
        move(value, (pill - value.width) / 2, (control - value.height) / 2) +
        step('+', pill - control, node.enabled !== false && node.numberValue < node.maximum)
      const inner = stack([text(node.label, 'caption', width, t.inkSoft), {svg, width: pill, height: control}], width, t.gapTight)
      return frame(inner, width, 0, t.gapTight, t.gapTight)
    }
    if (kind === 'timefield' || kind === 'datefield' || kind === 'textfield' || kind === 'field') {
      const label = text(node.label, 'caption', width, t.inkMuted)
      const value = kind === 'timefield' ? formattedTime(node) : kind === 'datefield' ? formattedDate(node) : node.value || node.text || ''
      const content = text(value, 'body', Math.max(1, width - t.padBase * 2))
      const height = Math.max(t.controlHeight, content.height + t.padTight * 2)
      return stack([label, {svg: rect(width, height, t.fieldFill ?? t.surfaceRaised, t.radiusControl, t.fieldLine ?? t.lineStrong) + move(content, t.padBase, (height - content.height) / 2), width, height}], width, t.gapTight)
    }
    if (kind === 'sparkline') {
      const height = 260, series = node.series || [], maximum = Math.max(1, node.maximum || 0)
      const color = T.toneEdge(t, style, t.primary), plotWidth = width
      let svg = ''
      if (node.bars) {
        const gap = 6, bar = Math.max(0, (plotWidth - gap * Math.max(0, series.length - 1)) / Math.max(1, series.length))
        svg = series.map((value, i) => { const h = Math.max(0, Math.min(1, value / maximum)) * height; return `<rect x="${i * (bar + gap)}" y="${height - h}" width="${bar}" height="${h}" fill="${color}"/>` }).join('')
      } else {
        const points = series.map((value, i) => `${(series.length > 1 ? i / (series.length - 1) : 0.5) * plotWidth},${height - Math.max(0, Math.min(1, value / maximum)) * height}`).join(' ')
        svg = `<polyline points="${points}" fill="none" stroke="${color}" stroke-width="2"/>`
      }
      return stack([text(node.label, 'body', width, t.inkSoft), {svg, width, height}], width, 4)
    }
    if (kind === 'slider' || kind === 'progress') {
      const frac = Math.max(0, Math.min(1, (node.eventValue - (node.minimum || 0)) / Math.max(1, (node.maximum || 100) - (node.minimum || 0))))
      const color = T.toneEdge(t, style, t.primary), x = 7 + Math.max(0, width - 14) * frac
      return stack([text(node.label, 'caption', width, t.inkMuted), {svg: `<rect x="7" y="8" width="${Math.max(0, width - 14)}" height="4" rx="2" fill="${t.secondaryFill}"/><rect x="7" y="8" width="${Math.max(0, x - 7)}" height="4" fill="${color}"/>` + (kind === 'slider' ? `<circle cx="${x}" cy="10" r="7" fill="${color}"/>` : ''), width, height: 20}], width, t.gapTight)
    }
    if (kind === 'stat' || kind === 'numberstat') {
      return stack([text(node.label, 'caption', width, t.inkMuted), text(kind === 'numberstat' ? formattedInt(node) : node.text, 'metric', width, T.toneInk(t, style, t.ink)), text(node.value, 'caption', width, t.inkSoft)], width, t.gapTight)
    }
    if (kind === 'progressring') {
      const size = t.controlHeight * 3, r = size / 2 - 7, c = size / 2
      const frac = Math.max(0, Math.min(1, node.eventValue / (node.maximum > 0 ? node.maximum : 100)))
      const length = 2 * Math.PI * r, color = T.toneEdge(t, style, t.primary)
      const centre = text(node.text || Math.round(frac * 100) + '%', 'heading', size - 36, T.toneInk(t, style, t.ink), {family: t.metricFontFamily ?? t.fontFamily, weight: t.weightMetric})
      const ring = {svg: `<circle cx="${c}" cy="${c}" r="${r}" fill="none" stroke="${t.lineSoft}" stroke-width="12"/>` +
        `<circle cx="${c}" cy="${c}" r="${r}" fill="none" stroke="${color}" stroke-width="12" stroke-linecap="round" stroke-dasharray="${length * frac} ${length}" transform="rotate(-90 ${c} ${c})"/>` +
        move(centre, (size - centre.width) / 2, (size - centre.height) / 2), width: size, height: size}
      const label = text(node.label, 'caption', width, t.inkStrong, {weight: 500})
      const inner = stack([{svg: move(ring, (width - size) / 2, 0), width, height: size}, {svg: move(label, (width - label.width) / 2, 0), width, height: label.height}], width, t.gapTight)
      return frame(inner, width, 0, t.gapBase, t.gapBase)
    }
    if (kind === 'tilegrid') {
      const pad = t.padBase, inner = Math.max(1, width - 2 * pad), gap = t.gapLoose, half = (inner - gap) / 2
      let svg = '', x = 0, y = 0, rowHeight = 0
      for (const child of children) {
        const wide = child.columns >= 2, w = wide ? inner : half
        if (x > 0 && (wide || x + w > inner + 0.5)) { y += rowHeight + gap; x = 0; rowHeight = 0 }
        const box = nodeBox(child, w, 'tilegrid')
        svg += move(box, x, y); rowHeight = Math.max(rowHeight, box.height); x += w + gap
        if (wide) { y += rowHeight + gap; x = 0; rowHeight = 0 }
      }
      if (x > 0) y += rowHeight
      else y = Math.max(0, y - gap)
      return {svg: move({svg, width: inner, height: y}, pad, 0), width, height: y + 2 * t.gapTight}
    }
    if (kind === 'tile') {
      const w = Math.max(1, width - 2 * t.padCard)
      const boxes = [text(node.label, 'caption', w, t.inkSoft, {weight: Math.max(t.weightHeading, 500)}),
        text(node.text, 'metric', w, T.toneInk(t, style, t.ink), {weight: t.weightMetric}),
        text(node.value, 'caption', w, t.inkSoft)]
      return frame(stack(boxes, w, t.gapTight), width, t.padCard, t.padCard, t.padCard, T.toneFill(t, style, t.surface), t.radiusCard, t.lineSoft)
    }
    if (kind === 'listitem') {
      const pad = t.padListX, w = Math.max(1, width - 2 * pad)
      const right = text(node.value, 'body', w / 2, t.inkSoft)
      const left = stack([text(node.text, 'body', w - right.width - t.gapBase, t.ink, {weight: t.weightHeading}), text(node.label, 'caption', w - right.width - t.gapBase, t.inkMuted)], w - right.width - t.gapBase, 2)
      const h = Math.max(left.height, right.height, t.controlHeight)
      const svg = move(left, 0, (h - left.height) / 2) + move(right, w - right.width, (h - right.height) / 2)
      return {svg: move({svg, width: w, height: h}, pad, t.padTight) + `<line x1="${pad}" x2="${width - pad}" y1="${h + 2 * t.padTight}" y2="${h + 2 * t.padTight}" stroke="${t.lineSoft}"/>`, width, height: h + 2 * t.padTight + 1}
    }
    if (kind === 'badge') {
      const content = text(node.text, 'caption', Math.max(1, width - t.padTight * 2), T.toneInk(t, style, t.ink))
      return frame(content, Math.min(width, content.width + t.padTight * 2), t.padTight, t.gapTight, t.gapTight, T.toneFill(t, style, t.secondaryFill), t.radiusSmall)
    }
    // Unsupported kinds remain explicit in the proof. This is not device output.
    const content = text(`${kind}: ${node.text || node.label || ''}`, 'body', Math.max(1, width - 2 * t.padTight), t.inkMuted)
    return frame(content, width, t.padTight, t.padTight, t.padTight, t.surface, t.radiusSmall, t.line)
  }
  function layout(node, width, parent = '') {
    const box = nodeBox(node, width, parent)
    return {...box, svg: box.svg ? `<g data-kind="${esc(node.kind)}">${box.svg}</g>` : ''}
  }
  return layout
}

function liftFilter(t) {
  const c = /^#([0-9A-F]{2})([0-9A-F]{6})$/i.exec(t.shadowColor)
  if (!c || t.shadowRadius <= 0) return ''
  return `<defs><filter id="lift" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="${t.shadowOffsetY}" stdDeviation="${t.shadowRadius / 2}" flood-color="#${c[2]}" flood-opacity="${parseInt(c[1], 16) / 255}"/></filter></defs>`
}

async function main() {
  const args = Object.fromEntries(process.argv.slice(2).map(arg => { const at = arg.indexOf('='); return [arg.slice(2, at), arg.slice(at + 1)] }))
  const width = args.width === undefined ? 360 : Number(args.width)
  if (!Number.isFinite(width) || width <= 0) throw Error('--width must be a positive number')
  const chunks = []
  for await (const chunk of process.stdin) chunks.push(chunk)
  const tree = JSON.parse(Buffer.concat(chunks).toString('utf8'))
  const app = tree && tree.kind === 'apptheme' ? tree : null
  // A preset override ignores the fixture seed so each matrix cell tests its preset.
  const theme = T.resolveTheme(args.preset || (app && app.style) || 'clean', args.preset ? '' : (app && app.value) || '', args.dark === 'true')
  const layout = createRenderer(theme, {embedded: args.embedded === 'true', selectWrap: args['select-wrap'] !== 'false'})
  const box = layout(tree, width), height = Math.max(1, box.height)
  const metadata = {approximate: true, preset: theme.preset, width, dark: args.dark === 'true', embedded: args.embedded === 'true', label: args.label || ''}
  process.stdout.write(`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}"><title>${esc(args.label || 'Approximate Vera proof')}</title><metadata>${esc(JSON.stringify(metadata))}</metadata>${liftFilter(theme)}${rect(width, height, theme.background)}${box.svg}</svg>\n`)
}
main().catch(error => { console.error(error.stack || error); process.exitCode = 1 })

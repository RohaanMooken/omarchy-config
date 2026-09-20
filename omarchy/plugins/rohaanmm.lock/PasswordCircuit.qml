import QtQuick
import QtQuick.Shapes
import qs.Commons

// Circuit-board password feedback. Every keystroke drops a *cluster* of pads —
// minCluster..maxCluster of them — somewhere in this item's bounds. The first
// pad of a cluster wires outward to a neighbouring cluster or back to the hub;
// the rest wire into their own cluster, so each character reads as a small
// sub-circuit rather than a lone dot.
//
// Traces are not drawn as the crow flies. They are laid down by a maze router:
// A* over a coarse occupancy grid whose state is (cell, heading), with a
// penalty for turning and a surcharge for riding over an existing trace. That
// is roughly what a PCB autorouter does — long orthogonal runs, few corners,
// routed *around* pads instead of through them. Corners are then chamfered to
// 45° the way real board routing is.
//
// Backspace pops the whole cluster. Drive it with a length, never text.
Item {
  id: root

  property int count: 0
  property color ink: Color.lock.borderActive

  // --- Cluster shape -------------------------------------------------------
  property int minCluster: 6
  property int maxCluster: 9
  property real clusterSpread: 64      // how far satellites sit from the anchor
  property real anchorSpacing: 78      // breathing room between cluster centres
  property real minRadius: 10
  property real maxRadius: 18
  property real gap: 10                 // clear space between neighbouring pads
  // Share of clusters wired straight back to the hub rather than to a
  // neighbour. Higher spreads the net wider; lower grows longer daisy chains.
  property real hubShare: 0.3

  // --- Router --------------------------------------------------------------
  property real cellSize: 8            // routing grid pitch
  property real turnCost: 4            // discourages staircasing
  property real crossCost: 6           // discourages riding an existing trace
  property real padClearance: 3        // keep-out ring around each pad
  property real chamfer: 7
  // Weighted A*: >1 trades a guaranteed-cheapest route for a much smaller
  // search. Traces stay tidy; the router just stops proving they are optimal.
  property real heuristicWeight: 1.6

  property int spawnAttempts: 240
  property int traceMs: 260
  property int stagger: 55             // per-pad delay within a cluster

  readonly property real hubX: width / 2
  readonly property real hubY: height / 2
  readonly property real hubSize: 14 + Math.min(nodes.count, 40) * 0.35
  readonly property real hubKeepout: 30

  function reset() { nodes.clear(); rebuildGrid() }
  function surge() { surgePulse.restart() }

  ListModel { id: nodes }

  // ---------------------------------------------------------------- grid ---
  // occ: 0 free, 1 existing trace (passable, priced), 2 pad or hub (blocked).
  property int cols: 0
  property int rows: 0
  property var occ: null

  // Search scratch, allocated once per grid size and reused. `visitGen` stamps
  // which entries belong to the current search, so a route costs no clearing
  // pass over ~31k states.
  property var gScore: null
  property var cameFrom: null
  property var visitGen: null
  property int searchGen: 0

  Component.onCompleted: { ensureGrid(); syncNodes() }
  onWidthChanged: { ensureGrid(); syncNodes() }
  onHeightChanged: { ensureGrid(); syncNodes() }

  function ensureGrid() {
    if (width <= 0 || height <= 0) return
    var c = Math.max(4, Math.floor(width / cellSize))
    var r = Math.max(4, Math.floor(height / cellSize))
    if (occ !== null && c === cols && r === rows) return
    cols = c
    rows = r
    occ = new Uint8Array(cols * rows)
    gScore = new Float32Array(cols * rows * 4)
    cameFrom = new Int32Array(cols * rows * 4)
    visitGen = new Int32Array(cols * rows * 4)
    searchGen = 0
    rebuildGrid()
  }

  function cellCenterX(c) { return (c + 0.5) * cellSize }
  function cellCenterY(r) { return (r + 0.5) * cellSize }
  function colAt(x) { return Math.max(0, Math.min(cols - 1, Math.floor(x / cellSize))) }
  function rowAt(y) { return Math.max(0, Math.min(rows - 1, Math.floor(y / cellSize))) }

  function markDisc(x, y, rr, v) {
    var rr2 = rr * rr
    var c1 = colAt(x + rr)
    var r1 = rowAt(y + rr)
    for (var c = colAt(x - rr); c <= c1; c++) {
      for (var r = rowAt(y - rr); r <= r1; r++) {
        var dx = cellCenterX(c) - x
        var dy = cellCenterY(r) - y
        if (dx * dx + dy * dy > rr2) continue
        var i = r * cols + c
        if (occ[i] < v) occ[i] = v
      }
    }
  }

  function markWire(pts, v) {
    for (var i = 1; i < pts.length; i++) {
      var ax = pts[i - 1][0], ay = pts[i - 1][1]
      var bx = pts[i][0], by = pts[i][1]
      var len = Math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay))
      var steps = Math.max(1, Math.ceil(len / (cellSize * 0.5)))
      for (var s = 0; s <= steps; s++) {
        var t = s / steps
        var idx = rowAt(ay + (by - ay) * t) * cols + colAt(ax + (bx - ax) * t)
        if (occ[idx] < v) occ[idx] = v
      }
    }
  }

  // Wires first, pads second: a pad always wins the cell it sits on.
  function rebuildGrid() {
    if (occ === null) return
    occ.fill(0)
    for (var i = 0; i < nodes.count; i++) markWire(JSON.parse(nodes.get(i).wire), 1)
    markDisc(hubX, hubY, hubKeepout, 2)
    for (var j = 0; j < nodes.count; j++) {
      var n = nodes.get(j)
      markDisc(n.cx, n.cy, n.rad + padClearance, 2)
    }
  }

  // Temporarily open a disc in the grid so a route may leave its own pad and
  // enter its parent's. Cleared cells are pushed onto `saved` for restoring.
  function clearDisc(d, saved) {
    var rr2 = d.r * d.r
    var c1 = colAt(d.x + d.r)
    var r1 = rowAt(d.y + d.r)
    for (var c = colAt(d.x - d.r); c <= c1; c++) {
      for (var r = rowAt(d.y - d.r); r <= r1; r++) {
        var dx = cellCenterX(c) - d.x
        var dy = cellCenterY(r) - d.y
        if (dx * dx + dy * dy > rr2) continue
        var i = r * cols + c
        if (occ[i] !== 0) { saved.push(i); saved.push(occ[i]); occ[i] = 0 }
      }
    }
  }

  // -------------------------------------------------------------- router ---
  // A* over (cell, heading). Heading is part of the state so a direction change
  // can be priced, which is what makes the output read as board routing —
  // long straight runs joined by a few deliberate corners — rather than a
  // staircase. Returns an orthogonal polyline, or null when the net is boxed in.
  function routeCells(x0, y0, x1, y1, openDiscs) {
    if (occ === null) return null

    var saved = []
    for (var d = 0; d < openDiscs.length; d++) clearDisc(openDiscs[d], saved)

    // Opening those keep-outs also unblocks any *third* pad that happens to
    // overlap them — dense clusters overlap constantly. Put every pad back
    // except the two endpoints, so this net may leave its own pad and enter
    // its parent's without being handed a shortcut through a neighbour. The
    // restore pass below undoes all of it either way.
    for (var q = 0; q < nodes.count; q++) {
      var nq = nodes.get(q)
      if (Math.abs(nq.cx - x0) < 0.01 && Math.abs(nq.cy - y0) < 0.01) continue
      if (Math.abs(nq.cx - x1) < 0.01 && Math.abs(nq.cy - y1) < 0.01) continue
      markDisc(nq.cx, nq.cy, nq.rad + padClearance, 2)
    }
    var hp = hubPad()
    if (Math.abs(hp.x - x1) > 0.01 || Math.abs(hp.y - y1) > 0.01)
      markDisc(hubX, hubY, hubKeepout, 2)

    var c0 = colAt(x0), r0 = rowAt(y0)
    var c1 = colAt(x1), r1 = rowAt(y1)
    var goal = r1 * cols + c1

    searchGen++
    var gen = searchGen
    var g = gScore, from = cameFrom, seen = visitGen
    var w = heuristicWeight

    var DC = [1, -1, 0, 0]
    var DR = [0, 0, 1, -1]
    var heap = []
    var start = r0 * cols + c0
    for (var h = 0; h < 4; h++) {
      var s0 = start * 4 + h
      g[s0] = 0
      from[s0] = -1
      seen[s0] = gen
      heapPush(heap, w * (Math.abs(c0 - c1) + Math.abs(r0 - r1)), 0, s0)
    }

    var found = -1
    while (heap.length > 0) {
      var cur = heapPop(heap)
      var st = cur.s
      if (cur.g > g[st] + 0.001) continue          // stale heap entry
      var ci = st >> 2
      if (ci === goal) { found = st; break }
      var dir = st & 3
      var cc = ci % cols
      var cr = Math.floor(ci / cols)
      for (var nd = 0; nd < 4; nd++) {
        var nc = cc + DC[nd]
        var nr = cr + DR[nd]
        if (nc < 0 || nr < 0 || nc >= cols || nr >= rows) continue
        var ni = nr * cols + nc
        var o = occ[ni]
        if (o === 2) continue
        var step = 1 + (o === 1 ? crossCost : 0) + (nd !== dir ? turnCost : 0)
        var ns = ni * 4 + nd
        var ng = g[st] + step
        if (seen[ns] === gen && ng >= g[ns]) continue
        g[ns] = ng
        from[ns] = st
        seen[ns] = gen
        heapPush(heap, ng + w * (Math.abs(nc - c1) + Math.abs(nr - r1)), ng, ns)
      }
    }

    for (var k = saved.length - 2; k >= 0; k -= 2) occ[saved[k]] = saved[k + 1]
    if (found < 0) return null

    var cells = []
    for (var s = found; s >= 0; s = from[s]) cells.push(s >> 2)
    var pts = []
    for (var p = cells.length - 1; p >= 0; p--) {
      pts.push([cellCenterX(cells[p] % cols), cellCenterY(Math.floor(cells[p] / cols))])
    }
    return pts
  }

  function heapPush(h, f, g, s) {
    h.push({ f: f, g: g, s: s })
    var i = h.length - 1
    while (i > 0) {
      var p = (i - 1) >> 1
      if (h[p].f <= h[i].f) break
      var t = h[p]; h[p] = h[i]; h[i] = t
      i = p
    }
  }

  function heapPop(h) {
    var top = h[0]
    var last = h.pop()
    if (h.length > 0) {
      h[0] = last
      var i = 0
      for (;;) {
        var l = 2 * i + 1, r = l + 1, m = i
        if (l < h.length && h[l].f < h[m].f) m = l
        if (r < h.length && h[r].f < h[m].f) m = r
        if (m === i) break
        var t = h[m]; h[m] = h[i]; h[i] = t
        i = m
      }
    }
    return top
  }

  function simplify(pts) {
    if (pts.length < 3) return pts
    var out = [pts[0]]
    for (var i = 1; i < pts.length - 1; i++) {
      var a = out[out.length - 1], b = pts[i], c = pts[i + 1]
      var cross = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
      if (Math.abs(cross) > 0.001) out.push(b)
    }
    out.push(pts[pts.length - 1])
    return out
  }

  // Every 90° corner becomes two 45° bends, clamped so short segments do not
  // swallow their own neighbours.
  function chamferPolyline(pts, amount) {
    if (pts.length < 3) return pts
    var out = [pts[0]]
    for (var i = 1; i < pts.length - 1; i++) {
      var a = pts[i - 1], b = pts[i], c = pts[i + 1]
      var d1x = b[0] - a[0], d1y = b[1] - a[1]
      var d2x = c[0] - b[0], d2y = c[1] - b[1]
      var l1 = Math.sqrt(d1x * d1x + d1y * d1y)
      var l2 = Math.sqrt(d2x * d2x + d2y * d2y)
      if (l1 < 0.01 || l2 < 0.01) continue
      var m = Math.min(amount, l1 * 0.45, l2 * 0.45)
      out.push([b[0] - d1x / l1 * m, b[1] - d1y / l1 * m])
      out.push([b[0] + d2x / l2 * m, b[1] + d2y / l2 * m])
    }
    out.push(pts[pts.length - 1])
    return out
  }

  function decode(wire) {
    var a = JSON.parse(wire)
    var out = []
    for (var i = 0; i < a.length; i++) out.push(Qt.point(a[i][0], a[i][1]))
    return out
  }

  // Walk the polyline and cut it at t of its total length so the trace draws
  // itself corner by corner.
  function clipPath(pts, t) {
    if (t >= 1) return pts
    var total = 0
    var segs = []
    for (var i = 1; i < pts.length; i++) {
      var ax = pts[i].x - pts[i - 1].x
      var ay = pts[i].y - pts[i - 1].y
      var len = Math.sqrt(ax * ax + ay * ay)
      segs.push(len)
      total += len
    }
    if (total <= 0) return [pts[0]]
    var target = total * t
    var out = [pts[0]]
    var acc = 0
    for (var s = 0; s < segs.length; s++) {
      if (acc + segs[s] >= target) {
        var f = segs[s] > 0 ? (target - acc) / segs[s] : 0
        out.push(Qt.point(pts[s].x + (pts[s + 1].x - pts[s].x) * f,
                          pts[s].y + (pts[s + 1].y - pts[s].y) * f))
        return out
      }
      acc += segs[s]
      out.push(pts[s + 1])
    }
    return out
  }

  // ------------------------------------------------------------ placement ---
  function groupCount() {
    return nodes.count === 0 ? 0 : nodes.get(nodes.count - 1).grp + 1
  }

  // Leaves the occupancy grid stale on purpose; syncNodes rebuilds once after
  // the last pop, so clearing a long password stays linear rather than
  // rebuilding the whole board per keystroke.
  function popGroup() {
    if (nodes.count === 0) return
    var g = nodes.get(nodes.count - 1).grp
    while (nodes.count > 0 && nodes.get(nodes.count - 1).grp === g) nodes.remove(nodes.count - 1)
  }

  onCountChanged: syncNodes()

  // Never loop on spawnGroup's success. Before layout has run there is no grid
  // and nothing can be placed; bailing out leaves the board short a cluster
  // until the size arrives, where onWidthChanged re-syncs. Spinning here would
  // wedge the UI thread, which on a lock screen means no way back in.
  function syncNodes() {
    var popped = false
    while (groupCount() > count) { popGroup(); popped = true }
    if (popped) rebuildGrid()
    while (groupCount() < count) {
      var before = groupCount()
      spawnGroup()
      if (groupCount() === before) return
    }
  }

  function hubPad() {
    return { x: cellCenterX(colAt(hubX)), y: cellCenterY(rowAt(hubY)), r: hubKeepout }
  }

  function clears(x, y, r) {
    for (var i = 0; i < nodes.count; i++) {
      var n = nodes.get(i)
      var dx = n.cx - x, dy = n.cy - y
      if (Math.sqrt(dx * dx + dy * dy) < n.rad + r + gap) return false
    }
    var hdx = hubX - x, hdy = hubY - y
    if (Math.sqrt(hdx * hdx + hdy * hdy) <= r + hubKeepout) return false
    return !coversWire(x, y, r + 1)
  }

  // A pad dropped on top of an existing trace reads as the trace running
  // straight through the circle, so refuse those spots too.
  function coversWire(x, y, rr) {
    if (occ === null) return false
    var rr2 = rr * rr
    var c1 = colAt(x + rr)
    var r1 = rowAt(y + rr)
    for (var c = colAt(x - rr); c <= c1; c++) {
      for (var r = rowAt(y - rr); r <= r1; r++) {
        var dx = cellCenterX(c) - x
        var dy = cellCenterY(r) - y
        if (dx * dx + dy * dy > rr2) continue
        if (occ[r * cols + c] === 1) return true
      }
    }
    return false
  }

  function nearestPadDist(x, y) {
    var best = Math.sqrt((x - hubX) * (x - hubX) + (y - hubY) * (y - hubY)) - hubKeepout
    for (var i = 0; i < nodes.count; i++) {
      var n = nodes.get(i)
      var dx = n.cx - x, dy = n.cy - y
      var d = Math.sqrt(dx * dx + dy * dy) - n.rad
      if (d < best) best = d
    }
    return best
  }

  // Clusters grow outward from the hub rather than scattering. Candidates that
  // crowd existing pads are thrown out, and of the rest the *tightest* one
  // wins — farthest-point sampling would spread every keystroke to the far
  // corners and leave the board strung together by board-length traces.
  function findAnchor() {
    var pad = maxRadius + clusterSpread * 0.4
    if (nodes.count === 0) {
      var a0 = Math.random() * Math.PI * 2
      var d0 = hubKeepout + clusterSpread * 0.7
      return {
        x: Math.max(pad, Math.min(width - pad, hubX + Math.cos(a0) * d0)),
        y: Math.max(pad, Math.min(height - pad, hubY + Math.sin(a0) * d0))
      }
    }
    // Candidates are drawn from an ellipse around the hub that widens with the
    // password, so the net grows radially out of the middle and stays balanced
    // instead of drifting into one lopsided band.
    var frac = Math.min(1, Math.sqrt((groupCount() + 1) / 26))
    var rx = Math.max(1, width / 2 - pad)
    var ry = Math.max(1, height / 2 - pad)
    var best = null, bestD = Infinity
    var fallback = { x: hubX, y: hubY }, fallbackD = -Infinity
    for (var i = 0; i < 96; i++) {
      var ang = Math.random() * Math.PI * 2
      var rad = Math.sqrt(Math.random()) * frac
      var x = hubX + Math.cos(ang) * rad * rx
      var y = hubY + Math.sin(ang) * rad * ry
      var d = nearestPadDist(x, y)
      if (d > fallbackD) { fallbackD = d; fallback = { x: x, y: y } }
      if (d < anchorSpacing || d >= bestD) continue
      bestD = d
      best = { x: x, y: y }
    }
    return best === null ? fallback : best
  }

  // Rejection sampling inside a disc around the cluster anchor (or the whole
  // board when `global`). Pads are snapped to grid centres so every trace ends
  // exactly on a routable cell. Shrink as the board fills so late keystrokes
  // still land.
  function findSpot(ax, ay, spread, r, global) {
    for (var i = 0; i < spawnAttempts; i++) {
      var x, y
      if (global) {
        x = r + Math.random() * Math.max(1, width - 2 * r)
        y = r + Math.random() * Math.max(1, height - 2 * r)
      } else {
        var a = Math.random() * Math.PI * 2
        var d = spread * Math.sqrt(Math.random())
        x = ax + Math.cos(a) * d
        y = ay + Math.sin(a) * d
      }
      x = cellCenterX(colAt(x))
      y = cellCenterY(rowAt(y))
      if (x < r || y < r || x > width - r || y > height - r) continue
      if (clears(x, y, r)) return { x: x, y: y, r: r }
      if (i % 60 === 59) r = Math.max(minRadius * 0.55, r * 0.85)
    }
    return null
  }

  // A cluster's lead pad reaches out to an earlier cluster (or the hub); every
  // parent is therefore at a lower index than its child, so popping from the
  // end can never orphan a trace.
  function outerParent(x, y, grp) {
    if (grp === 0 || Math.random() < hubShare) return hubPad()
    var near = []
    for (var i = 0; i < nodes.count; i++) {
      var n = nodes.get(i)
      if (n.grp >= grp) continue
      var dx = n.cx - x, dy = n.cy - y
      near.push({ i: i, d: dx * dx + dy * dy })
    }
    if (near.length === 0) return hubPad()
    near.sort(function (a, b) { return a.d - b.d })
    var p = nodes.get(near[Math.floor(Math.random() * Math.min(3, near.length))].i)
    return { x: p.cx, y: p.cy, r: p.rad }
  }

  function clusterParent(x, y, grp) {
    var bi = -1, bd = Infinity
    for (var i = 0; i < nodes.count; i++) {
      var n = nodes.get(i)
      if (n.grp !== grp) continue
      var dx = n.cx - x, dy = n.cy - y
      var d = dx * dx + dy * dy
      if (d < bd) { bd = d; bi = i }
    }
    if (bi < 0) return outerParent(x, y, grp)
    var p = nodes.get(bi)
    return { x: p.cx, y: p.cy, r: p.rad }
  }

  function addNode(x, y, r, parent, grp, ord) {
    var pts = routeCells(x, y, parent.x, parent.y,
                         [{ x: x, y: y, r: r + padClearance + cellSize },
                          { x: parent.x, y: parent.y, r: parent.r + padClearance + cellSize }])
    if (pts === null || pts.length < 2) pts = [[x, y], [parent.x, parent.y]]
    else pts = chamferPolyline(simplify(pts), chamfer)

    nodes.append({
      cx: x, cy: y, rad: r,
      px: parent.x, py: parent.y,
      grp: grp, ord: ord,
      wire: JSON.stringify(pts)
    })
    markWire(pts, 1)
    markDisc(x, y, r + padClearance, 2)
  }

  // Always lands at least one pad, so groupCount() advances and onCountChanged
  // cannot spin.
  function spawnGroup() {
    ensureGrid()
    if (occ === null) return
    var grp = groupCount()
    var size = minCluster + Math.floor(Math.random() * (maxCluster - minCluster + 1))
    var anchor = findAnchor()
    var placed = 0
    for (var i = 0; i < size; i++) {
      var r = minRadius + Math.random() * (maxRadius - minRadius)
      if (placed > 0) r = Math.min(r, maxRadius * 0.7)
      var spot = findSpot(anchor.x, anchor.y,
                          placed === 0 ? clusterSpread * 0.35 : clusterSpread,
                          r, false)
      if (spot === null && placed === 0) spot = findSpot(0, 0, 0, r, true)
      if (spot === null) break
      addNode(spot.x, spot.y, spot.r,
              placed === 0 ? outerParent(spot.x, spot.y, grp)
                           : clusterParent(spot.x, spot.y, grp),
              grp, placed)
      placed++
    }
    if (placed === 0) {
      var p = hubPad()
      addNode(p.x, p.y, minRadius * 0.6, p, grp, 0)
    }
  }

  // --------------------------------------------------------------- paint ---
  Repeater {
    model: nodes

    delegate: Item {
      id: node
      anchors.fill: parent

      property real cx: model.cx
      property real cy: model.cy
      property real rad: model.rad
      property real px: model.px
      property real py: model.py
      property int ord: model.ord
      readonly property var pts: root.decode(model.wire)
      property real grow: 0
      property real trace: 0

      SequentialAnimation on grow {
        PauseAnimation { duration: node.ord * root.stagger }
        NumberAnimation { from: 0; to: 1; duration: 170; easing.type: Easing.OutBack }
      }

      SequentialAnimation on trace {
        PauseAnimation { duration: node.ord * root.stagger + 60 }
        NumberAnimation { from: 0; to: 1; duration: root.traceMs; easing.type: Easing.OutCubic }
      }

      Shape {
        anchors.fill: parent
        ShapePath {
          strokeColor: root.ink
          strokeWidth: 1.5
          fillColor: "transparent"
          capStyle: ShapePath.RoundCap
          joinStyle: ShapePath.MiterJoin
          PathPolyline {
            path: root.clipPath(node.pts, node.trace)
          }
        }
      }

      // Junction pad where the trace meets its parent, so branches read as
      // solder points rather than lines crossing by accident.
      Rectangle {
        width: 4; height: 4; radius: 1
        x: node.px - 2
        y: node.py - 2
        color: root.ink
        opacity: node.trace >= 1 ? 0.9 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }
      }

      Rectangle {
        x: node.cx - node.rad * node.grow
        y: node.cy - node.rad * node.grow
        width: node.rad * 2 * node.grow
        height: width
        radius: width / 2
        color: "transparent"
        border.color: root.ink
        border.width: 1.5
        opacity: node.grow
      }

      Rectangle {
        width: 3; height: 3; radius: 1.5
        x: node.cx - 1.5
        y: node.cy - 1.5
        color: root.ink
        opacity: node.grow
      }
    }
  }

  Rectangle {
    id: hub
    width: root.hubSize
    height: width
    radius: 2
    x: root.hubX - width / 2
    y: root.hubY - height / 2
    color: "transparent"
    border.color: root.ink
    border.width: 1.5
    rotation: 45
    opacity: nodes.count > 0 ? 1 : 0.35
    Behavior on width { NumberAnimation { duration: 180 } }
    Behavior on opacity { NumberAnimation { duration: 180 } }
  }

  SequentialAnimation {
    id: surgePulse
    NumberAnimation { target: hub; property: "scale"; to: 1.9; duration: 110 }
    NumberAnimation { target: hub; property: "scale"; to: 1.0; duration: 220
                      easing.type: Easing.OutBack }
  }
}

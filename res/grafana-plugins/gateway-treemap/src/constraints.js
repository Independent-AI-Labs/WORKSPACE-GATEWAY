/*
 * gateway-treemap - tile-area constraints (pure, dependency-free).
 *
 * d3.treemap normalises the sum of the leaf values to the panel area, so with
 * no padding a leaf's drawn area is
 *
 *   area_i = panelArea * layoutValue_i / sum(layoutValue)
 *
 * Both constraints below are derived from that relation:
 *   - maxTileArea caps a leaf's layout value so it cannot dominate the panel;
 *   - minTileArea merges the smallest leaves into one overflow tile so none of
 *     them collapses to a sub-pixel sliver.
 *
 * The functions here are pure (no DOM, no d3) so they can be unit-tested with
 * `node --test`.
 */
(function (root, factory) {
    var api = factory();
    if (typeof module === "object" && module && module.exports) {
        module.exports = api;
    }
    if (root) {
        root.GwTreemapConstraints = api;
    }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
    "use strict";

    function sum(values) {
        var total = 0;
        for (var i = 0; i < values.length; i++) {
            total += values[i];
        }
        return total;
    }

    function num(value, defaultValue) {
        var n = Number(value);
        return isFinite(n) ? n : defaultValue;
    }

    function clamp(value, lo, hi) {
        return value < lo ? lo : value > hi ? hi : value;
    }

    function pluck(items, field) {
        return items.map(function (item) {
            return item[field];
        });
    }

    // Attach a layoutValue to every item (raw value is kept for display).
    function withLayoutValue(items, values) {
        return items.map(function (item, i) {
            var copy = {};
            for (var key in item) {
                if (Object.prototype.hasOwnProperty.call(item, key)) {
                    copy[key] = item[key];
                }
            }
            copy.layoutValue = values[i];
            return copy;
        });
    }

    // Cap every leaf so no single tile exceeds `maxArea` px².
    //
    // Water-filling: find a cap level L so the capped weights
    // layoutValue_i = min(value_i, L) satisfy max_i layoutValue_i / V = L/V
    // <= fraction, with V = sum(layoutValue). If C is the set of capped values
    // (|C| = k, all of them > L) and S the sum of the rest, then
    //   V = S + k * L and L = fraction * V  =>  L = fraction * S / (1 - k*fraction).
    function capValues(items, panelArea, maxArea) {
        var cap = Number(maxArea);
        if (!(cap > 0) || !(panelArea > 0) || cap >= panelArea) {
            return withLayoutValue(items, pluck(items, "value"));
        }

        var fraction = cap / panelArea;
        var values = pluck(items, "value");
        var total = sum(values);
        var n = values.length;
        var limit;

        if (n === 0) {
            return [];
        }
        // Feasible only if the capped tiles can still fill the panel.
        if (n * fraction < 1 - 1e-9) {
            limit = total / n;
        } else {
            var order = values
                .map(function (_, i) {
                    return i;
                })
                .sort(function (a, b) {
                    return values[b] - values[a];
                });
            var cappedSum = 0;
            // If no tile actually exceeds `fraction` of the panel the cap is
            // inactive, so leave `limit` above every value (no capping).
            limit = Infinity;
            for (var k = 1; k <= n; k++) {
                var denom = 1 - k * fraction;
                if (denom <= 1e-9) {
                    break;
                }
                cappedSum += values[order[k - 1]];
                var level = (fraction * (total - cappedSum)) / denom;
                var nextW = k < n ? values[order[k]] : -Infinity;
                if (values[order[k - 1]] > level + 1e-9 && nextW <= level + 1e-9) {
                    limit = level;
                    break;
                }
            }
        }

        return withLayoutValue(
            items,
            values.map(function (value) {
                return Math.min(value, limit);
            })
        );
    }

    function overflowNode(small, layoutValue, rawValue, label) {
        return {
            key: "__other__",
            label: label,
            value: rawValue,
            layoutValue: layoutValue,
            isOther: true,
            count: small.length
        };
    }

    // Merge leaves below `minArea` px² into a single overflow tile.
    function aggregateSmall(items, panelArea, minArea, otherLabel) {
        var min = Number(minArea);
        if (!(min > 0) || !(panelArea > 0) || items.length === 0) {
            return items;
        }

        var layoutValues = pluck(items, "layoutValue");
        var layoutTotal = sum(layoutValues);
        var minValue = (min * layoutTotal) / panelArea;
        if (!(minValue > 0)) {
            return items;
        }

        var big = [];
        var small = [];
        for (var i = 0; i < items.length; i++) {
            (items[i].layoutValue >= minValue ? big : small).push(items[i]);
        }
        if (small.length === 0) {
            return items;
        }

        var smallLayout = sum(pluck(small, "layoutValue"));
        var smallRaw = sum(pluck(small, "value"));
        var label = otherLabel || "Other";

        if (big.length === 0) {
            return [overflowNode(small, smallLayout, smallRaw, label)];
        }
        // If the combined overflow would itself be too small, drop it rather
        // than draw a tile that still violates the floor; the freed area
        // grows the remaining tiles.
        if (smallLayout >= minValue) {
            return big.concat([overflowNode(small, smallLayout, smallRaw, label)]);
        }
        return big;
    }

    // Public entry point: raw leaves in, constrained layout nodes out.
    function computeLayoutValues(leaves, width, height, options) {
        options = options || {};
        var panelArea = Number(width) * Number(height);
        if (!(panelArea > 0) || !leaves || leaves.length === 0) {
            return [];
        }

        var items = [];
        for (var i = 0; i < leaves.length; i++) {
            var leaf = leaves[i];
            if (leaf && isFinite(leaf.value) && leaf.value > 0) {
                var copy = {};
                for (var key in leaf) {
                    if (Object.prototype.hasOwnProperty.call(leaf, key)) {
                        copy[key] = leaf[key];
                    }
                }
                copy.layoutValue = leaf.value;
                items.push(copy);
            }
        }
        if (items.length === 0) {
            return [];
        }

        items = capValues(items, panelArea, options.maxArea);
        items = aggregateSmall(items, panelArea, options.minArea, options.otherLabel);
        return items;
    }

    // ---- auto font sizing ------------------------------------------------

    // Normalise each tile's area to [0, 1] through a cube root. Drawn area
    // grows like the square of a linear dimension and the eye reads volume,
    // so a cube-root-of-area scale spreads a 4x-area tile only ~1.59x in the
    // linear font size - a linear (or even sqrt) scale saturates the largest
    // tiles to nearly the same size.
    function sizeScales(rects, gap) {
        var list = rects || [];
        var g = num(gap, 0);
        var keys = [];
        var i;
        for (i = 0; i < list.length; i++) {
            var w = Math.max(0, list[i].w - g);
            var h = Math.max(0, list[i].h - g);
            keys.push(Math.cbrt(w * h));
        }
        if (keys.length === 0) {
            return [];
        }
        var lo = Math.min.apply(null, keys);
        var hi = Math.max.apply(null, keys);
        var span = hi - lo;
        var scales = [];
        for (i = 0; i < keys.length; i++) {
            scales.push(span > 1e-9 ? clamp((keys[i] - lo) / span, 0, 1) : 1);
        }
        return scales;
    }

    // Pick a font size per tile: interpolate min..max by the cube-root size
    // scale so the whole range is used over the real distribution and the
    // largest tiles are not flattened together.
    function fontSizes(rects, options, gap) {
        options = options || {};
        var list = rects || [];
        var minFont = num(options.minFontSize, 8);
        var maxFont = num(options.maxFontSize, 28);
        if (maxFont < minFont) {
            maxFont = minFont;
        }
        var sizes = [];
        var i;

        if (options.autoFontSize === false) {
            var fixed = clamp(num(options.fontSize, 12), minFont, maxFont);
            for (i = 0; i < list.length; i++) {
                sizes.push(fixed);
            }
            return sizes;
        }

        var g = num(gap, 0);
        var scales = sizeScales(list, g);
        for (i = 0; i < list.length; i++) {
            var size = minFont + (maxFont - minFont) * scales[i];
            // Keep text from outgrowing its own tile on very small panels.
            var side = Math.max(0, Math.min(list[i].w, list[i].h) - g);
            var fit = Math.min(maxFont, side * 0.42);
            sizes.push(clamp(size, minFont, Math.max(minFont, fit)));
        }
        return sizes;
    }

    // Decide which of the three tile-face lines fit, given the measured
    // heights of the percent/name/value texts, the measured name width and
    // the content box. `gap` is the scaled spacing inserted between the
    // percent and name lines (0 when the percent line is absent). The value
    // line is always shown.
    function lineFit(availW, availH, heights, nameWidth, gap) {
        var hP = num(heights && heights.percent, 0);
        var hN = num(heights && heights.name, 0);
        var hV = num(heights && heights.value, 0);
        var space = num(gap, 0);
        return {
            percent: availH + 0.5 >= hP + space + hN + hV,
            name: availH + 0.5 >= hN + hV && availW + 0.5 >= num(nameWidth, 0)
        };
    }

    // ---- treemap geometry (squarified, plus slice/dice) ------------------

    function worstRatio(row, side) {
        var s = 0;
        var rmin = Infinity;
        var rmax = 0;
        for (var i = 0; i < row.length; i++) {
            var area = row[i].area;
            s += area;
            if (area < rmin) {
                rmin = area;
            }
            if (area > rmax) {
                rmax = area;
            }
        }
        if (!(s > 0) || !(side > 0) || !(rmin > 0)) {
            return Infinity;
        }
        var s2 = s * s;
        var side2 = side * side;
        return Math.max((side2 * rmax) / s2, s2 / (side2 * rmin));
    }

    // Place a row along the shorter side of `rect`; return the leftover rect.
    function placeRow(row, rect, out) {
        var rowArea = 0;
        for (var i = 0; i < row.length; i++) {
            rowArea += row[i].area;
        }
        if (rect.w >= rect.h) {
            var colW = rowArea / rect.h;
            var y = rect.y;
            for (var a = 0; a < row.length; a++) {
                var h = row[a].area / colW;
                out.push({ node: row[a].node, x: rect.x, y: y, w: colW, h: h });
                y += h;
            }
            return { x: rect.x + colW, y: rect.y, w: Math.max(0, rect.w - colW), h: rect.h };
        }
        var stripH = rowArea / rect.w;
        var x = rect.x;
        for (var b = 0; b < row.length; b++) {
            var w = row[b].area / stripH;
            out.push({ node: row[b].node, x: x, y: rect.y, w: w, h: stripH });
            x += w;
        }
        return { x: rect.x, y: rect.y + stripH, w: rect.w, h: Math.max(0, rect.h - stripH) };
    }

    function squarify(items, rect, out) {
        var row = [];
        var rest = items;
        var box = rect;
        while (rest.length > 0) {
            var side = Math.min(box.w, box.h);
            var next = rest[0];
            if (
                row.length === 0 ||
                worstRatio(row, side) >= worstRatio(row.concat([next]), side)
            ) {
                row.push(next);
                rest = rest.slice(1);
            } else {
                box = placeRow(row, box, out);
                row = [];
            }
        }
        if (row.length > 0) {
            placeRow(row, box, out);
        }
    }

    function partition(items, rect, out, vertical) {
        var total = 0;
        for (var i = 0; i < items.length; i++) {
            total += items[i].area;
        }
        var x = rect.x;
        var y = rect.y;
        for (var j = 0; j < items.length; j++) {
            if (vertical) {
                var h = (rect.h * items[j].area) / total;
                out.push({ node: items[j].node, x: rect.x, y: y, w: rect.w, h: h });
                y += h;
            } else {
                var w = (rect.w * items[j].area) / total;
                out.push({ node: items[j].node, x: x, y: rect.y, w: w, h: rect.h });
                x += w;
            }
        }
    }

    // Lay out constrained nodes into `width` x `height`; returns rects that
    // exactly tile the panel (values are scaled so sum(area) == w*h).
    function layoutTreemap(nodes, width, height, tiling) {
        var w = Number(width);
        var h = Number(height);
        if (!(w > 0) || !(h > 0) || !nodes || nodes.length === 0) {
            return [];
        }
        var total = 0;
        for (var i = 0; i < nodes.length; i++) {
            total += Number(nodes[i].layoutValue) || 0;
        }
        if (!(total > 0)) {
            return [];
        }
        var scale = (w * h) / total;
        var items = nodes.map(function (node) {
            return { node: node, area: (Number(node.layoutValue) || 0) * scale };
        });
        items.sort(function (a, b) {
            return b.area - a.area;
        });

        var out = [];
        var rect = { x: 0, y: 0, w: w, h: h };
        if (tiling === "slice") {
            partition(items, rect, out, true);
        } else if (tiling === "dice") {
            partition(items, rect, out, false);
        } else {
            squarify(items, rect, out);
        }
        return out;
    }

    return {
        computeLayoutValues: computeLayoutValues,
        capValues: capValues,
        aggregateSmall: aggregateSmall,
        sizeScales: sizeScales,
        fontSizes: fontSizes,
        lineFit: lineFit,
        layoutTreemap: layoutTreemap
    };
});

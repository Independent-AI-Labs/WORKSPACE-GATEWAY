import test from "node:test";
import assert from "node:assert/strict";
import constraints from "../src/constraints.js";

const { computeLayoutValues, capValues, aggregateSmall, sizeScales, fontSizes, lineFit, layoutTreemap } = constraints;

function leaves(values) {
  return values.map((value, i) => ({ key: "k" + i, label: "k" + i, value: value }));
}

const LAYOUT_TOTAL = (items) => items.reduce((s, it) => s + it.layoutValue, 0);

test("empty or unusable input yields no tiles", () => {
  assert.deepEqual(computeLayoutValues([], 100, 100, {}), []);
  assert.deepEqual(computeLayoutValues(leaves([1, 2]), 0, 100, {}), []);
  assert.deepEqual(computeLayoutValues(leaves([0, -1, NaN]), 100, 100, {}), []);
});

test("without constraints every value is kept verbatim", () => {
  const out = computeLayoutValues(leaves([5, 3, 2]), 100, 100, {});
  assert.equal(out.length, 3);
  assert.deepEqual(
    out.map((it) => it.layoutValue),
    [5, 3, 2]
  );
});

test("minTileArea merges the smallest leaves into one overflow tile", () => {
  // panel 100x100 = 10000 px2, min 150 px2 -> minValue = 150 * 107 / 10000 = 1.6
  const out = computeLayoutValues(leaves([100, 5, 1, 1]), 100, 100, { minArea: 150 });
  const other = out.find((it) => it.isOther);
  assert.ok(other, "expected an overflow tile");
  assert.equal(other.count, 2);
  assert.equal(other.value, 2);
  assert.equal(other.label, "Other");
  // Every drawn tile clears the floor (overflow included).
  const minValue = (150 * LAYOUT_TOTAL(out)) / 10000;
  for (const node of out) {
    assert.ok(node.layoutValue >= minValue - 1e-9, `${node.key} below floor`);
  }
});

test("minTileArea uses the configured overflow label", () => {
  const out = computeLayoutValues(leaves([100, 3, 3]), 100, 100, { minArea: 470, otherLabel: "small models" });
  const other = out.find((it) => it.isOther);
  assert.ok(other, "expected an overflow tile");
  assert.equal(other.label, "small models");
});

test("a lone tiny leaf with big siblings is dropped when the overflow is still too small", () => {
  // layoutTotal 201, panelArea 10000, min 1000 -> minValue 20.1; tiny=1 -> drop
  const out = computeLayoutValues(leaves([100, 100, 1]), 100, 100, { minArea: 1000 });
  assert.equal(out.length, 2);
  assert.equal(out.some((it) => it.isOther), false);
});

test("when every leaf is below the floor a single overflow tile is returned", () => {
  const many = leaves(new Array(100).fill(1));
  const out = computeLayoutValues(many, 100, 10, { minArea: 100, otherLabel: "rest" });
  assert.equal(out.length, 1);
  assert.equal(out[0].isOther, true);
  assert.equal(out[0].count, 100);
  assert.equal(out[0].value, 100);
});

test("maxTileArea caps the dominant tile and never exceeds the cap fraction", () => {
  const values = [1000, 100, 100, 100, 100, 100, 100, 100, 100, 100];
  const items = leaves(values);
  const out = capValues(items, 10000, 2000);
  const total = LAYOUT_TOTAL(out);
  const limit = (2000 / 10000) * total;
  for (const node of out) {
    assert.ok(node.layoutValue <= limit + 1e-9, `${node.key} above cap`);
  }
  assert.ok(out[0].layoutValue < 1000, "dominant tile should be capped");
  assert.equal(out[0].layoutValue, 225, "water-filling cap level");
  // The small tiles are untouched.
  assert.equal(out[1].layoutValue, 100);
  assert.equal(out[1].value, 100, "raw value preserved for display");
});

test("maxTileArea falls back to capping at the mean when the cap is infeasible", () => {
  // 3 tiles cannot each stay under 25% of the panel and still fill it, so the
  // dominant tile is capped at the mean instead.
  const out = capValues(leaves([1000, 100, 100]), 10000, 2500);
  assert.deepEqual(
    out.map((it) => it.layoutValue),
    [400, 100, 100]
  );
});

test("maxTileArea does not bite when no tile reaches the fraction", () => {
  // The largest tile is 40% of the panel, below the 50% cap, so every value is
  // left untouched instead of being flattened to the mean.
  const out = capValues(leaves([400, 300, 300]), 10000, 5000);
  assert.deepEqual(
    out.map((it) => it.layoutValue),
    [400, 300, 300]
  );
});

test("maxTileArea at or above the panel area is a no-op", () => {
  const out = computeLayoutValues(leaves([10, 5]), 100, 100, { maxArea: 0 });
  assert.deepEqual(
    out.map((it) => it.layoutValue),
    [10, 5]
  );
  const out2 = computeLayoutValues(leaves([10, 5]), 100, 100, { maxArea: 10000 });
  assert.deepEqual(
    out2.map((it) => it.layoutValue),
    [10, 5]
  );
});

test("aggregateSmall is a no-op when no floor is set", () => {
  const items = leaves([1, 2]).map((it) => ({ ...it, layoutValue: it.value }));
  assert.equal(aggregateSmall(items, 100, 0, "Other").length, 2);
});

test("layoutTreemap tiles the panel exactly", () => {
  const nodes = computeLayoutValues(leaves([50, 25, 15, 10]), 400, 300, {});
  const rects = layoutTreemap(nodes, 400, 300, "squarify");
  assert.equal(rects.length, 4);
  let area = 0;
  for (const r of rects) {
    area += r.w * r.h;
    assert.ok(r.x >= -1e-9 && r.y >= -1e-9, "inside bounds");
    assert.ok(r.x + r.w <= 400 + 1e-6, "within width");
    assert.ok(r.y + r.h <= 300 + 1e-6, "within height");
  }
  assert.ok(Math.abs(area - 400 * 300) < 1e-3, "area conserved");
});

test("layoutTreemap returns nothing for unusable geometry", () => {
  assert.deepEqual(layoutTreemap(leaves([1, 2]), 0, 100, "squarify"), []);
  assert.deepEqual(layoutTreemap([], 100, 100, "squarify"), []);
});

test("slice and dice partition without overlapping", () => {
  const nodes = computeLayoutValues(leaves([3, 1]), 200, 100, {});
  const slice = layoutTreemap(nodes, 200, 100, "slice");
  assert.equal(slice.length, 2);
  assert.ok(Math.abs(slice[0].w - 200) < 1e-6, "slice spans full width");
  assert.ok(Math.abs(slice[0].h - 75) < 1e-6, "slice height by value");
  const dice = layoutTreemap(nodes, 200, 100, "dice");
  assert.ok(Math.abs(dice[0].h - 100) < 1e-6, "dice spans full height");
  assert.ok(Math.abs(dice[0].w - 150) < 1e-6, "dice width by value");
});

test("auto font sizes spread across the range without saturating", () => {
  const rects = [
    { w: 300, h: 250 },
    { w: 220, h: 180 },
    { w: 120, h: 110 },
    { w: 80, h: 70 },
    { w: 44, h: 40 },
  ];
  const sizes = fontSizes(rects, { autoFontSize: true, minFontSize: 8, maxFontSize: 22 }, 2);
  assert.equal(sizes[0], 22, "largest tile reaches the maximum");
  assert.equal(sizes[sizes.length - 1], 8, "smallest tile hits the minimum");
  for (let i = 1; i < sizes.length; i++) {
    assert.ok(sizes[i] <= sizes[i - 1] + 1e-9, "sizes are monotonic with tile size");
  }
  // A mid-size tile must not already be pinned at the maximum.
  assert.ok(sizes[1] < 22 - 1e-9, "second tile is not saturated at the max");
  assert.ok(sizes[2] > 8 + 1e-9, "middle tile is not collapsed to the min");
});

test("font size never outgrows a very small tile", () => {
  const rects = [{ w: 400, h: 300 }, { w: 20, h: 18 }];
  const sizes = fontSizes(rects, { autoFontSize: true, minFontSize: 8, maxFontSize: 22 }, 2);
  assert.ok(sizes[1] <= Math.max(8, (18 - 2) * 0.42) + 1e-9, "tiny tile font fits");
});

test("fixed font size is returned unchanged when auto sizing is off", () => {
  const rects = [{ w: 300, h: 300 }, { w: 40, h: 40 }];
  const sizes = fontSizes(rects, { autoFontSize: false, fontSize: 14, minFontSize: 8, maxFontSize: 22 }, 2);
  assert.deepEqual(sizes, [14, 14]);
});

test("lineFit drops the percent line first, then the name", () => {
  const heights = { percent: 30, name: 20, value: 18 };
  const wide = 200;
  // Not enough height for all three -> no percent, but name+value fit.
  assert.deepEqual(lineFit(wide, 40, heights, 80), { percent: false, name: true });
  // Not enough height for name+value -> only the value survives.
  assert.deepEqual(lineFit(wide, 20, heights, 80), { percent: false, name: false });
  // Height is fine but the name is wider than the tile -> name hidden.
  assert.deepEqual(lineFit(50, 100, heights, 80), { percent: true, name: false });
  // Everything fits.
  assert.deepEqual(lineFit(wide, 100, heights, 80), { percent: true, name: true });
});

test("lineFit reserves the scaled gap between percent and name", () => {
  const heights = { percent: 30, name: 20, value: 18 };
  // 30+20+18 = 68 fits in 70 with no gap, not with a 6px gap.
  assert.equal(lineFit(200, 70, heights, 80).percent, true);
  assert.equal(lineFit(200, 70, heights, 80, 6).percent, false);
});

test("font size follows a cube-root-of-area scale", () => {
  // Areas 1e4, 4e4, 16e4 (each 4x the previous). A cube-root scale gives
  // linear spacing in cbrt(area), so the 4x tiles do not collapse together.
  const rects = [
    { w: 100, h: 100 },
    { w: 200, h: 200 },
    { w: 400, h: 400 },
  ];
  const sizes = fontSizes(rects, { autoFontSize: true, minFontSize: 8, maxFontSize: 22 }, 0);
  const lo = Math.cbrt(1e4);
  const hi = Math.cbrt(16e4);
  const expected = [1e4, 4e4, 16e4].map((a) => 8 + 14 * ((Math.cbrt(a) - lo) / (hi - lo)));
  sizes.forEach((s, i) => assert.ok(Math.abs(s - expected[i]) < 1e-6, `tile ${i}`));

  const scales = sizeScales(rects, 0);
  assert.deepEqual(scales, [0, (Math.cbrt(4e4) - lo) / (hi - lo), 1]);
  // The two largest tiles stay clearly apart, not "almost the same".
  assert.ok(sizes[2] - sizes[1] > 3, "4x area tiles differ by more than 3px");
});

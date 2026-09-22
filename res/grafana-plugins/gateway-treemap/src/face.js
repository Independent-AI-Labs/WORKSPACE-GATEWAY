/*
 * gateway-treemap - tile face helpers (pure, no React, no DOM).
 *
 * Text/number/colour helpers shared by the panel: value formatting via a
 * Grafana display processor, the colour ramp, the mustache tooltip renderer
 * and the tile padding/context builders. Kept dependency-free so the AMD
 * panel module can call them and `node --test` can exercise them directly.
 */
(function (root, factory) {
    var api = factory();
    if (typeof module === "object" && module && module.exports) {
        module.exports = api;
    }
    if (root) {
        root.GwTreemapFace = api;
    }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
    "use strict";

    function numberOr(value, defaultValue) {
        var n = Number(value);
        return isFinite(n) ? n : defaultValue;
    }

    function clampNumber(value, min, max) {
        if (value < min) {
            return min;
        }
        if (value > max) {
            return max;
        }
        return value;
    }

    function findField(frame, name) {
        for (var i = 0; i < frame.fields.length; i++) {
            if (frame.fields[i].name === name) {
                return frame.fields[i];
            }
        }
        return null;
    }

    function firstNumberField(frame) {
        for (var i = frame.fields.length - 1; i >= 0; i--) {
            if (frame.fields[i].type === "number") {
                return frame.fields[i];
            }
        }
        return frame.fields.length ? frame.fields[frame.fields.length - 1] : null;
    }

    // Grafana normally attaches `field.display`, but if it is missing (or is
    // not callable in this Grafana version) use the framework's own
    // display-processor factory so units/decimals are still honoured.
    function resolveProcessor(field, theme, data) {
        if (field && typeof field.display === "function") {
            return field.display;
        }
        if (field && data && typeof data.getDisplayProcessor === "function") {
            try {
                var processor = data.getDisplayProcessor({ field: field, theme: theme });
                if (typeof processor === "function") {
                    return processor;
                }
            } catch (e) {
                console.warn("gateway-treemap: display processor factory failed", e);
            }
        }
        return null;
    }

    function formatValue(processor, value) {
        if (processor) {
            try {
                var dv = processor(value);
                if (dv && dv.text != null) {
                    return (dv.prefix || "") + dv.text + (dv.suffix || "");
                }
            } catch (e) {
                /* fall through to the raw value */
            }
        }
        return value == null ? "" : String(value);
    }

    function colorFor(processor, value) {
        if (processor) {
            try {
                var dv = processor(value);
                if (dv && dv.color) {
                    return dv.color;
                }
            } catch (e) {
                /* no display color */
            }
        }
        return null;
    }

    function parseHex(hex) {
        var match = /^#?([0-9a-f]{6})$/i.exec(String(hex == null ? "" : hex));
        if (!match) {
            return null;
        }
        var n = parseInt(match[1], 16);
        return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
    }

    // Readable foreground for a tile colour.
    function textColorFor(hex) {
        var c = parseHex(hex);
        if (!c) {
            return "#ffffff";
        }
        var luminance = (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) / 255;
        return luminance > 0.6 ? "#110b11" : "#ffffff";
    }

    function toHex(channel) {
        var n = Math.round(clampNumber(channel, 0, 255));
        return (n < 16 ? "0" : "") + n.toString(16);
    }

    // Blend two #rrggbb colours; t=0 -> from, t=1 -> to.
    function mixHex(from, to, t) {
        var a = parseHex(from);
        var b = parseHex(to);
        if (!a || !b) {
            return t >= 0.5 ? to : from;
        }
        var k = clampNumber(t, 0, 1);
        return (
            "#" +
            toHex(a.r + (b.r - a.r) * k) +
            toHex(a.g + (b.g - a.g) * k) +
            toHex(a.b + (b.b - a.b) * k)
        );
    }

    function escapeHtml(value) {
        return String(value).replace(/[&<>"']/g, function (ch) {
            switch (ch) {
                case "&":
                    return "&amp;";
                case "<":
                    return "&lt;";
                case ">":
                    return "&gt;";
                case '"':
                    return "&quot;";
                default:
                    return "&#39;";
            }
        });
    }

    // Minimal mustache: {{ key }} / {{ fields.cost }} / {{ raw.tokens }}.
    // Only the substituted values are escaped; the template markup is trusted
    // (it is authored by a dashboard administrator).
    function renderTemplate(template, context) {
        return String(template == null ? "" : template).replace(
            /\{\{\s*([\w.]+)\s*\}\}/g,
            function (_, key) {
                var parts = key.split(".");
                var value = context;
                for (var i = 0; i < parts.length && value != null; i++) {
                    value = value[parts[i]];
                }
                return escapeHtml(value == null ? "" : value);
            }
        );
    }

    function buildModel(panelData, options, theme, data) {
        var frames = (panelData && panelData.series) || [];
        var labelName = options.textField || "model";
        var sizeName = options.sizeField || "tokens";
        var colorName = options.colorField || "";
        var leaves = [];
        var sizeProcessor = null;

        for (var fi = 0; fi < frames.length; fi++) {
            var frame = frames[fi];
            var size = findField(frame, sizeName) || firstNumberField(frame);
            if (!size) {
                continue;
            }
            var sizeFormat = resolveProcessor(size, theme, data);
            if (!sizeProcessor) {
                sizeProcessor = sizeFormat;
            }
            var labelField = findField(frame, labelName);
            var labelFormat = resolveProcessor(labelField, theme, data);
            var colorField = colorName ? findField(frame, colorName) : null;
            var colorFormat = resolveProcessor(colorField, theme, data);
            var fields = frame.fields;
            var processors = [];
            for (var pi = 0; pi < fields.length; pi++) {
                processors.push(resolveProcessor(fields[pi], theme, data));
            }

            for (var ri = 0; ri < frame.length; ri++) {
                var rawSize = size.values[ri];
                var numeric = Number(rawSize);
                if (!isFinite(numeric) || numeric <= 0) {
                    continue;
                }
                var raw = {};
                var text = {};
                for (var ci = 0; ci < fields.length; ci++) {
                    var column = fields[ci];
                    raw[column.name] = column.values[ri];
                    text[column.name] = formatValue(processors[ci], column.values[ri]);
                }
                leaves.push({
                    key: (frame.refId || "A") + ":" + ri,
                    label: labelField
                        ? formatValue(labelFormat, labelField.values[ri])
                        : String(text[sizeName] == null ? "" : text[sizeName]),
                    value: numeric,
                    valueText: formatValue(sizeFormat, rawSize),
                    raw: raw,
                    fields: text,
                    color: colorField ? colorFor(colorFormat, colorField.values[ri]) : null
                });
            }
        }
        return { leaves: leaves, sizeProcessor: sizeProcessor };
    }

    function totalRawValue(nodes) {
        var total = 0;
        for (var i = 0; i < nodes.length; i++) {
            total += nodes[i].value;
        }
        return total;
    }

    function buildContext(node, innerW, innerH, fontSize, fill, total) {
        var percent = total > 0 ? (node.value / total) * 100 : 0;
        return {
            label: node.label == null ? "" : node.label,
            value: node.valueText != null ? node.valueText : String(node.value),
            valueRaw: node.value,
            percent: percent.toFixed(1),
            area: Math.round(innerW * innerH),
            width: Math.round(innerW),
            height: Math.round(innerH),
            color: fill,
            fontSize: Math.round(fontSize),
            isOther: !!node.isOther,
            count: node.count || 1,
            fields: node.fields || {},
            raw: node.raw || {}
        };
    }

    function tilePaddingBox(innerW, innerH) {
        var shortest = Math.min(innerW, innerH);
        if (shortest < 26) {
            return { y: 1, x: 1 };
        }
        if (shortest < 44) {
            return { y: 2, x: 3 };
        }
        return { y: 4, x: 6 };
    }

    function tilePadding(innerW, innerH) {
        var box = tilePaddingBox(innerW, innerH);
        return box.y + "px " + box.x + "px";
    }

    return {
        numberOr: numberOr,
        clampNumber: clampNumber,
        findField: findField,
        firstNumberField: firstNumberField,
        resolveProcessor: resolveProcessor,
        formatValue: formatValue,
        colorFor: colorFor,
        parseHex: parseHex,
        textColorFor: textColorFor,
        mixHex: mixHex,
        escapeHtml: escapeHtml,
        renderTemplate: renderTemplate,
        buildModel: buildModel,
        totalRawValue: totalRawValue,
        buildContext: buildContext,
        tilePaddingBox: tilePaddingBox,
        tilePadding: tilePadding
    };
});

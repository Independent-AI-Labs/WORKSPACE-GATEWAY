/*
 * gateway-treemap - panel implementation (hand-written AMD, no bundler).
 *
 * Depends on the constraints/geometry module above (globalThis.
 * GwTreemapConstraints) and the tile-face helpers (globalThis.GwTreemapFace),
 * plus Grafana's own AMD modules.
 */
define(["react", "@grafana/data"], function (React, data) {
    "use strict";

    var PanelPlugin = data.PanelPlugin;

    var DEFAULT_TOOLTIP =
        "<div><strong>{{label}}</strong></div>" +
        "<div>{{value}} &middot; {{percent}}%</div>";
    var DEFAULT_COLOR = "#247ba0";
    // Smallest tiles fade towards this neutral grey; large ones get the full
    // saturation of the tile colour (brand grey -> brand blue).
    var SCALE_MIN_COLOR = "#50514f";

    // Tile face is three stacked lines: percent (biggest, thin), name, value.
    var PERCENT_FONT_SCALE = 1.5;
    var VALUE_FONT_SCALE = 0.9;
    var PERCENT_WEIGHT = 300;
    var NAME_WEIGHT = 600;
    var VALUE_WEIGHT = 400;
    var PERCENT_LINE_HEIGHT = 1.0;
    var NAME_LINE_HEIGHT = 1.15;
    var VALUE_LINE_HEIGHT = 1.05;
    // Scaled spacing between the percent line and the model name.
    var PERCENT_GAP_SCALE = 0.28;

    // ---- modules ----------------------------------------------------------

    function getConstraints() {
        if (typeof globalThis !== "undefined" && globalThis.GwTreemapConstraints) {
            return globalThis.GwTreemapConstraints;
        }
        if (typeof module === "object" && module && module.exports) {
            return module.exports;
        }
        throw new Error("gateway-treemap: constraints module missing");
    }

    function getFace() {
        if (typeof globalThis !== "undefined" && globalThis.GwTreemapFace) {
            return globalThis.GwTreemapFace;
        }
        throw new Error("gateway-treemap: face module missing");
    }

    var face = getFace();
    var numberOr = face.numberOr;
    var clampNumber = face.clampNumber;
    var formatValue = face.formatValue;
    var textColorFor = face.textColorFor;
    var mixHex = face.mixHex;
    var renderTemplate = face.renderTemplate;
    var buildContext = face.buildContext;
    var tilePaddingBox = face.tilePaddingBox;
    var tilePadding = face.tilePadding;

    // ---- data model -------------------------------------------------------

    function applyConstraints(model, options, width, height) {
        var nodes = getConstraints().computeLayoutValues(model.leaves, width, height, {
            minArea: numberOr(options.minTileArea, 0),
            maxArea: numberOr(options.maxTileArea, 0),
            otherLabel: options.otherLabel || "Other"
        });
        for (var i = 0; i < nodes.length; i++) {
            if (nodes[i].isOther) {
                nodes[i].valueText = formatValue(model.sizeProcessor, nodes[i].value);
                nodes[i].raw = {};
                nodes[i].fields = {};
            }
        }
        return nodes;
    }

    // A hidden, absolutely-positioned copy of a tile's three lines used to
    // measure their natural box dimensions after the tile is rendered.
    function probeLine(boxRef, textRef, fontSize, weight, lineHeight, text) {
        return React.createElement(
            "div",
            {
                ref: boxRef,
                style: {
                    display: "block",
                    fontSize: fontSize + "px",
                    fontWeight: weight,
                    lineHeight: lineHeight,
                    whiteSpace: "nowrap"
                }
            },
            React.createElement(
                "span",
                { ref: textRef, style: { display: "inline-block", whiteSpace: "nowrap" } },
                text
            )
        );
    }

    // ---- component --------------------------------------------------------

    function GatewayTreemapPanel(props) {
        var options = props.options || {};
        var theme = props.theme || {};
        var width = Math.max(0, Number(props.width) || 0);
        var height = Math.max(0, Number(props.height) || 0);

        var model = React.useMemo(
            function () {
                return face.buildModel(props.data, options, theme, data);
            },
            [props.data, options, theme]
        );
        var nodes = React.useMemo(
            function () {
                return applyConstraints(model, options, width, height);
            },
            [model, options, width, height]
        );
        var rects = React.useMemo(
            function () {
                return getConstraints().layoutTreemap(nodes, width, height, options.tiling);
            },
            [nodes, width, height, options.tiling]
        );

        var hoverPair = React.useState(null);
        var hover = hoverPair[0];
        var setHover = hoverPair[1];
        var containerRef = React.useRef(null);
        var fitPair = React.useState({});
        var fit = fitPair[0];
        var setFit = fitPair[1];
        var fitRef = React.useRef(fit);
        fitRef.current = fit;
        var probeRefs = React.useRef({});

        // Measure the hidden probe copy of each tile's three lines after the
        // tiles have been laid out, then show/hide lines so the face never
        // overflows. Runs synchronously before paint to avoid a flash.
        React.useLayoutEffect(function () {
            var probeMap = probeRefs.current || {};
            var keys = Object.keys(probeMap);
            if (keys.length === 0) {
                return;
            }
            var next = {};
            var changed = false;
            for (var i = 0; i < keys.length; i++) {
                var entry = probeMap[keys[i]];
                if (!entry || !entry.p || !entry.n || !entry.v) {
                    continue;
                }
                if (!entry.p.box || !entry.n.box || !entry.v.box || !entry.n.text) {
                    continue;
                }
                var pad = entry.pad || { x: 0, y: 0 };
                var flags = getConstraints().lineFit(
                    entry.innerW - pad.x * 2,
                    entry.innerH - pad.y * 2,
                    {
                        percent: entry.p.box.getBoundingClientRect().height,
                        name: entry.n.box.getBoundingClientRect().height,
                        value: entry.v.box.getBoundingClientRect().height
                    },
                    entry.n.text.getBoundingClientRect().width,
                    entry.gap
                );
                var prev = fitRef.current[keys[i]];
                if (!prev || prev.percent !== flags.percent || prev.name !== flags.name) {
                    changed = true;
                }
                next[keys[i]] = flags;
            }
            if (changed) {
                setFit(next);
            }
        });

        var emptyColor = (theme.colors && theme.colors.text && theme.colors.text.secondary) || "#8e8e8e";

        if (width === 0 || height === 0 || rects.length === 0) {
            return React.createElement(
                "div",
                {
                    style: {
                        display: "flex",
                        alignItems: "center",
                        justifyContent: "center",
                        width: "100%",
                        height: "100%",
                        color: emptyColor
                    }
                },
                "No data"
            );
        }

        var gap = clampNumber(numberOr(options.tileGap, 2), 0, 24);
        var defaultColor = options.defaultColor || DEFAULT_COLOR;
        var total = face.totalRawValue(nodes);
        var fontSizes = getConstraints().fontSizes(rects, options, gap);
        var colorScales = getConstraints().sizeScales(rects, gap);
        var probeMap = {};

        var tiles = rects.map(function (rect, index) {
            var node = rect.node;
            var key = node.key || node.label;
            var innerW = Math.max(0, rect.w - gap);
            var innerH = Math.max(0, rect.h - gap);
            var baseFont = fontSizes[index];
            var percentFont = baseFont * PERCENT_FONT_SCALE;
            var nameFont = baseFont;
            var valueFont = baseFont * VALUE_FONT_SCALE;
            var percentGap = baseFont * PERCENT_GAP_SCALE;
            // Larger tiles get the full colour, smaller ones a neutral grey.
            var fill = node.color || mixHex(SCALE_MIN_COLOR, defaultColor, colorScales[index]);
            var context = buildContext(node, innerW, innerH, baseFont, fill, total);
            var flags = fit[key] || { percent: true, name: true };
            var pad = tilePaddingBox(innerW, innerH);

            var entry = (probeMap[key] = { innerW: innerW, innerH: innerH, pad: pad, gap: percentGap });
            function lineRef(part, kind) {
                return function (el) {
                    var slot = entry[part] || (entry[part] = {});
                    slot[kind] = el;
                };
            }
            var probe = React.createElement(
                "div",
                {
                    key: "probe",
                    "aria-hidden": "true",
                    style: {
                        position: "absolute",
                        top: 0,
                        left: 0,
                        width: innerW,
                        padding: pad.y + "px " + pad.x + "px",
                        boxSizing: "border-box",
                        visibility: "hidden",
                        pointerEvents: "none",
                        whiteSpace: "nowrap"
                    }
                },
                probeLine(lineRef("p", "box"), lineRef("p", "text"), percentFont, PERCENT_WEIGHT, PERCENT_LINE_HEIGHT, context.percent + "%"),
                probeLine(lineRef("n", "box"), lineRef("n", "text"), nameFont, NAME_WEIGHT, NAME_LINE_HEIGHT, context.label),
                probeLine(lineRef("v", "box"), lineRef("v", "text"), valueFont, VALUE_WEIGHT, VALUE_LINE_HEIGHT, context.value)
            );

            var lines = [];
            if (flags.percent) {
                lines.push(
                    React.createElement(
                        "div",
                        {
                            key: "percent",
                            style: {
                                fontSize: percentFont + "px",
                                fontWeight: PERCENT_WEIGHT,
                                lineHeight: PERCENT_LINE_HEIGHT,
                                marginBottom: percentGap + "px",
                                opacity: 0.85
                            }
                        },
                        context.percent + "%"
                    )
                );
            }
            if (flags.name) {
                lines.push(
                    React.createElement(
                        "div",
                        {
                            key: "name",
                            style: {
                                fontSize: nameFont + "px",
                                fontWeight: NAME_WEIGHT,
                                lineHeight: NAME_LINE_HEIGHT
                            }
                        },
                        context.label
                    )
                );
            }
            lines.push(
                React.createElement(
                    "div",
                    {
                        key: "value",
                        style: {
                            fontSize: valueFont + "px",
                            fontWeight: VALUE_WEIGHT,
                            lineHeight: VALUE_LINE_HEIGHT,
                            opacity: 0.85
                        }
                    },
                    context.value
                )
            );

            return React.createElement(
                "div",
                {
                    key: key,
                    style: {
                        position: "absolute",
                        left: rect.x + gap / 2,
                        top: rect.y + gap / 2,
                        width: innerW,
                        height: innerH,
                        background: fill,
                        color: textColorFor(fill),
                        borderRadius: 2,
                        padding: tilePadding(innerW, innerH),
                        boxSizing: "border-box",
                        overflow: "hidden",
                        display: "flex",
                        flexDirection: "column",
                        alignItems: "center",
                        justifyContent: "center",
                        textAlign: "center",
                        transition: "opacity 120ms ease"
                    },
                    onMouseMove: function (event) {
                        if (!options.tooltipTemplate) {
                            return;
                        }
                        var box = containerRef.current
                            ? containerRef.current.getBoundingClientRect()
                            : { left: 0, top: 0 };
                        setHover({
                            context: context,
                            x: event.clientX - box.left,
                            y: event.clientY - box.top
                        });
                    },
                    onMouseLeave: function () {
                        setHover(null);
                    }
                },
                probe,
                lines
            );
        });
        probeRefs.current = probeMap;

        var tooltip = null;
        if (hover && options.tooltipTemplate) {
            var tooltipStyle = {
                position: "absolute",
                zIndex: 20,
                pointerEvents: "none",
                maxWidth: 340,
                padding: "6px 8px",
                borderRadius: 4,
                fontSize: 12,
                lineHeight: 1.35,
                whiteSpace: "nowrap",
                color: (theme.colors && theme.colors.text && theme.colors.text.primary) || "#ffffff",
                background: (theme.colors && theme.colors.background && theme.colors.background.secondary) || "#1f1f20",
                border:
                    "1px solid " +
                    ((theme.colors && theme.colors.border && theme.colors.border.weak) || "#333333"),
                boxShadow: "0 2px 8px rgba(0,0,0,0.35)"
            };
            if (hover.x > width / 2) {
                tooltipStyle.right = Math.max(0, width - hover.x + 12);
            } else {
                tooltipStyle.left = Math.max(0, hover.x + 12);
            }
            if (hover.y > height / 2) {
                tooltipStyle.bottom = Math.max(0, height - hover.y + 12);
            } else {
                tooltipStyle.top = Math.max(0, hover.y + 12);
            }
            tooltip = React.createElement("div", {
                style: tooltipStyle,
                dangerouslySetInnerHTML: { __html: renderTemplate(options.tooltipTemplate, hover.context) }
            });
        }

        return React.createElement(
            "div",
            {
                ref: containerRef,
                style: { position: "relative", width: "100%", height: "100%", overflow: "hidden" }
            },
            tiles,
            tooltip
        );
    }

    // ---- plugin registration ---------------------------------------------

    // Grafana only applies the dashboard's field config (unit, decimals,
    // color, ...) to panel data when the plugin registers a field config
    // registry, so opt in to the standard options.
    var plugin = new PanelPlugin(GatewayTreemapPanel);
    if (typeof plugin.useFieldConfig === "function") {
        plugin.useFieldConfig();
    }
    plugin = plugin.setPanelOptions(function (builder) {
        builder
            .addSelect({
                path: "tiling",
                name: "Tiling",
                defaultValue: "squarify",
                settings: {
                    options: [
                        { value: "squarify", label: "Squarified" },
                        { value: "slice", label: "Slice (horizontal)" },
                        { value: "dice", label: "Dice (vertical)" }
                    ]
                }
            })
            .addFieldNamePicker({ path: "textField", name: "Label field", defaultValue: "model" })
            .addFieldNamePicker({ path: "sizeField", name: "Size field", defaultValue: "tokens" })
            .addFieldNamePicker({
                path: "colorField",
                name: "Color field (optional)",
                defaultValue: ""
            })
            .addColorPicker({ path: "defaultColor", name: "Default tile color", defaultValue: DEFAULT_COLOR })
            .addNumberInput({
                path: "minTileArea",
                name: "Minimum tile area (px\u00b2)",
                description: "Tiles smaller than this are merged into one overflow tile. 0 disables.",
                defaultValue: 0
            })
            .addNumberInput({
                path: "maxTileArea",
                name: "Maximum tile area (px\u00b2)",
                description: "Tiles larger than this are capped and the freed area redistributed. 0 disables.",
                defaultValue: 0
            })
            .addTextInput({ path: "otherLabel", name: "Overflow tile label", defaultValue: "Other" })
            .addNumberInput({ path: "tileGap", name: "Tile gap (px)", defaultValue: 2 })
            .addBooleanSwitch({ path: "autoFontSize", name: "Auto font size", defaultValue: true })
            .addNumberInput({ path: "minFontSize", name: "Minimum font size (px)", defaultValue: 8 })
            .addNumberInput({ path: "maxFontSize", name: "Maximum font size (px)", defaultValue: 28 })
            .addNumberInput({
                path: "fontSize",
                name: "Fixed font size (px)",
                description: "Used when auto font size is off.",
                defaultValue: 12
            })
            .addTextInput({ path: "tooltipTemplate", name: "Tooltip template", defaultValue: DEFAULT_TOOLTIP });
    });

    return { plugin: plugin };
});

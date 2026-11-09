import Foundation

/// Indices into the per-frame parameter array shared by Swift and the shader.
enum ShaderParam {
    static let width = 0, height = 1, scale = 2, style = 3, regionCount = 4
    /// Each region is 5 floats: x0, x1, channel (0 mid, 1 left, 2 right), mirrored, band count.
    static let region0 = 5
    static let showPeaks = 15, axis = 16, stopCount = 17, capHeight = 18
    static let ledRows = 19, ledSegment = 20, ledPitch = 21, ledOffset = 22
    static let vuSegment = 23, vuSpacing = 24
    static let meterLeft = 25, meterRight = 26, meterPeakLeft = 27, meterPeakRight = 28
    static let pulseLeft = 29   // r, g, b, a
    static let pulseRight = 33  // r, g, b, a
    static let blendLow = 37, blendHigh = 38, stereo = 39
    /// The notch (or a sliver at the center) without padding, and its corner radius.
    static let gapLow = 40, gapHigh = 41, notchRadius = 42
    static let particleCount = 43
    static let scopeAlpha = 44, scopePoints = 45
    static let historyIndex = 46, historyLength = 47, waterfallColumn = 48
    /// 0 = menu bar strip; 1 left, 2 right, 3 bottom, 4 top screen-edge glow.
    static let edgeMode = 49, edgeThickness = 50, edgeBands = 51
    static let brightness = 52
    /// 1 when colors follow the screen (Ambient light), then this window's span on its screen
    /// as fractions of the screen: x0, x1, y0 (bottom), y1 (top).
    static let ambient = 53, ambientRect = 54
    /// Edge glow: how long each side's run of bands is, in points: the side window plus the top window's corner,
    /// so the bands carry on through the top corners. 0 means just the window's own height.
    static let edgeRun = 58
    /// Keep menu bar text readable: 0 off, 1 the menu bar's text is light, 2 it's dark.
    static let textGuard = 59
    /// Bar styles: columns per band (1 or more). Screens wider than 16:9 get extra columns in between the bands,
    /// so bars keep a normal width instead of stretching.
    static let barColumns = 60
    /// Voice: its color (r, g, b), how far it spreads out from the middle of the screen (0...1, 1 = everywhere),
    /// and the menu bar glow's strength (0...1). Uses `ambientRect` for where this window sits on its screen.
    static let voiceColor = 61, voiceTint = 64, voiceGlow = 65
    static let count = 66

    /// Band buffer: levels for mid/left/right, then peaks for mid/left/right.
    static let maxBands = 128
    static let bandBufferCount = maxBands * 6

    /// Ambient light buffer: the screen's colors along the top, bottom, left and right edges
    /// (rgb), and how strongly a light beam lights each spot (a).
    static let ambientCount = ScreenColors.columns * 2 + ScreenColors.rows * 2
}

extension EQStyle {
    var shaderIndex: Int {
        switch self {
        case .led: return 0
        case .bars: return 1
        case .center: return 2
        case .glow: return 3
        case .pulse: return 4
        case .vu: return 5
        case .aura: return 6
        case .waterfall: return 7
        case .scope: return 8
        case .sparks: return 9
        }
    }
}

/// Metal source for every style. Compiled at launch, so the app builds with just the Command Line Tools.
/// Each pixel works out which bar/segment it belongs to and colors itself; output is premultiplied alpha.
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant int P_WIDTH = \(ShaderParam.width);
    constant int P_HEIGHT = \(ShaderParam.height);
    constant int P_SCALE = \(ShaderParam.scale);
    constant int P_STYLE = \(ShaderParam.style);
    constant int P_REGION_COUNT = \(ShaderParam.regionCount);
    constant int P_REGION0 = \(ShaderParam.region0);
    constant int P_SHOW_PEAKS = \(ShaderParam.showPeaks);
    constant int P_AXIS = \(ShaderParam.axis);
    constant int P_STOP_COUNT = \(ShaderParam.stopCount);
    constant int P_CAP = \(ShaderParam.capHeight);
    constant int P_LED_ROWS = \(ShaderParam.ledRows);
    constant int P_LED_SEGMENT = \(ShaderParam.ledSegment);
    constant int P_LED_PITCH = \(ShaderParam.ledPitch);
    constant int P_LED_OFFSET = \(ShaderParam.ledOffset);
    constant int P_VU_SEGMENT = \(ShaderParam.vuSegment);
    constant int P_VU_SPACING = \(ShaderParam.vuSpacing);
    constant int P_METER_L = \(ShaderParam.meterLeft);
    constant int P_METER_R = \(ShaderParam.meterRight);
    constant int P_METER_PEAK_L = \(ShaderParam.meterPeakLeft);
    constant int P_METER_PEAK_R = \(ShaderParam.meterPeakRight);
    constant int P_PULSE_L = \(ShaderParam.pulseLeft);
    constant int P_PULSE_R = \(ShaderParam.pulseRight);
    constant int P_BLEND_LO = \(ShaderParam.blendLow);
    constant int P_BLEND_HI = \(ShaderParam.blendHigh);
    constant int P_STEREO = \(ShaderParam.stereo);
    constant int P_GAP_LO = \(ShaderParam.gapLow);
    constant int P_GAP_HI = \(ShaderParam.gapHigh);
    constant int P_NOTCH_RADIUS = \(ShaderParam.notchRadius);
    constant int P_PARTICLES = \(ShaderParam.particleCount);
    constant int P_SCOPE_ALPHA = \(ShaderParam.scopeAlpha);
    constant int P_SCOPE_POINTS = \(ShaderParam.scopePoints);
    constant int P_HIST_INDEX = \(ShaderParam.historyIndex);
    constant int P_HIST_LEN = \(ShaderParam.historyLength);
    constant int P_WF_COLUMN = \(ShaderParam.waterfallColumn);
    constant int P_EDGE_MODE = \(ShaderParam.edgeMode);
    constant int P_EDGE_THICKNESS = \(ShaderParam.edgeThickness);
    constant int P_EDGE_BANDS = \(ShaderParam.edgeBands);
    constant int P_BRIGHTNESS = \(ShaderParam.brightness);
    constant int P_AMBIENT = \(ShaderParam.ambient);
    constant int P_AMBIENT_RECT = \(ShaderParam.ambientRect);
    constant int P_EDGE_RUN = \(ShaderParam.edgeRun);
    constant int P_TEXT_GUARD = \(ShaderParam.textGuard);
    constant int P_BAR_COLUMNS = \(ShaderParam.barColumns);
    constant int P_VOICE_COLOR = \(ShaderParam.voiceColor);
    constant int P_VOICE_TINT = \(ShaderParam.voiceTint);
    constant int P_VOICE_GLOW = \(ShaderParam.voiceGlow);
    constant int MAX_BANDS = \(ShaderParam.maxBands);
    constant int AMBIENT_COLUMNS = \(ScreenColors.columns);
    constant int AMBIENT_ROWS = \(ScreenColors.rows);

    constant int STYLE_LED = \(EQStyle.led.shaderIndex);
    constant int STYLE_BARS = \(EQStyle.bars.shaderIndex);
    constant int STYLE_CENTER = \(EQStyle.center.shaderIndex);
    constant int STYLE_GLOW = \(EQStyle.glow.shaderIndex);
    constant int STYLE_PULSE = \(EQStyle.pulse.shaderIndex);
    constant int STYLE_VU = \(EQStyle.vu.shaderIndex);
    constant int STYLE_AURA = \(EQStyle.aura.shaderIndex);
    constant int STYLE_WATERFALL = \(EQStyle.waterfall.shaderIndex);
    constant int STYLE_SCOPE = \(EQStyle.scope.shaderIndex);
    constant int STYLE_SPARKS = \(EQStyle.sparks.shaderIndex);

    struct VOut { float4 position [[position]]; };

    // One triangle that covers the whole strip.
    vertex VOut eq_vertex(uint vid [[vertex_id]]) {
        float2 uv = float2(float((vid << 1) & 2), float(vid & 2));
        VOut out;
        out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    static float snapTo(float v, float scale) { return round(v * scale) / scale; }

    static float3 paletteColor(float t, constant float4 *stops, int count) {
        t = clamp(t, 0.0, 1.0);
        float3 prev = stops[0].rgb;
        float prevPos = stops[0].a;
        for (int i = 1; i < count; i++) {
            float4 s = stops[i];
            if (t <= s.a) {
                float span = s.a - prevPos;
                return mix(prev, s.rgb, span > 0.0 ? (t - prevPos) / span : 0.0);
            }
            prev = s.rgb;
            prevPos = s.a;
        }
        return prev;
    }

    // The colors one pixel draws with: the palette, or (Ambient light) the screen's color next to it,
    // and how strongly a light beam from the screen lights this spot.
    struct Colors {
        constant float4 *stops;
        int count;
        bool ambient;
        float3 here;
        float beam;
    };

    static float3 pal(thread const Colors &c, float t) {
        return c.ambient ? c.here : paletteColor(t, c.stops, c.count);
    }

    // Ambient light: the screen's color at u (0...1) along one edge: 0 top, 1 bottom, 2 left, 3 right.
    // Alpha is how strongly a light beam lights that spot.
    static float4 ambientAt(constant float4 *A, int side, float u) {
        int offset = side < 2 ? side * AMBIENT_COLUMNS : 2 * AMBIENT_COLUMNS + (side - 2) * AMBIENT_ROWS;
        int count = side < 2 ? AMBIENT_COLUMNS : AMBIENT_ROWS;
        float f = clamp(u, 0.0, 1.0) * float(count - 1);
        int i0 = int(floor(f));
        int i1 = min(i0 + 1, count - 1);
        return mix(A[offset + i0], A[offset + i1], f - float(i0));
    }

    static float3 capColor(thread const Colors &c, bool vertical, float hue, float height) {
        return vertical ? mix(pal(c, height), float3(1.0), 0.3)
                        : mix(pal(c, hue), float3(1.0), 0.4);
    }

    struct Region { float x0; float x1; int channel; bool mirrored; int count; };

    static bool regionAt(float x, constant float *P, thread Region &r) {
        int n = int(P[P_REGION_COUNT]);
        for (int i = 0; i < n; i++) {
            int b = P_REGION0 + i * 5;
            if (x >= P[b] && x < P[b + 1]) {
                r.x0 = P[b];
                r.x1 = P[b + 1];
                r.channel = int(P[b + 2]);
                r.mirrored = P[b + 3] > 0.5;
                r.count = max(1, int(P[b + 4]));
                return true;
            }
        }
        return false;
    }

    static float levelOf(constant float *B, int channel, int band) { return B[channel * MAX_BANDS + band]; }

    // A level between bands (pos 0...count-1, row 0-2 levels, 3-5 peaks): a smooth curve through the neighbouring
    // bands that never goes above or below the two it sits between, so in-between bars add no fake peaks.
    static float bandCurve(constant float *B, int row, int count, float pos) {
        int i1 = clamp(int(floor(pos)), 0, count - 1);
        float t = clamp(pos - float(i1), 0.0, 1.0);
        int i2 = min(i1 + 1, count - 1);
        constant float *b = B + row * MAX_BANDS;
        float p0 = b[max(i1 - 1, 0)], p1 = b[i1], p2 = b[i2], p3 = b[min(i1 + 2, count - 1)];
        float v = 0.5 * (2.0 * p1 + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t
                         + (3.0 * (p1 - p2) + p3 - p0) * t * t * t);
        return clamp(v, min(p1, p2), max(p1, p2));
    }

    // Level at position u (0...1) along a channel's bands, interpolated.
    static float bandLevelAt(constant float *B, int channel, int count, float u) {
        float f = clamp(u, 0.0, 1.0) * float(max(count - 1, 0));
        int b0 = int(floor(f));
        int b1 = min(b0 + 1, max(count - 1, 0));
        return mix(levelOf(B, channel, b0), levelOf(B, channel, b1), f - float(b0));
    }

    // Distance outside the notch: a box from the bottom of the strip upward, bottom corners rounded.
    static float notchDistance(float2 p, float lo, float hi, float H, float radius) {
        float2 center = float2((lo + hi) * 0.5, H);
        float2 halfSize = float2(max(0.5, (hi - lo) * 0.5), H);
        float r = min(radius, halfSize.x);
        float2 q = abs(p - center) - halfSize + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    static float segmentDistance(float2 p, float2 a, float2 b) {
        float2 ab = b - a;
        float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-4), 0.0, 1.0);
        return length(p - (a + ab * t));
    }

    static float scopeAt(constant float *wave, int count, float u) {
        float pos = clamp(u, 0.0, 1.0) * float(count - 1);
        int i0 = int(floor(pos));
        int i1 = min(i0 + 1, count - 1);
        return mix(wave[i0], wave[i1], pos - float(i0));
    }

    // One screen edge's glow (premultiplied): `e` points in from the edge, `u` the spot along its bands.
    static float4 edgeGlowAt(constant float *P, constant float *B, thread const Colors &C,
                             bool vertical, int channel, float u, float e, float thickness, float pulse) {
        float level = bandLevelAt(B, channel, int(P[P_EDGE_BANDS]), u);
        float falloff = pow(clamp(1.0 - e / thickness, 0.0, 1.0), 2.2);
        float a = clamp((0.8 * pow(level, 1.2) + 0.35 * pulse) * falloff, 0.0, 1.0);
        // A light beam spills out of the screen here, whatever the music is doing, and reaches further in.
        if (C.beam > 0.001) {
            float spill = C.beam * pow(clamp(1.0 - e / thickness, 0.0, 1.0), 1.4);
            a = 1.0 - (1.0 - a) * (1.0 - spill);
        }
        float3 col = vertical ? pal(C, 0.3 + 0.7 * level) : pal(C, u);
        return float4(col * a, a);
    }

    // Two overlapping glows: as bright as the stronger one (so corners don't double up), colors blended.
    static float4 combineGlows(float4 a, float4 b) {
        float alpha = max(a.a, b.a);
        float total = a.a + b.a;
        if (total < 1e-5) return float4(0.0);
        return float4((a.rgb + b.rgb) / total * alpha, alpha);
    }

    // Ambient light: find where this pixel is on the screen and take the screen's color next to it.
    static Colors colorsAt(VOut in, constant float *P, constant float4 *stops, constant float4 *ambient,
                           thread float &screenV) {
        float scale = P[P_SCALE];
        float H = P[P_HEIGHT];
        float x = in.position.x / scale;
        float y = H - in.position.y / scale;
        int edge = int(P[P_EDGE_MODE]);
        Colors C;
        C.stops = stops;
        C.count = int(P[P_STOP_COUNT]);
        C.ambient = P[P_AMBIENT] > 0.5;
        C.here = float3(1.0);
        C.beam = 0.0;
        screenV = 0.0;
        if (C.ambient) {
            float screenU = mix(P[P_AMBIENT_RECT], P[P_AMBIENT_RECT + 1], clamp(x / P[P_WIDTH], 0.0, 1.0));
            screenV = mix(P[P_AMBIENT_RECT + 2], P[P_AMBIENT_RECT + 3], clamp(y / H, 0.0, 1.0));
            int side = edge == 0 || edge == 4 ? 0 : (edge == 1 ? 2 : (edge == 2 ? 3 : 1));
            float4 a = ambientAt(ambient, side, side < 2 ? screenU : screenV);
            C.here = a.rgb;
            C.beam = a.a;
        }
        return C;
    }

    static float4 shade(VOut in, constant float *P, constant float *B, thread const Colors &C, float screenV,
                        constant float4 *particles, constant float *scope, constant float4 *ambient,
                        texture2d<float, access::read> history) {
        float scale = P[P_SCALE];
        float H = P[P_HEIGHT];
        float x = in.position.x / scale;
        float y = H - in.position.y / scale;   // points, measured up from the bottom edge
        int style = int(P[P_STYLE]);
        bool vertical = P[P_AXIS] < 0.5;
        bool peaks = P[P_SHOW_PEAKS] > 0.5;
        float4 pulseL = float4(P[P_PULSE_L], P[P_PULSE_L + 1], P[P_PULSE_L + 2], P[P_PULSE_L + 3]);
        float4 pulseR = float4(P[P_PULSE_R], P[P_PULSE_R + 1], P[P_PULSE_R + 2], P[P_PULSE_R + 3]);
        int edge = int(P[P_EDGE_MODE]);

        // Screen-edge glow: brightness along each edge follows that side's bands (bass at the bottom center,
        // treble up the sides; along the top, bass in the middle like the bars above it), fading in from the edge.
        // The bottom and top windows also draw the sides' glow in their corners, where the side windows stop.
        if (edge > 0) {
            float W = P[P_WIDTH];
            float thickness = P[P_EDGE_THICKNESS];
            float pulseLeft = pulseL.a / 0.92, pulseRight = pulseR.a / 0.92;
            // Up the sides the bands run from the middle (0.5) to treble (1) at the top corners.
            float run = P[P_EDGE_RUN] > 0.5 ? P[P_EDGE_RUN] : H;
            if (edge == 1) {
                return edgeGlowAt(P, B, C, vertical, 1, 0.5 + 0.5 * clamp(y / run, 0.0, 1.0),
                                  x, thickness, pulseLeft);
            }
            if (edge == 2) {
                return edgeGlowAt(P, B, C, vertical, 2, 0.5 + 0.5 * clamp(y / run, 0.0, 1.0),
                                  W - x, thickness, pulseRight);
            }
            bool top = edge == 4;
            float c = W * 0.5;
            bool left = x < c;
            float across = clamp(abs(x - c) / c, 0.0, 1.0);
            float4 g = edgeGlowAt(P, B, C, vertical, left ? 1 : 2, top ? across : 0.5 * across,
                                  top ? H - y : y, thickness, left ? pulseLeft : pulseRight);
            float side = left ? x : W - x;
            if (side < thickness) {
                // The corners carry on the side glow, so in Ambient light they take the side's color.
                Colors corner = C;
                if (C.ambient) {
                    float4 a = ambientAt(ambient, left ? 2 : 3, screenV);
                    corner.here = a.rgb;
                    corner.beam = a.a;
                }
                // Top corners carry on the side's bands where its window stops; bottom corners hold the first one.
                float u = top ? 0.5 + 0.5 * clamp((run - H + y) / run, 0.0, 1.0) : 0.5;
                g = combineGlows(g, edgeGlowAt(P, B, corner, vertical, left ? 1 : 2, u,
                                               side, thickness, left ? pulseLeft : pulseRight));
            }
            return g;
        }

        // Aura: a rim of light hugging the notch, with a halo that reaches further on every bass hit.
        if (style == STYLE_AURA) {
            float lo = P[P_GAP_LO];
            float hi = P[P_GAP_HI];
            float d = notchDistance(float2(x, y), lo, hi, H, P[P_NOTCH_RADIUS]);
            if (d < 0.0) return float4(0.0);   // inside the notch itself
            float4 side = x < (lo + hi) * 0.5 ? pulseL : pulseR;
            float pulse = side.a / 0.92;
            float presence = min(1.0, pulse * 6.0);
            float rim = exp(-d / 3.0) * (0.55 + 0.45 * pulse) * presence;
            float halo = exp(-d / (20.0 + 420.0 * pulse)) * min(1.0, pulse * 1.6);
            float a = clamp(rim + halo, 0.0, 1.0);
            float3 col = mix(side.rgb, float3(1.0), clamp(rim, 0.0, 1.0) * 0.35);
            return float4(col * a, a);
        }

        // Sparks: glowing streaks flying outward from the notch edges.
        if (style == STYLE_SPARKS) {
            int n = int(P[P_PARTICLES]);
            float lo = P[P_GAP_LO];
            float hi = P[P_GAP_HI];
            float rightSpan = P[P_WIDTH] - hi;
            float2 p = float2(x, y);
            float3 sum = float3(0.0);
            float total = 0.0;
            for (int i = 0; i < n; i++) {
                float4 a = particles[i * 2];       // side, distance (0 notch ... 1 screen edge), y (0...1), life
                float4 b = particles[i * 2 + 1];   // speed, vertical speed, hue, size
                float span = a.x < 0.0 ? lo : rightSpan;
                float2 head = float2(a.x < 0.0 ? lo - a.y * span : hi + a.y * span, a.z * H);
                float2 streak = float2(a.x * b.x * span, b.y * H) * 0.05;
                float streakLength = length(streak);
                if (streakLength > 80.0) streak *= 80.0 / streakLength;   // keep fast sparks from smearing
                float dist = segmentDistance(p, head - streak, head);
                float s = b.w;
                float life = pow(a.w, 0.6);   // stay bright for most of the flight
                float glow = life * (exp(-(dist * dist) / (s * s)) + 0.3 * exp(-dist / (s * 3.0)));
                if (glow < 0.002) continue;
                float3 col = vertical ? pal(C, 0.3 + 0.7 * a.w) : pal(C, b.z);
                sum += col * glow;
                total += glow;
            }
            if (total < 0.002) return float4(0.0);
            float alpha = clamp(total, 0.0, 1.0);
            float3 col = mix(sum / total, float3(1.0), clamp(total - 1.0, 0.0, 0.5));
            return float4(col * alpha, alpha);
        }

        // Pulse: one color across the strip, or two blended across the notch.
        if (style == STYLE_PULSE) {
            float4 l = float4(P[P_PULSE_L], P[P_PULSE_L + 1], P[P_PULSE_L + 2], P[P_PULSE_L + 3]);
            float4 r = float4(P[P_PULSE_R], P[P_PULSE_R + 1], P[P_PULSE_R + 2], P[P_PULSE_R + 3]);
            float t = 0.0;
            if (P[P_STEREO] > 0.5) {
                t = clamp((x - P[P_BLEND_LO]) / max(0.001, P[P_BLEND_HI] - P[P_BLEND_LO]), 0.0, 1.0);
            }
            float4 c = mix(l, r, t);
            return float4(c.rgb * c.a, c.a);
        }

        Region r;
        if (!regionAt(x, P, r)) return float4(0.0);
        float width = r.x1 - r.x0;

        // Waterfall: newest column at the notch (or left edge), older columns flowing outward.
        // Height is frequency: bass at the bottom, treble at the top.
        if (style == STYLE_WATERFALL) {
            float d = r.mirrored ? (r.x1 - x) : (x - r.x0);
            int len = int(P[P_HIST_LEN]);
            int age = int(d / P[P_WF_COLUMN]);
            if (age >= len) return float4(0.0);
            uint column = uint((int(P[P_HIST_INDEX]) - age + len * 2) % len);
            float f = clamp(y / H, 0.0, 1.0) * float(r.count - 1);
            uint b0 = uint(floor(f));
            uint b1 = uint(min(int(b0) + 1, r.count - 1));
            uint row = uint(r.channel * MAX_BANDS);
            float level = mix(history.read(uint2(column, row + b0)).r, history.read(uint2(column, row + b1)).r, f - floor(f));
            float fade = 1.0 - smoothstep(0.6, 1.0, d / max(1.0, width));
            float a = pow(level, 1.4) * fade;
            float hue = f / max(1.0, float(r.count - 1));
            float3 col = vertical ? pal(C, 0.25 + 0.75 * level) : pal(C, hue);
            return float4(col * a, a);
        }

        // Scope: the waveform as a glowing line, time running outward from the notch.
        if (style == STYLE_SCOPE) {
            float alpha = P[P_SCOPE_ALPHA];
            if (alpha < 0.002) return float4(0.0);
            int count = int(P[P_SCOPE_POINTS]);
            constant float *wave = scope + r.channel * count;
            float u = (r.mirrored ? (r.x1 - x) : (x - r.x0)) / width;
            float du = (1.0 / scale) / width;
            float v0 = scopeAt(wave, count, u - du);
            float v1 = scopeAt(wave, count, u);
            float v2 = scopeAt(wave, count, u + du);
            float mid = H * 0.5;
            float amp = H * 0.44;
            float lo = mid + min(v1, min((v0 + v1) * 0.5, (v1 + v2) * 0.5)) * amp;
            float hi = mid + max(v1, max((v0 + v1) * 0.5, (v1 + v2) * 0.5)) * amp;
            float dist = y < lo ? lo - y : (y > hi ? y - hi : 0.0);
            float core = 1.0 - smoothstep(0.5, 1.5, dist);
            float a = clamp(core + exp(-dist / 5.0) * 0.45, 0.0, 1.0) * alpha;
            float3 col = vertical ? pal(C, 0.3 + 0.7 * abs(v1)) : pal(C, u);
            col = mix(col, float3(1.0), core * 0.25);
            return float4(col * a, a);
        }

        // Glow: band levels interpolated smoothly across the strip, brightest at the bottom.
        if (style == STYLE_GLOW) {
            float p = (x - r.x0) / width * float(r.count) - 0.5;
            int j0 = clamp(int(floor(p)), 0, r.count - 1);
            int j1 = min(j0 + 1, r.count - 1);
            float f = p < 0.0 ? 0.0 : clamp(p - floor(p), 0.0, 1.0);
            int b0 = r.mirrored ? r.count - 1 - j0 : j0;
            int b1 = r.mirrored ? r.count - 1 - j1 : j1;
            float level = mix(levelOf(B, r.channel, b0), levelOf(B, r.channel, b1), f);
            float hue = r.count > 1 ? mix(float(b0), float(b1), f) / float(r.count - 1) : 0.0;
            float3 col = vertical ? pal(C, 0.3 + 0.7 * level) : pal(C, hue);
            float a = pow(min(1.0, level * 1.3), 1.3) * mix(1.0, 0.5, clamp(y / H, 0.0, 1.0));
            return float4(col * a, a);
        }

        // VU: segments counted outward from the notch, growing taller toward the edges.
        if (style == STYLE_VU) {
            float seg = P[P_VU_SEGMENT];
            float pitch = seg + P[P_VU_SPACING];
            int count = int(width / pitch);
            if (count < 2) return float4(0.0);
            float d = r.mirrored ? (r.x1 - x) : (x - r.x0);
            int k = int(floor(d / pitch));
            if (k >= count || d - float(k) * pitch >= seg) return float4(0.0);
            float fraction = float(k) / float(count - 1);
            float h = snapTo(H * (0.3 + 0.7 * fraction), scale);
            float y0 = snapTo((H - h) / 2.0, scale);
            if (y < y0 || y >= y0 + h) return float4(0.0);
            bool left = r.channel == 1;
            float level = left ? P[P_METER_L] : P[P_METER_R];
            float peak = left ? P[P_METER_PEAK_L] : P[P_METER_PEAK_R];
            int lit = int(round(level * float(count)));
            int peakIndex = peaks ? min(count - 1, int(round(peak * float(count))) - 1) : -1;
            float3 col = pal(C, fraction);
            if (k == peakIndex && peakIndex >= lit - 1) return float4(mix(col, float3(1.0), 0.4), 1.0);
            if (k < lit) return float4(col, 1.0);
            return float4(0.0);
        }

        // Bar styles: find the column under this pixel (edges snapped to whole pixels). On ultrawide screens
        // there are more columns than bands; the extra ones show levels in between their neighbours.
        float px = 1.0 / scale;
        int columns = max(r.count, int(round(float(r.count) * max(1.0, P[P_BAR_COLUMNS]))));
        float slot = width / float(columns);
        int j = clamp(int((x - r.x0) / slot), 0, columns - 1);
        float gap = max(px, snapTo(min(slot * 0.22, 5.0), scale));
        float cx0 = snapTo(r.x0 + float(j) * slot + gap / 2.0, scale);
        float cx1 = max(cx0 + px, snapTo(r.x0 + float(j + 1) * slot - gap / 2.0, scale));
        if (x < cx0 || x >= cx1) return float4(0.0);
        int k = r.mirrored ? columns - 1 - j : j;   // bass first
        float pos = clamp((float(k) + 0.5) / float(columns) * float(r.count) - 0.5, 0.0, float(r.count - 1));
        float hue = r.count > 1 ? pos / float(r.count - 1) : 0.0;
        float level = bandCurve(B, r.channel, r.count, pos);
        float peak = bandCurve(B, 3 + r.channel, r.count, pos);

        if (style == STYLE_LED) {
            float rowsF = P[P_LED_ROWS];
            int rows = int(rowsF);
            float ry = y - P[P_LED_OFFSET];
            float pitch = P[P_LED_PITCH];
            int row = int(floor(ry / pitch));
            if (row < 0 || row >= rows || ry - float(row) * pitch >= P[P_LED_SEGMENT]) return float4(0.0);
            int lit = int(round(level * rowsF));
            float rowFraction = (float(row) + 0.5) / rowsF;
            int peakRow = min(rows - 1, int(round(peak * rowsF)) - 1);
            if (peaks && peakRow >= 0 && peakRow >= lit - 1 && row == peakRow) {
                return float4(capColor(C, vertical, hue, rowFraction), 1.0);
            }
            if (row < lit) {
                return float4(vertical ? pal(C, rowFraction) : pal(C, hue), 1.0);
            }
            return float4(0.0);
        }

        float cap = P[P_CAP];
        if (style == STYLE_CENTER) {
            float mid = H / 2.0;
            if (peaks && peak > 0.015) {
                float ph = snapTo(peak * H / 2.0, scale);
                float top = min(H - cap, mid + ph);
                float bottom = max(0.0, mid - ph - cap);
                if ((y >= top && y < top + cap) || (y >= bottom && y < bottom + cap)) {
                    return float4(capColor(C, vertical, hue, peak), 1.0);
                }
            }
            float halfHeight = snapTo(level * H / 2.0, scale);
            if (y >= mid - halfHeight && y < mid + halfHeight) {
                return float4(vertical ? pal(C, abs(y / H * 2.0 - 1.0)) : pal(C, hue), 1.0);
            }
            return float4(0.0);
        }

        // STYLE_BARS
        if (peaks && peak > 0.015) {
            float cy = min(H - cap, snapTo(peak * H, scale));
            if (y >= cy && y < cy + cap) return float4(capColor(C, vertical, hue, peak), 1.0);
        }
        float h = snapTo(level * H, scale);
        if (y < h) {
            return float4(vertical ? pal(C, y / H) : pal(C, hue), 1.0);
        }
        return float4(0.0);
    }

    // Blending two opposite colors (teal and gold, say) passes through grey; this puts back the saturation
    // the two colors have between them, keeping the blend's hue and brightness.
    static float3 keepSaturation(float3 mixed, float3 a, float3 b, float t) {
        float v = max(mixed.r, max(mixed.g, mixed.b));
        if (v < 0.0001) return mixed;
        float s = (v - min(mixed.r, min(mixed.g, mixed.b))) / v;
        float sa = (max(a.r, max(a.g, a.b)) - min(a.r, min(a.g, a.b))) / max(0.0001, max(a.r, max(a.g, a.b)));
        float sb = (max(b.r, max(b.g, b.b)) - min(b.r, min(b.g, b.b))) / max(0.0001, max(b.r, max(b.g, b.b)));
        float want = mix(sa, sb, t);
        if (s < 0.0001) return mixed;
        return clamp(v - (v - mixed) * (want / s), 0.0, v);
    }

    // Keep menu bar text readable: under light (white) menu bar text, colors bright enough to wash it out are eased
    // down (white and yellow the most; reds, blues and purples hardly at all). Under dark text, the darkest colors
    // are lifted instead. Works on straight (not premultiplied) color.
    float3 readableUnderText(float3 rgb, int mode) {
        float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        if (mode == 1) {
            const float knee = 0.42, ceiling = 0.64;
            if (luma <= knee) return rgb;
            float eased = knee + (ceiling - knee) * (1.0 - exp(-(luma - knee) / (ceiling - knee)));
            return rgb * (eased / luma);
        }
        const float lowest = 0.46;
        if (luma >= lowest) return rgb;
        return mix(rgb, float3(1.0), (lowest - luma) / max(1.0 - luma, 0.001));
    }

    // Entry point: draw the style, then apply the Brightness setting.
    fragment float4 eq_fragment(VOut in [[stage_in]],
                                constant float *P [[buffer(0)]],
                                constant float *B [[buffer(1)]],
                                constant float4 *stops [[buffer(2)]],
                                constant float4 *particles [[buffer(3)]],
                                constant float *scope [[buffer(4)]],
                                constant float4 *ambient [[buffer(5)]],
                                texture2d<float, access::read> history [[texture(0)]]) {
        float screenV;
        Colors C = colorsAt(in, P, stops, ambient, screenV);
        float4 c = shade(in, P, B, C, screenV, particles, scope, ambient, history);
        // A light beam just below the menu bar washes up into the strip, behind the bars,
        // brightest at the bottom where it comes out of the screen.
        if (int(P[P_EDGE_MODE]) == 0 && C.beam > 0.001) {
            float H = P[P_HEIGHT];
            float y = H - in.position.y / P[P_SCALE];
            float w = C.beam * 0.4 * mix(1.0, 0.35, clamp(y / H, 0.0, 1.0));
            c += float4(C.here * w, w) * (1.0 - c.a);
        }
        // Voice: the voice's color spreads out from the middle of the screen while someone sings, further with
        // louder singing (each pixel keeps its own brightness). In the menu bar a soft glow swells out of the middle
        // with each word, behind the bars.
        float3 voice = float3(P[P_VOICE_COLOR], P[P_VOICE_COLOR + 1], P[P_VOICE_COLOR + 2]);
        float reach = P[P_VOICE_TINT] * 1.05;
        if (reach > 0.001 && c.a > 0.0001) {
            float across = clamp(in.position.x / P[P_SCALE] / max(1.0, P[P_WIDTH]), 0.0, 1.0);
            float u = mix(P[P_AMBIENT_RECT], P[P_AMBIENT_RECT + 1], across);   // 0...1 across the screen
            float cover = 1.0 - smoothstep(reach - 0.12, reach, abs(u - 0.5) * 2.0);
            if (cover > 0.001) {
                float3 straight = c.rgb / c.a;
                float level = max(straight.r, max(straight.g, straight.b));
                float3 toward = voice * (level / max(0.001, max(voice.r, max(voice.g, voice.b))));
                c.rgb = keepSaturation(mix(straight, toward, cover), straight, toward, cover) * c.a;
            }
        }
        float glow = P[P_VOICE_GLOW];
        if (int(P[P_EDGE_MODE]) == 0 && glow > 0.001) {
            float H = P[P_HEIGHT];
            float x = in.position.x / P[P_SCALE];
            float y = H - in.position.y / P[P_SCALE];
            float lo = P[P_GAP_LO], hi = P[P_GAP_HI];
            float d = max(0.0, abs(x - (lo + hi) * 0.5) - (hi - lo) * 0.5);   // from the notch's edge, or the middle
            float reach = 30.0 + glow * P[P_WIDTH] * 0.16;
            float g = glow * exp(-d / reach) * mix(1.0, 0.55, clamp(y / H, 0.0, 1.0));
            c += float4(voice * g, g) * (1.0 - 0.6 * c.a);
            c = float4(min(c.rgb, float3(1.0)), min(c.a, 1.0));
        }
        float brightness = P[P_BRIGHTNESS];
        float a = min(1.0, c.a * brightness);
        float3 rgb = min(c.rgb * brightness, float3(a));
        int textGuard = int(P[P_TEXT_GUARD]);
        if (textGuard != 0 && a > 0.0001) rgb = readableUnderText(rgb / a, textGuard) * a;
        return float4(rgb, a);
    }
    """
}

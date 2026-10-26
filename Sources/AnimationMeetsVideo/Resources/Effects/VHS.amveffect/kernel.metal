// A worn video tape played back: lines jitter sideways a little each
// frame, color smears to the right of the picture's detail (tape kept
// far less color than brightness), a band of bad tracking drifts down
// the frame with the bottom lines torn by the head switch, and noise
// streaks along the lines. A new picture every frame.

extern "C" [[stitchable]] float4 amvVHS(coreimage::sampler src, float space, float scale, float wear, float bleed, float tracking,
                                        float noise, float seed, float frame, float seconds, float2 origin, float height,
                                        float amount, coreimage::destination dest) {
    float2 d = dest.coord();
    float4 original = src.sample(src.transform(d));
    height = max(height, 1.0);
    int s = int(seed);
    int tick = int(frame);
    // Lines of a 480-line picture, counted from the top.
    float down = 0.5 - (d.y - origin.y) / height;
    float lineHeight = max(height / 480.0, 1.0);
    int line = int(floor(down * height / lineHeight));

    // Each line's jitter this frame, and a slow sideways wobble.
    float shift = (rand(int3(line, tick, s)) - 0.5) * 4.0 * wear * scale;
    shift += noise3(float3(down * 8.0, seconds * 1.5, 0.0), s) * 3.0 * wear * scale;
    // The tracking band drifts down the frame, its lines pulled sideways.
    float bandMiddle = fract(seconds * 0.06 + rand(int3(s, 7, 11)));
    float fromBand = abs(fract(down - bandMiddle + 0.5) - 0.5);
    float inBand = tracking * (1.0 - smoothstep(0.0, 0.04, fromBand));
    shift += inBand * (rand(int3(line, tick, s), 1) * 0.6 + 0.4) * 24.0 * scale;
    // The head switch tears the last lines at the bottom.
    float torn = smoothstep(0.975, 1.0, down) * max(tracking, wear * 0.5);
    shift += torn * 28.0 * scale;
    // Within the reach effect.json gives.
    shift = clamp(shift, -30.0 * scale, 30.0 * scale);

    // Brightness from the shifted line, a little soft; color from further
    // left, smeared over `bleed`.
    float2 at = d - float2(shift, 0.0);
    float soft = 0.75 * scale;
    float4 middle = src.sample(src.transform(at));
    float3 y3 = toTones(straight(middle), space) * 2.0;
    y3 += toTones(straight(src.sample(src.transform(at - float2(soft, 0.0)))), space);
    y3 += toTones(straight(src.sample(src.transform(at + float2(soft, 0.0)))), space);
    float y = luma(y3 / 4.0);
    float3 chroma = float3(0.0);
    for (int i = 0; i < 6; i++) {
        float3 t = toTones(straight(src.sample(src.transform(at - float2(bleed * float(i) / 5.0, 0.0)))), space);
        chroma += t - luma(t);
    }
    chroma *= (1.0 - 0.25 * wear) / 6.0;
    // Worn tape lifts the blacks and dulls the whites.
    y = mix(y, 0.06 + y * 0.88, wear);

    // Fine noise along each line, and white streaks, most in the band.
    float grain = rand(int3(int2(floor(float2(d.x / (2.0 * scale), float(line)))), tick * 31 + s), 2) - 0.5;
    y += grain * noise * 0.12;
    float streakOdds = noise * 0.015 + inBand * 0.25 + torn * 0.2;
    int2 streakCell = int2(int(floor(d.x / (24.0 * scale))), line);
    if (rand(int3(streakCell, tick * 17 + s), 3) < streakOdds) {
        float along = fract(d.x / (24.0 * scale));
        y = mix(y, 1.0, 0.8 * sin(3.14159265 * along));
    }
    float3 tape = y + chroma;
    float a = middle.a;
    float4 played = float4(fromTones(tape, space) * a, a);
    return mix(original, played, amount);
}

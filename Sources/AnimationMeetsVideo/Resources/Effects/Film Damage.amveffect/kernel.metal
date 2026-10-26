// A worn film print: long scratches down the frame that last a moment,
// drifting and broken, and dust and hairs that are new every frame,
// dark (on the print) or light (on the negative). Sized to the frame's
// height, so the same damage shows at any size.

// The tone a mark takes: black, white, or either at random.
inline float dirtTone(float choice, float r) {
    return choice < 0.5 ? 0.0 : (choice < 1.5 ? 1.0 : (r < 0.5 ? 0.0 : 1.0));
}

extern "C" [[stitchable]] float4 amvFilmDamage(coreimage::sample_t s, float space, float scratches, float dust, float hairs,
                                               float tone, float size, float seed, float frame, float seconds,
                                               float width, float height, float amount, coreimage::destination dest) {
    // In the pixels of a frame 1080 high.
    float unit = 1080.0 / max(height, 1.0);
    float2 u = dest.coord() * unit;
    float across = width * unit;
    int sd = int(seed);
    int tick = int(frame);
    float3 t = toTones(straight(s), space);

    // Scratches: eight places, each scratched or not for a stretch of
    // half a second to two seconds.
    for (int i = 0; i < 8; i++) {
        int3 slot = int3(i, sd, 0);
        float lasts = 0.5 + 1.5 * rand(slot);
        float time = seconds / lasts + rand(slot, 1);
        int3 stretch = int3(i, sd, int(floor(time)));
        if (rand(stretch) >= scratches * 0.6) continue;
        float drift = (rand(stretch, 2) - 0.5) * 60.0 * fract(time) * lasts;
        float wobble = (rand(int3(i, sd, tick), 3) - 0.5) * 2.0;
        float x = rand(stretch, 1) * across + drift + wobble;
        float thickness = (0.8 + 1.6 * rand(stretch, 4)) * size;
        float off = abs(u.x - x);
        if (off > thickness + 2.0) continue;
        float line = 1.0 - smoothstep(thickness * 0.5 - 0.6, thickness * 0.5 + 0.6, off);
        // Broken along its length, and fainter some frames than others.
        float whole = smoothstep(-0.35, -0.1, noise3(float3(u.y / 180.0, float(i) * 3.1, floor(time)), sd));
        float strength = 0.35 + 0.5 * rand(int3(i, sd, tick), 4);
        t = mix(t, float3(dirtTone(tone, rand(stretch, 5))), line * whole * strength);
    }

    // Dust and hairs: at most one a cell, new every frame.
    float cellSize = 90.0 * max(size, 1.0);
    int2 cell = int2(floor(u / cellSize));
    int3 id = int3(cell, tick * 101 + sd);
    float2 within = u - float2(cell) * cellSize;
    float pick = rand(id);
    if (pick < dust * 0.12) {
        float radius = (0.6 + 5.0 * pow(rand(id, 1), 3.0)) * size;
        float2 at = radius + 1.0 + float2(rand(id, 2), rand(id, 3)) * (cellSize - 2.0 * radius - 2.0);
        float2 v = within - at;
        float angle = atan2(v.y, v.x);
        // Lumpy rather than round.
        float edge = radius * (0.8 + 0.25 * sin(3.0 * angle + 6.283 * rand(id, 4)) + 0.1 * sin(5.0 * angle));
        float speck = 1.0 - smoothstep(edge - 0.6, edge + 0.6, length(v));
        t = mix(t, float3(dirtTone(tone, rand(id, 5))), speck * 0.9);
    } else if (pick > 1.0 - hairs * 0.01) {
        // A hair: part of a circle, thin, in the middle of its cell.
        float bend = (14.0 + 20.0 * rand(id, 6)) * size;
        float2 middle = cellSize * 0.5 + (float2(rand(id, 7), rand(id, 8)) - 0.5) * 8.0;
        float2 v = within - middle;
        float start = 6.283 * rand(id, 9), span = 1.0 + 2.0 * rand(id, 10);
        float angle = fract((atan2(v.y, v.x) - start) / 6.283185307) * 6.283185307;
        float onArc = 1.0 - smoothstep(span - 0.2, span, angle);
        float thin = 0.5 + 0.5 * size;
        float hair = (1.0 - smoothstep(thin * 0.5, thin * 0.5 + 0.8, abs(length(v) - bend))) * onArc;
        t = mix(t, float3(dirtTone(tone, rand(id, 11))), hair * 0.85);
    }
    return mixed(s, fromTones(t, space), amount);
}

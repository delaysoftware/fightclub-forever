"""Erzeugt Media/icon.tga (64x64, 32 Bit, unkomprimiert): rundes Fightclub-Symbol mit gekreuzten Klingen."""
import math, struct

N = 64
c = (N - 1) / 2.0
px = [[(0, 0, 0, 0)] * N for _ in range(N)]

def dist_to_segment(x, y, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(x - (ax + t * dx), y - (ay + t * dy))

def blend(dst, src):
    a = src[3] / 255.0
    return (int(dst[0] * (1 - a) + src[0] * a), int(dst[1] * (1 - a) + src[1] * a),
            int(dst[2] * (1 - a) + src[2] * a), max(dst[3], src[3]))

for y in range(N):
    for x in range(N):
        r = math.hypot(x - c, y - c)
        p = (0, 0, 0, 0)
        if r <= 31.5:
            # dunkelroter Hintergrund mit leichtem Verlauf zur Mitte
            k = 1.0 - r / 31.5
            p = (int(70 + 80 * k), int(8 + 14 * k), int(10 + 14 * k), 255)
        if 27.5 <= r <= 31.5:
            p = (212, 170, 40, 255)  # goldener Ring
        if 26.5 <= r < 27.5:
            p = (110, 80, 10, 255)   # dunkle Innenkante
        if r < 26.5:
            for (ax, ay, bx, by) in ((14, 14, 50, 50), (50, 14, 14, 50)):
                d = dist_to_segment(x, y, ax, ay, bx, by)
                if d <= 2.6:
                    p = (235, 235, 240, 255)      # Klinge
                elif d <= 3.6:
                    p = (60, 20, 20, 255)          # dunkle Kontur
            # Parierstangen (kurze Querbalken nahe den unteren Enden)
            for (ax, ay, bx, by) in ((9, 20, 20, 9), (55, 20, 44, 9), (9, 44, 20, 55), (55, 44, 44, 55)):
                pass
        px[y][x] = p

# Griffe: goldene Punkte an den Enden der Klingen
for (gx, gy) in ((14, 14), (50, 14), (14, 50), (50, 50)):
    for y in range(N):
        for x in range(N):
            if math.hypot(x - gx, y - gy) <= 4.2 and math.hypot(x - c, y - c) < 26.5:
                px[y][x] = (212, 170, 40, 255)

header = struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, N, N, 32, 0x28)  # 0x28: 8 Alpha-Bits, Ursprung oben links
body = bytearray()
for row in px:
    for (r_, g_, b_, a_) in row:
        body += bytes((b_, g_, r_, a_))
open('Media/icon.tga', 'wb').write(header + bytes(body))
print('Media/icon.tga geschrieben')

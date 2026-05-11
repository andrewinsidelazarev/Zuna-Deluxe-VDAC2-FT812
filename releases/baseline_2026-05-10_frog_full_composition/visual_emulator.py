#!/usr/bin/env python3
"""visual_emulator.py — ТОЛЬКО tongue sprite, вращается вокруг центра.

Цель: найти правильную формулу rotation для tongue.  Никаких frog body,
plate, overlay — только sprite языка в центре canvas, поворачивается на
угол курсора вокруг своей середины.

Управление:
  мышь    — задаёт угол rotation
  стрелки — двигать UV pivot (red cross на sprite)
  r       — сменить формулу rotation (cycle)
  Esc     — выход
"""
import os, math, random
import tkinter as tk
from PIL import Image, ImageTk, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
GFX = os.path.join(os.path.expanduser('~'), 'Desktop', 'Zuma Deluxe', 'graphics')

# Sprites: plate, body, tongue, overlay — все 122×122 (resize 162→122).
sheet = Image.open(os.path.join(GFX, 'frog.png')).convert('RGBA')
W = 122
body = sheet.crop((0, 0, 162, 162)).resize((W, W), Image.LANCZOS)
plate = sheet.crop((162, 162, 324, 324)).resize((W, W), Image.LANCZOS)
tongue = sheet.crop((162, 0, 324, 162)).resize((W, W), Image.LANCZOS)
overlay = sheet.crop((0, 162, 162, 324)).resize((W, W), Image.LANCZOS)
TW, TH = W, W
print(f'All sprites {W}x{W}')

# Real ball sprites: 6 цветов из spritesheet Zuma Deluxe.
BALL_PNG = os.path.join(GFX, 'Zuma Deluxe - Gameplay - Balls.png')
balls_sheet = Image.open(BALL_PNG).convert('RGBA')   # 192x1632, 6×32×32 cells по rolling rows
BALL_NOW_SIZE = 32                                   # размер sprite в рот
BALL_NEXT_SIZE = 32                                  # next-ball indicator (для покрытия чёрной точки)
BALL_EXPAND_IDLE = 24                                # idle radius ball-now от frog centre (HD = 24)
NEXT_BALL_OFFSET = 28                                # radius next-ball от frog centre (HD = 40, уменьшаем под VDAC2 122 body)
ball_now_sprites = []
ball_next_sprites = []
for ci in range(6):
    cell = balls_sheet.crop((ci * 32, 0, (ci + 1) * 32, 32))     # frame 0
    ball_now_sprites.append(cell.resize((BALL_NOW_SIZE, BALL_NOW_SIZE), Image.LANCZOS))
    ball_next_sprites.append(cell.resize((BALL_NEXT_SIZE, BALL_NEXT_SIZE), Image.LANCZOS))

CW = 480           # canvas square
CENTRE = CW // 2

ROT_FORMULAS = [
    # (label, fn(degrees) -> PIL rotate angle).
    # Перебираем все 8 знак/offset комбинаций + identity.
    ('-(deg - 90)  = 90 - deg',   lambda d: -(d - 90)),
    ('-(deg + 90)',                lambda d: -(d + 90)),
    ('deg - 90',                   lambda d: d - 90),
    ('deg + 90',                   lambda d: d + 90),
    ('90 - deg',                   lambda d: 90 - d),
    ('270 - deg',                  lambda d: 270 - d),
    ('-deg',                       lambda d: -d),
    ('deg',                        lambda d:  d),
]


class App:
    def __init__(self, root):
        self.root = root
        root.title('Tongue rotation tester')
        self.canvas = tk.Canvas(root, width=CW, height=CW, bg='#202028',
                                highlightthickness=0)
        self.canvas.pack(side='left')
        self.info = tk.Label(root, font=('Consolas', 11), justify='left',
                             anchor='nw', width=44, bg='#181818', fg='#cccccc')
        self.info.pack(side='right', fill='y')

        self.mouse_xy = (CENTRE + 100, CENTRE)
        self.pivot_x = TW // 2          # 61 = sprite x-centre
        self.pivot_y = TH // 2          # 61 = sprite y-centre (HD anchor = sprite centre)
        self.tongue_offset = 24         # HD: pos + 24·dir orbit (idle)
        self.formula_idx = 0            # стартовая = -(deg - 90)
        # Fire/recoil state (HD-style)
        self.is_fire = False
        self.recoil_tick_rad = 0.0      # 0..π за полу-цикл выстрела
        self.ball_expand = float(BALL_EXPAND_IDLE)  # idle, fire→0→IDLE
        self.ball_color = random.randint(0, 5)
        self.next_ball_color = random.randint(0, 3)

        self.canvas.bind('<Motion>', self.on_motion)
        self.canvas.bind('<Button-1>', self.on_click)
        root.bind('<Up>',     lambda e: self.adj_y(-1))
        root.bind('<Down>',   lambda e: self.adj_y(+1))
        root.bind('<Left>',   lambda e: self.adj_x(-1))
        root.bind('<Right>',  lambda e: self.adj_x(+1))
        root.bind('r',        lambda e: self.next_formula())
        root.bind('o',        lambda e: self.adj_offset(+2))
        root.bind('p',        lambda e: self.adj_offset(-2))
        root.bind('[',        lambda e: self.adj_ball_radius(-1))
        root.bind(']',        lambda e: self.adj_ball_radius(+1))
        root.bind(',',        lambda e: self.adj_next_offset(-1))
        root.bind('.',        lambda e: self.adj_next_offset(+1))
        root.bind('<Escape>', lambda e: root.destroy())

        self.tk_img = None
        self.tick()

    def adj_x(self, d): self.pivot_x = max(0, min(TW-1, self.pivot_x + d))
    def adj_y(self, d): self.pivot_y = max(0, min(TH-1, self.pivot_y + d))
    def adj_offset(self, d): self.tongue_offset = max(-50, min(80, self.tongue_offset + d))
    def adj_ball_radius(self, d):
        global BALL_EXPAND_IDLE
        BALL_EXPAND_IDLE = max(0, min(40, BALL_EXPAND_IDLE + d))
        if not self.is_fire:
            self.ball_expand = float(BALL_EXPAND_IDLE)
    def adj_next_offset(self, d):
        global NEXT_BALL_OFFSET
        NEXT_BALL_OFFSET = max(0, min(80, NEXT_BALL_OFFSET + d))
    def next_formula(self):
        self.formula_idx = (self.formula_idx + 1) % len(ROT_FORMULAS)

    def on_motion(self, e):
        self.mouse_xy = (e.x, e.y)

    def on_click(self, e):
        # HD: ЛКМ rise → start fire (если не уже firing).
        # ballColor → выстреливаемый = текущий ballColor; next promoted к ballColor.
        if not self.is_fire:
            self.is_fire = True
            self.recoil_tick_rad = 0.0
            self.ball_expand = 0.0
            self.ball_color = self.next_ball_color
            self.next_ball_color = random.randint(0, 3)

    def update_fire(self):
        """HD-style fire/recoil tick.  recoilTick += 0.25 rad/frame.
        recoil = sin(tick); пока > 0:
          tongueExpand = 24 - recoil*24 (язык втянут)
          pos = posStart - dir·recoil·8 (тело откатывается)
        recoil <= 0 → end fire, всё к idle.
        ballExpand: 0 при выстреле, +2.5/frame восстанавливается до 32.
        """
        self.tongue_expand = 24
        self.frog_dx = 0.0
        self.frog_dy = 0.0
        self._cur_recoil = 0.0
        if self.is_fire:
            self.recoil_tick_rad += 0.25
            recoil = math.sin(self.recoil_tick_rad)
            if recoil <= 0:
                self.is_fire = False
                self.recoil_tick_rad = 0.0
                self.ball_expand = BALL_EXPAND_IDLE
            else:
                self.tongue_expand = 24 - recoil * 24
                self._cur_recoil = recoil
        # ballExpand recovers даже после end fire (если еще < IDLE).
        if self.ball_expand < BALL_EXPAND_IDLE:
            self.ball_expand = min(BALL_EXPAND_IDLE, self.ball_expand + 2.5)

    def render(self):
        self.update_fire()
        mx, my = self.mouse_xy
        angle = math.atan2(my - CENTRE, mx - CENTRE)
        deg = math.degrees(angle)
        formula_label, formula_fn = ROT_FORMULAS[self.formula_idx]
        rot_deg = formula_fn(deg)
        # frog pos shift during recoil (HD: posStart - dir·recoil·8)
        recoil = self._cur_recoil
        if recoil > 0:
            self.frog_dx = -math.cos(angle) * recoil * 8
            self.frog_dy = -math.sin(angle) * recoil * 8

        # Background
        img = Image.new('RGBA', (CW, CW), (40, 40, 50, 255))
        draw_bg = ImageDraw.Draw(img)
        # Reference lines: cardinal directions
        draw_bg.line([(0, CENTRE), (CW, CENTRE)], fill=(80, 80, 90, 255), width=1)
        draw_bg.line([(CENTRE, 0), (CENTRE, CW)], fill=(80, 80, 90, 255), width=1)
        # Cursor direction line (green)
        cx = CENTRE + 200 * math.cos(angle)
        cy = CENTRE + 200 * math.sin(angle)
        draw_bg.line([(CENTRE, CENTRE), (cx, cy)], fill=(0, 255, 100, 255), width=2)

        # frog pos with recoil (HD: posStart - dir·recoil·8 during fire)
        fx = CENTRE + self.frog_dx
        fy = CENTRE + self.frog_dy

        # plate at frog pos
        img.alpha_composite(plate, (int(fx - W/2), int(fy - W/2)))
        # body at frog pos, rotated
        body_rot = body.rotate(rot_deg, resample=Image.BILINEAR, expand=False)
        img.alpha_composite(body_rot, (int(fx - W/2), int(fy - W/2)))

        # HD logic: tongue 122×122 sprite, centre at (frog + tongueExpand·dir).
        # tongueExpand = 24 idle, втягивается до 0 при выстреле.
        tongue_cx = fx + self.tongue_expand * math.cos(angle)
        tongue_cy = fy + self.tongue_expand * math.sin(angle)
        pivot = (self.pivot_x, self.pivot_y)
        tongue_rot = tongue.rotate(rot_deg, resample=Image.BILINEAR,
                                    center=pivot, expand=True)
        rw, rh = tongue_rot.size
        ax = int(tongue_cx - rw / 2)
        ay = int(tongue_cy - rh / 2)
        img.alpha_composite(tongue_rot, (ax, ay))

        # ball-now (выстреливаемый шар во рту) — pos + ballExpand·dir.
        # Real ball sprite from spritesheet (32×32).
        ball_x = fx + self.ball_expand * math.cos(angle)
        ball_y = fy + self.ball_expand * math.sin(angle)
        spr_now = ball_now_sprites[self.ball_color]
        img.alpha_composite(spr_now,
                            (int(ball_x - BALL_NOW_SIZE/2), int(ball_y - BALL_NOW_SIZE/2)))

        # next-ball indicator (на спине frog) — pos - NEXT_BALL_OFFSET·dir.
        nb_x = fx - NEXT_BALL_OFFSET * math.cos(angle)
        nb_y = fy - NEXT_BALL_OFFSET * math.sin(angle)
        spr_next = ball_next_sprites[self.next_ball_color]
        img.alpha_composite(spr_next,
                            (int(nb_x - BALL_NEXT_SIZE/2), int(nb_y - BALL_NEXT_SIZE/2)))

        # face overlay (HD blink frame 0) — поверх всего, маскирует корни tongue
        # и часть ball-now.  Mouth opening alpha=0 → ball-now виден через рот.
        overlay_rot = overlay.rotate(rot_deg, resample=Image.BILINEAR, expand=False)
        img.alpha_composite(overlay_rot, (int(fx - W/2), int(fy - W/2)))

        # Markers
        draw = ImageDraw.Draw(img)
        # frog centre (shifts during recoil) — red cross + ring
        draw.ellipse([fx-6, fy-6, fx+6, fy+6], outline=(255, 0, 0, 255), width=2)
        draw.line([(fx-9, fy), (fx+9, fy)], fill=(255, 0, 0, 255), width=1)
        draw.line([(fx, fy-9), (fx, fy+9)], fill=(255, 0, 0, 255), width=1)
        # posStart (canvas centre, fixed) — faint blue ring (для recoil reference)
        draw.ellipse([CENTRE-4, CENTRE-4, CENTRE+4, CENTRE+4],
                     outline=(80, 120, 220, 200), width=1)

        self.tk_img = ImageTk.PhotoImage(img)
        self.canvas.delete('all')
        self.canvas.create_image(0, 0, image=self.tk_img, anchor='nw')

        cnames = ['BLUE','GREEN','YELLOW','RED','PURPLE','WHITE']
        info = (
            f'HD-style frog full composition\n'
            f'plate+body+tongue+ball+nextball+overlay\n'
            f'\n'
            f'mouse: {self.mouse_xy}\n'
            f'angle: {int(deg) % 360}°\n'
            f'\n'
            f'Pivot UV: ({self.pivot_x}, {self.pivot_y})\n'
            f'Formula:  {formula_label}\n'
            f'\n'
            f'FIRE state:\n'
            f'  isFire:       {self.is_fire}\n'
            f'  recoil:       {self._cur_recoil:.3f}\n'
            f'  tongueExpand: {self.tongue_expand:.1f}\n'
            f'  ballExpand:   {self.ball_expand:.1f}\n'
            f'  pos shift:    ({self.frog_dx:+.1f},{self.frog_dy:+.1f})\n'
            f'\n'
            f'BALLS:\n'
            f'  now:  {cnames[self.ball_color]}\n'
            f'  next: {cnames[self.next_ball_color]}\n'
            f'\n'
            f'KEYS:\n'
            f'  arrows  - tongue pivot UV\n'
            f'  [ / ]   - ball-now radius ({BALL_EXPAND_IDLE})\n'
            f'  , / .   - next-ball radius ({NEXT_BALL_OFFSET})\n'
            f'  r       - cycle rotation formula\n'
            f'  ЛКМ     - выстрел\n'
            f'  Esc     - quit\n'
            f'\n'
            f'red   = frog centre (с recoil shift)\n'
            f'blue  = posStart (idle)\n'
            f'green = cursor direction\n'
        )
        self.info.config(text=info)

    def tick(self):
        self.render()
        self.root.after(20, self.tick)


if __name__ == '__main__':
    root = tk.Tk()
    App(root)
    root.mainloop()

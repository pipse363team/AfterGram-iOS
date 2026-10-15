class Color:
    BLACK = 0xFF000000
    WHITE = 0xFFFFFFFF
    TRANSPARENT = 0
    RED = 0xFFFF0000
    GREEN = 0xFF00FF00
    BLUE = 0xFF0000FF
    @staticmethod
    def rgb(red, green, blue): return 0xFF000000 | (int(red) << 16) | (int(green) << 8) | int(blue)
    @staticmethod
    def argb(alpha, red, green, blue): return (int(alpha) << 24) | (int(red) << 16) | (int(green) << 8) | int(blue)
    @staticmethod
    def parseColor(value):
        value = str(value).lstrip('#')
        return int(value, 16) | (0xFF000000 if len(value) == 6 else 0)

class Typeface:
    DEFAULT = 'default'
    DEFAULT_BOLD = 'default-bold'
    NORMAL = 0
    BOLD = 1
    ITALIC = 2
    @staticmethod
    def create(family, style=0): return (family, style)

class Paint:
    ANTI_ALIAS_FLAG = 1

class Bitmap:
    class Config: ARGB_8888 = 'ARGB_8888'
    @staticmethod
    def createBitmap(*args, **kwargs): raise NotImplementedError('Android Bitmap rendering needs a native iOS adapter')

class Canvas:
    def __init__(self, bitmap=None): self.bitmap = bitmap
    def __getattr__(self, name):
        if name.startswith('draw'): raise NotImplementedError('Android Canvas drawing needs a native iOS adapter')
        raise AttributeError(name)

class Rect:
    def __init__(self, left=0, top=0, right=0, bottom=0): self.left,self.top,self.right,self.bottom = left,top,right,bottom
    def width(self): return self.right - self.left
    def height(self): return self.bottom - self.top

class PorterDuff:
    class Mode: SRC_IN = 'src_in'; SRC_ATOP = 'src_atop'; MULTIPLY = 'multiply'

class Drawable:
    def setBounds(self, left, top, right, bottom): self.bounds = Rect(left, top, right, bottom)
    def setAlpha(self, value): self.alpha = int(value)
    def setColorFilter(self, *args): self.color_filter = args

class ColorDrawable(Drawable):
    def __init__(self, color=Color.TRANSPARENT): self.color = color

class GradientDrawable(Drawable):
    RECTANGLE = 0
    OVAL = 1
    def __init__(self, *args): self.color = Color.TRANSPARENT
    def setColor(self, color): self.color = color
    def setCornerRadius(self, radius): self.corner_radius = float(radius)
    def setShape(self, shape): self.shape = shape
    def setStroke(self, width, color): self.stroke = (int(width), color)

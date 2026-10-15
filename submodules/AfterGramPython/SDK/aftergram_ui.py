"""Portable form models rendered with native iOS dialogs."""
from aftergram_java import String

from aftergram_intents import Context as NativeContext

class View:
    VISIBLE = 0
    INVISIBLE = 4
    GONE = 8
    def __init__(self, context=None):
        self.context = context or NativeContext();self.text = '';self.hint = ''
        self.children = [];self.enabled = True;self.visibility = self.VISIBLE
        self.listener = None;self.input_type = 1;self.font_size = 16
    def getContext(self): return self.context
    def setVisibility(self, value): self.visibility = value
    def setEnabled(self, value): self.enabled = bool(value)
    def setPadding(self, left, top, right, bottom): self.padding = (left,top,right,bottom)
    def setBackgroundColor(self, value): self.background_color = value
    def setLayoutParams(self, value): self.layout_params = value
    def setOnClickListener(self, value): self.listener = value
    def setOnTouchListener(self, value): self.touch_listener = value
    def getVisibility(self): return self.visibility
    def getWidth(self): return getattr(self, 'width', 0)
    def getHeight(self): return getattr(self, 'height', 0)
    def post(self, runnable):
        from android_utils import run_on_ui_thread
        return run_on_ui_thread(runnable)
    def postDelayed(self, runnable, delay):
        from android_utils import run_on_ui_thread
        return run_on_ui_thread(runnable, delay)

class TextView(View):
    def setText(self, text): self.text = str(text or '')
    def getText(self): return String(self.text)
    def setHint(self, hint): self.hint = str(hint)
    def setTextSize(self, *args): self.font_size = float(args[-1])
    def setTextColor(self, value): self.text_color = value
    def setGravity(self, value): self.gravity = value

class EditText(TextView):
    def setInputType(self, value): self.input_type = int(value)
    def setSingleLine(self, value=True): self.single_line = bool(value)
    def setMaxLines(self, value): self.max_lines = int(value)
    def setSelection(self, *args): self.selection = args

class Button(TextView): pass
class ButtonWithCounterView(Button):
    def setSubtext(self, value): self.subtext = str(value)

class LinearLayout(View):
    VERTICAL = 1
    HORIZONTAL = 0
    def setOrientation(self, value): self.orientation = value
    def setGravity(self, value): self.gravity = value
    def addView(self, view, params=None):
        if not isinstance(view, View): raise TypeError('Expected a portable view')
        self.children.append(view)
    def getChildAt(self, index): return self.children[index]
    def getChildCount(self): return len(self.children)

class FrameLayout(LinearLayout): pass

class ViewGroup(FrameLayout):
    class LayoutParams:
        MATCH_PARENT = -1
        WRAP_CONTENT = -2
        def __init__(self, width, height): self.width,self.height = width,height

class ScrollView(FrameLayout):
    def setFillViewport(self, value): self.fill_viewport = bool(value)
    def setVerticalScrollBarEnabled(self, value): self.vertical_scrollbar = bool(value)

class MotionEvent:
    ACTION_DOWN = 0
    ACTION_UP = 1
    ACTION_MOVE = 2
    ACTION_CANCEL = 3

class _Listener: pass
View.OnClickListener = _Listener
View.OnTouchListener = _Listener

class Gravity:
    CENTER = 17
    CENTER_HORIZONTAL = 1
    CENTER_VERTICAL = 16
    LEFT = 3
    RIGHT = 5
    TOP = 48
    BOTTOM = 80

class InputType:
    TYPE_CLASS_TEXT = 1
    TYPE_CLASS_NUMBER = 2
    TYPE_CLASS_PHONE = 3
    TYPE_TEXT_VARIATION_PASSWORD = 128
    TYPE_TEXT_FLAG_MULTI_LINE = 131072

class LayoutHelper:
    MATCH_PARENT = -1
    WRAP_CONTENT = -2
    @staticmethod
    def createLinear(*args): return args
    createFrame = createLinear

def flatten(view):
    if view.visibility != View.VISIBLE: return []
    if isinstance(view, LinearLayout): return [child for item in view.children for child in flatten(item)]
    return [view]

def as_json(view):
    return {'kind':'input' if isinstance(view, EditText) else ('button' if isinstance(view, Button) else 'text'),
            'text':view.text, 'hint':view.hint, 'enabled':view.enabled, 'font_size':view.font_size,
            'secure':bool(view.input_type & InputType.TYPE_TEXT_VARIATION_PASSWORD), 'input_type':view.input_type & 15}

class NativeFragment:
    def getParentActivity(self): return NativeContext()
    def getContext(self): return NativeContext()
    def showDialog(self, dialog): return dialog.show()
    def getResourceProvider(self): return None

class ActionBar:
    def __init__(self): self.title = ''
    def setTitle(self, value): self.title = str(value)

class AlertDialog:
    class Builder:
        def __init__(self, context=None, *args, **kwargs):
            from ui.alert import AlertDialogBuilder
            self._builder = AlertDialogBuilder(context)
        def setTitle(self, value): self._builder.set_title(value);return self
        def setMessage(self, value): self._builder.set_message(value);return self
        def setPositiveButton(self, text, listener=None): self._builder.set_positive_button(text, listener);return self
        def setNegativeButton(self, text, listener=None): self._builder.set_negative_button(text, listener);return self
        def setNeutralButton(self, text, listener=None): self._builder.set_neutral_button(text, listener);return self
        def setItems(self, values, listener=None): self._builder.set_items(values, listener);return self
        def setCancelable(self, value): self._builder.set_cancelable(value);return self
        def create(self): return self._builder
        def show(self): return self._builder.show()

BaseFragment = NativeFragment

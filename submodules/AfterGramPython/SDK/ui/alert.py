from uuid import uuid4
from aftergram_host import current, emit
from aftergram_ui import View, EditText, Button, flatten, as_json

class AlertDialogBuilder:
    ALERT_TYPE_MESSAGE = 0
    ALERT_TYPE_LOADING = 1
    ALERT_TYPE_SPINNER = 2
    BUTTON_POSITIVE = -1
    BUTTON_NEGATIVE = -2
    BUTTON_NEUTRAL = -3
    def __init__(self, context, progress_style=0, resources_provider=None):
        self.dialog_id = uuid4().hex;self.title = '';self.message = '';self.progress_style = progress_style
        self.progress = 0;self.cancelable = True;self.buttons = {};self.items = [];self.item_listener = None
        self.view = None;self.dismiss_listener = None;self.cancel_listener = None;self.back_listener = None
        self.shown = False;self.closed = False
    def _update(self):
        if self.shown and not self.closed: emit({'type':'dialog_update', **self._json()})
        return self
    def set_title(self, title): self.title = str(title);return self._update()
    def set_message(self, message): self.message = str(message);return self._update()
    def set_progress(self, progress): self.progress = max(0,min(100,int(progress)));return self._update()
    def set_cancelable(self, value): self.cancelable = bool(value);return self._update()
    def set_canceled_on_touch_outside(self, value): return self.set_cancelable(value)
    def set_view(self, view, height=-2):
        if not isinstance(view, View): raise NotImplementedError('Dialog requires portable iOS form controls')
        self.view = view;return self
    def set_items(self, items, listener=None, icons=None): self.items = list(map(str,items));self.item_listener = listener;return self
    def _button(self, which, text, listener): self.buttons[which] = {'text':str(text),'callback':listener,'red':False};return self
    def set_positive_button(self, text, listener=None): return self._button(-1,text,listener)
    def set_negative_button(self, text, listener=None): return self._button(-2,text,listener)
    def set_neutral_button(self, text, listener=None): return self._button(-3,text,listener)
    def make_button_red(self, button_type): self.buttons[button_type]['red'] = True;return self._update()
    def set_on_dismiss_listener(self, listener=None): self.dismiss_listener = listener;return self
    def set_on_cancel_listener(self, listener=None): self.cancel_listener = listener;return self
    def set_on_back_button_listener(self, listener=None): self.back_listener = listener;return self
    def create(self): return self
    def get_dialog(self): return self if not self.closed else None
    def _json(self):
        controls = flatten(self.view) if self.view else []
        return {'dialog':self.dialog_id, 'title':self.title, 'message':self.message, 'progress_style':self.progress_style,
                'progress':self.progress,'cancelable':self.cancelable, 'items':self.items,
                'buttons':[{'which':k,'text':v['text'],'red':v['red']} for k,v in self.buttons.items()],
                'controls':[as_json(v) for v in controls]}
    def show(self):
        if self.closed: raise ValueError('Create a new builder after dismissing a dialog')
        ctx = current()
        if len(ctx['host'].dialogs) >= 16 and self.dialog_id not in ctx['host'].dialogs: raise ValueError('Too many plugin dialogs')
        ctx['host'].dialogs[self.dialog_id] = (self,dict(ctx))
        self.shown = True;emit({'type':'dialog', **self._json()});return self
    def dismiss(self):
        if self.closed: return
        self.closed = True;current()['host'].dialogs.pop(self.dialog_id,None)
        emit({'type':'dialog_dismiss','dialog':self.dialog_id})
        if self.dismiss_listener: self.dismiss_listener(self)
    def _event(self, event, which, values):
        if self.closed: return
        controls = flatten(self.view) if self.view else []
        inputs = [v for v in controls if isinstance(v, EditText)]
        for view,text in zip(inputs,values): view.setText(text)
        if event == 'button':
            callback = self.buttons.get(which,{}).get('callback')
            if callback: callback(self,which)
        elif event == 'item' and self.item_listener: self.item_listener(self,which)
        elif event == 'control' and 0 <= which < len(controls):
            view = controls[which]
            if isinstance(view,Button) and view.listener: view.listener(view)
        elif event == 'cancel':
            if self.back_listener: self.back_listener(self,-2)
            if self.cancel_listener: self.cancel_listener(self)
        self.dismiss()

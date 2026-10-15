import logging
from aftergram_host import emit, schedule

def log(message): logging.getLogger('plugin').info(message)
def run_on_ui_thread(fn, delay=0): return schedule(fn, delay)
def copy_to_clipboard(text): emit({'type': 'clipboard', 'text': str(text)})

class R:
    def __init__(self, fn):
        if not callable(fn): raise TypeError('Expected a callback')
        self.fn = fn
    def run(self): return self.fn()
    def __call__(self): return self.fn()

class OnClickListener:
    def __init__(self, fn): self.fn = fn
    def onClick(self, view): return self.fn(view)
    def __call__(self, view=None): return self.onClick(view)

class OnLongClickListener:
    def __init__(self, fn): self.fn = fn
    def onLongClick(self, view): return bool(self.fn(view))
    def __call__(self, view=None): return self.onLongClick(view)

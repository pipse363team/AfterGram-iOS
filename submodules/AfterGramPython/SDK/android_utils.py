import logging
from aftergram_host import emit, schedule

def log(message): logging.getLogger('plugin').info(message)
def run_on_ui_thread(fn, delay=0): return schedule(fn, delay)
def copy_to_clipboard(text): emit({'type': 'clipboard', 'text': str(text)})

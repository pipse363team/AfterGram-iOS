from aftergram_host import current, emit, schedule
STAGE_QUEUE = 'stageQueue'
GLOBAL_QUEUE = 'globalQueue'
CACHE_CLEAR_QUEUE = 'cacheClearQueue'
SEARCH_QUEUE = 'searchQueue'
PHONE_BOOK_QUEUE = 'phoneBookQueue'
THEME_QUEUE = 'themeQueue'
EXTERNAL_NETWORK_QUEUE = 'externalNetworkQueue'
PLUGINS_QUEUE = 'pluginsQueue'

def send_message(params, parse_mode=None, *, account=None):
    ctx = current()
    if account is not None and account != ctx['account']:
        raise ValueError('Sending across accounts is not supported')
    supported = {'peer', 'message', 'notify', 'replyToMsg', 'scheduleDate'}
    if set(params) - supported or parse_mode:
        raise NotImplementedError('Only plain text, reply, notification and schedule fields are supported')
    text = params.get('message')
    if not isinstance(text, str) or not text or len(text) > 4096:
        raise ValueError('Expected nonempty text up to 4096 characters')
    peer = int(params.get('peer', ctx.get('dialog_id', 0)))
    if not peer: raise ValueError('A Telegram dialog ID is required')
    native_peer = ctx.get('native_peer') if peer == ctx.get('dialog_id') else None
    emit({'type': 'send', 'native_peer': native_peer, 'peer': str(peer), 'text': text, 'notify': bool(params.get('notify', True)),
          'reply': int(params.get('replyToMsg') or 0), 'schedule': int(params.get('scheduleDate') or 0)})

def send_text(peer_id, text, replyToMsg=None, parse_mode=None, *, account=None):
    return send_message({'peer': peer_id, 'message': text, 'replyToMsg': replyToMsg}, parse_mode, account=account)

def run_on_queue(fn, queue_name=GLOBAL_QUEUE, delay=0): return schedule(fn, delay)
def send_request(*args, **kwargs): raise NotImplementedError('Raw Java TLRPC requests need an iOS adapter')
def edit_message(*args, **kwargs): raise NotImplementedError('Message editing is not yet supported')
class AccountClient:
    def __init__(self, account=None): self.account = account
    def send_text(self, peer_id, text, **kwargs): return send_text(peer_id, text, account=self.account, **kwargs)
    def send_message(self, params, **kwargs): return send_message(params, account=self.account, **kwargs)

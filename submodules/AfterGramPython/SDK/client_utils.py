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
    supported = {'peer', 'message', 'notify', 'replyToMsg', 'scheduleDate', 'entities'}
    if set(params) - supported:
        raise NotImplementedError('Unsupported send_message fields: ' + ', '.join(sorted(set(params) - supported)))
    text = params.get('message')
    from extera_utils.text_formatting import parse_text, serialize_entities, utf16_length
    if parse_mode:
        if params.get('entities'): raise ValueError('Use either parse_mode or explicit entities')
        parsed = parse_text(text, parse_mode)
        text, entities = parsed['message'], parsed['entities']
    else: entities = params.get('entities', [])
    if not isinstance(text, str) or not text or utf16_length(text) > 4096:
        raise ValueError('Expected nonempty text up to 4096 characters')
    peer = int(params.get('peer', ctx.get('dialog_id', 0)))
    if not peer: raise ValueError('A Telegram dialog ID is required')
    native_peer = ctx.get('native_peer') if peer == ctx.get('dialog_id') else None
    emit({'type': 'send', 'native_peer': native_peer, 'peer': str(peer), 'text': text, 'entities': serialize_entities(entities, text), 'notify': bool(params.get('notify', True)),
          'reply': int(params.get('replyToMsg') or 0), 'schedule': int(params.get('scheduleDate') or 0)})

def send_text(peer_id, text, replyToMsg=None, parse_mode=None, *, account=None):
    return send_message({'peer': peer_id, 'message': text, 'replyToMsg': replyToMsg}, parse_mode, account=account)

def _send_media(kind, peer_id, path, caption='', parse_mode=None, *, account=None, replyToMsg=None, notify=True, scheduleDate=0, with_spoiler=False, high_quality=False):
    from pathlib import Path
    from extera_utils.text_formatting import parse_text, serialize_entities, utf16_length
    ctx = current()
    if account is not None and account != ctx['account']: raise ValueError('Sending across accounts is not supported')
    file = Path(path).expanduser().resolve()
    if not file.is_file() or not 0 < file.stat().st_size <= 512 * 1024 * 1024: raise ValueError('Expected a local media file up to 512 MB')
    parsed = parse_text(caption or '', parse_mode)
    if utf16_length(parsed['message']) > 1024: raise ValueError('Media caption exceeds 1024 UTF-16 units')
    peer = int(peer_id)
    if not peer: raise ValueError('A Telegram dialog ID is required')
    emit({'type':'send', 'peer':str(peer), 'native_peer':ctx.get('native_peer') if peer == ctx.get('dialog_id') else None,
          'text':parsed['message'], 'entities':serialize_entities(parsed['entities'], parsed['message']),
          'reply':int(replyToMsg or 0), 'notify':bool(notify), 'schedule':int(scheduleDate or 0),
          'media':{'kind':kind, 'path':str(file), 'spoiler':bool(with_spoiler), 'high_quality':bool(high_quality)}})

def send_photo(peer_id, path, caption='', high_quality=False, parse_mode=None, **kwargs):
    return _send_media('photo', peer_id, path, caption, parse_mode, high_quality=high_quality, **kwargs)
def send_document(peer_id, path, caption='', parse_mode=None, **kwargs): return _send_media('document', peer_id, path, caption, parse_mode, **kwargs)
def send_video(peer_id, path, caption='', parse_mode=None, **kwargs): return _send_media('video', peer_id, path, caption, parse_mode, **kwargs)
def send_audio(peer_id, path, caption='', parse_mode=None, **kwargs): return _send_media('audio', peer_id, path, caption, parse_mode, **kwargs)

def run_on_queue(fn, queue_name=PLUGINS_QUEUE, delay=0):
    get_queue_by_name(queue_name)
    return schedule(fn, delay, background=True)

class _Queue:
    def __init__(self, name): self.name = name
    def postRunnable(self, runnable, delay=0): return schedule(runnable, delay, background=True)
    def cancelRunnable(self, runnable):
        ctx = current()
        with ctx['host'].state_lock:
            ctx['host'].jobs = [job for job in ctx['host'].jobs if not (job[1] == ctx['plugin'] and job[2] is runnable)]

def get_queue_by_name(name):
    if name not in {STAGE_QUEUE, GLOBAL_QUEUE, CACHE_CLEAR_QUEUE, SEARCH_QUEUE, PHONE_BOOK_QUEUE, THEME_QUEUE, EXTERNAL_NETWORK_QUEUE, PLUGINS_QUEUE}:
        raise ValueError('Unknown queue: ' + str(name))
    return _Queue(name)

def get_selected_account(): return current()['account']
def get_last_fragment():
    from aftergram_ui import NativeFragment
    return NativeFragment()
def send_request(request, fn, *, account=None):
    ctx = current()
    if account is not None and account != ctx['account']: raise ValueError('Requests across accounts are not supported')
    from aftergram_tl import TLObject, encode
    if not isinstance(request, TLObject) or not request._model or not request._model.get('function'):
        raise TypeError('Expected a TLRPC request generated for this Telegram API layer')
    if not callable(fn): raise TypeError('Expected a request callback')
    payload = encode(request)
    callback = ctx['host'].register_callback(fn, request._model['result'])
    emit({'type':'rpc', 'callback':callback, 'name':request._model['name'], 'payload':payload})
    return int(callback)

def cancel_request(request_id):
    ctx = current();key = str(request_id)
    pending = ctx['host'].callbacks.get(key)
    if pending and pending[1]['plugin'] == ctx['plugin']:
        ctx['host'].callbacks.pop(key)
        emit({'type':'cancel_rpc', 'callback':key})

class _ConnectionsManager:
    def __init__(self, account=None): self.account = account
    def sendRequest(self, request, callback, *flags): return send_request(request, callback, account=self.account)
    def cancelRequest(self, request_id, notify_server=False): return cancel_request(request_id)

def get_connections_manager(account=None): return _ConnectionsManager(account)

class _SendMessagesHelper:
    def generatePhotoSizes(self, path, *args):
        from pathlib import Path
        file = Path(path)
        if not file.is_file(): return None
        return {'path':str(file.resolve()), 'kind':'photo'}

def get_send_messages_helper(): return _SendMessagesHelper()

class _MessagesStorage:
    def updateUserInfo(self, *args, **kwargs): return None

def get_messages_storage(): return _MessagesStorage()

def get_java_class(name):
    from aftergram_hooks import find_class
    return find_class(name)

def _account_context(account):
    ctx = current()
    if account is not None and account != ctx['account']: raise ValueError('This account is not in plugin callback scope')
    return ctx

class _MessagesController:
    def __init__(self, account=None): self.account = account
    def getInputPeer(self, dialog_id):
        from aftergram_tl import TLRPC
        host = _account_context(self.account)['host'];dialog_id = int(dialog_id)
        if dialog_id == host.self_id and dialog_id: return TLRPC.TL_inputPeerSelf()
        if dialog_id not in host.peers: raise ValueError('Chat information is unavailable; fetch dialogs or use the current chat')
        return host.peers[dialog_id]
    def getInputUser(self, user_id):
        from aftergram_tl import TLRPC
        peer = self.getInputPeer(user_id)
        if isinstance(peer, TLRPC.TL_inputPeerSelf): return TLRPC.TL_inputUserSelf()
        if not isinstance(peer, TLRPC.TL_inputPeerUser): raise ValueError('Expected a Telegram user')
        return TLRPC.TL_inputUser(user_id=peer.user_id, access_hash=peer.access_hash)
    def getUser(self, user_id): return _account_context(self.account)['host'].users.get(int(user_id))
    def getChat(self, chat_id): return _account_context(self.account)['host'].chats.get(abs(int(chat_id)))

def get_messages_controller(account=None): return _MessagesController(account)

class _UserConfig:
    def __init__(self, account=None): self.account = account
    def getClientUserId(self): return _account_context(self.account)['host'].self_id
    @property
    def clientUserId(self): return self.getClientUserId()
    def getCurrentUser(self):
        host = _account_context(self.account)['host'];return host.users.get(host.self_id)
    def isClientActivated(self): return bool(self.getClientUserId())

def get_user_config(account=None): return _UserConfig(account)

class _AccountInstance:
    def __init__(self, account=None): self.account = account
    def getMessagesController(self): return get_messages_controller(self.account)
    def getConnectionsManager(self): return get_connections_manager(self.account)
    def getUserConfig(self): return get_user_config(self.account)

def get_account_instance(account=None): return _AccountInstance(account)
def edit_message(message_obj, text=None, file_path=None, with_spoiler=False, parse_mode=None, *, account=None):
    ctx = current()
    if account is not None and account != ctx['account']: raise ValueError('Editing across accounts is not supported')
    if file_path or with_spoiler: raise NotImplementedError('Replacing message media needs a native adapter')
    from extera_utils.text_formatting import parse_text, serialize_entities, utf16_length
    parsed = parse_text(text, parse_mode)
    if not parsed['message'] or utf16_length(parsed['message']) > 4096: raise ValueError('Expected nonempty text up to 4096 characters')
    peer = int(message_obj.getDialogId())
    message_id = int(message_obj.getId())
    if not peer or not 0 < message_id <= 2147483647: raise ValueError('Expected a cloud message')
    emit({'type': 'edit', 'peer': str(peer), 'native_peer': ctx.get('native_peer') if peer == ctx.get('dialog_id') else None,
          'id': message_id, 'text': parsed['message'], 'entities': serialize_entities(parsed['entities'], parsed['message'])})
class AccountClient:
    def __init__(self, account=None): self.account = account
    def send_text(self, peer_id, text, **kwargs): return send_text(peer_id, text, account=self.account, **kwargs)
    def send_message(self, params, **kwargs): return send_message(params, account=self.account, **kwargs)
    def edit_message(self, message_obj, **kwargs): return edit_message(message_obj, account=self.account, **kwargs)
    def send_request(self, request, fn): return send_request(request, fn, account=self.account)
    def send_photo(self, peer_id, path, **kwargs): return send_photo(peer_id, path, account=self.account, **kwargs)
    def send_document(self, peer_id, path, **kwargs): return send_document(peer_id, path, account=self.account, **kwargs)
    def send_video(self, peer_id, path, **kwargs): return send_video(peer_id, path, account=self.account, **kwargs)
    def send_audio(self, peer_id, path, **kwargs): return send_audio(peer_id, path, account=self.account, **kwargs)

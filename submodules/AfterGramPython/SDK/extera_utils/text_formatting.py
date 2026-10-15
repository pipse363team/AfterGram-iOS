"""Telegram text formatting with UTF-16 offsets shared by Android and iOS."""
from dataclasses import dataclass
from enum import Enum
from html import escape
from html.parser import HTMLParser
import re

class TLEntityType(Enum):
    CODE = 'code'
    PRE = 'pre'
    STRIKETHROUGH = 'strikethrough'
    TEXT_LINK = 'text_link'
    BOLD = 'bold'
    ITALIC = 'italic'
    UNDERLINE = 'underline'
    SPOILER = 'spoiler'
    CUSTOM_EMOJI = 'custom_emoji'
    BLOCKQUOTE = 'blockquote'
    URL = 'url'
    MENTION = 'mention'
    HASHTAG = 'hashtag'
    BOT_COMMAND = 'bot_command'
    EMAIL = 'email'
    PHONE_NUMBER = 'phone_number'
    TEXT_MENTION = 'text_mention'

@dataclass
class RawEntity:
    type: TLEntityType
    offset: int
    length: int
    url: str = None
    language: str = None
    document_id: int = None
    collapsed: bool = False
    user_id: int = None

_ENTITY_NAMES = {'code':'Code','pre':'Pre','strikethrough':'Strike','text_link':'TextUrl','bold':'Bold','italic':'Italic',
                 'underline':'Underline','spoiler':'Spoiler','custom_emoji':'CustomEmoji','blockquote':'Blockquote',
                 'url':'Url','mention':'Mention','hashtag':'Hashtag','bot_command':'BotCommand','email':'Email',
                 'phone_number':'Phone','text_mention':'MentionName'}

def tl_entity(entity):
    from aftergram_tl import TLRPC, TLObject
    if isinstance(entity,TLObject): return entity
    value = dict(entity) if isinstance(entity,dict) else dict(vars(entity))
    kind = value['type'].value if isinstance(value['type'],TLEntityType) else value['type']
    fields = {'offset':value['offset'],'length':value['length']}
    for key in {'url','document_id','user_id'}:
        if value.get(key) is not None: fields[key] = value[key]
    if kind == 'pre': fields['language'] = value.get('language') or ''
    if kind == 'blockquote': fields['collapsed'] = bool(value.get('collapsed',False))
    return getattr(TLRPC,'TL_messageEntity'+_ENTITY_NAMES[kind])(**fields)

def utf16_length(text):
    return len(text.encode('utf-16-le')) // 2

def serialize_entities(entities, text):
    result = []
    limit = utf16_length(text)
    for entity in entities or []:
        from aftergram_tl import TLObject
        if isinstance(entity,TLObject):
            suffix = (entity._model or {}).get('name','').removeprefix('messageEntity')
            kind = next((key for key,name in _ENTITY_NAMES.items() if name == suffix),None)
            value = dict(entity._values);value['type'] = kind
            if kind == 'blockquote': value['collapsed'] = entity.collapsed
        else: value = dict(entity) if isinstance(entity, dict) else dict(vars(entity))
        kind = value.get('type')
        value['type'] = kind.value if isinstance(kind, TLEntityType) else kind
        offset, length = value.get('offset'), value.get('length')
        if value['type'] not in {t.value for t in TLEntityType}:
            raise ValueError('Unsupported text entity')
        if type(offset) is not int or type(length) is not int or offset < 0 or length <= 0 or offset + length > limit:
            raise ValueError('Invalid UTF-16 entity range')
        encoded = text.encode('utf-16-le')
        try:
            encoded[:offset * 2].decode('utf-16-le')
            encoded[:(offset + length) * 2].decode('utf-16-le')
        except UnicodeDecodeError:
            raise ValueError('Entity splits a Unicode character') from None
        result.append(value)
    return result

class _HTML(HTMLParser):
    tags = {'b': 'BOLD', 'strong': 'BOLD', 'i': 'ITALIC', 'em': 'ITALIC', 'u': 'UNDERLINE',
            's': 'STRIKETHROUGH', 'del': 'STRIKETHROUGH', 'strike': 'STRIKETHROUGH',
            'a': 'TEXT_LINK', 'code': 'CODE', 'pre': 'PRE', 'spoiler': 'SPOILER',
            'tg-spoiler': 'SPOILER', 'blockquote': 'BLOCKQUOTE', 'emoji': 'CUSTOM_EMOJI', 'tg-emoji': 'CUSTOM_EMOJI'}
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts, self.stack, self.entities = [], [], []
        self.position = 0
    def handle_data(self, text):
        self.parts.append(text);self.position += utf16_length(text)
    def handle_starttag(self, tag, attrs):
        if tag == 'br': self.handle_data('\n');return
        if tag not in self.tags: return
        attrs = dict(attrs)
        if tag == 'code' and any(t == 'pre' for t, _ in self.stack):
            for t, e in reversed(self.stack):
                if t == 'pre':
                    e.language = attrs.get('class', '').removeprefix('language-') or e.language
                    return
        kind = TLEntityType[self.tags[tag]]
        entity = RawEntity(kind, self.position, 0)
        if kind == TLEntityType.TEXT_LINK:
            entity.url = attrs.get('href', '')
            if not entity.url: return
        if kind == TLEntityType.PRE: entity.language = attrs.get('language')
        if kind == TLEntityType.BLOCKQUOTE: entity.collapsed = any(k in attrs for k in ('expandable', 'collapsed'))
        if kind == TLEntityType.CUSTOM_EMOJI:
            entity.document_id = int(attrs.get('id', attrs.get('emoji-id', '0')))
            if entity.document_id <= 0: raise ValueError('Invalid custom emoji ID')
        self.stack.append((tag, entity))
    def handle_endtag(self, tag):
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                _, entity = self.stack.pop(index)
                entity.length = self.position - entity.offset
                if entity.length: self.entities.append(entity)
                return
    def result(self):
        for _, entity in self.stack:
            entity.length = self.position - entity.offset
            if entity.length: self.entities.append(entity)
        return ''.join(self.parts), sorted(self.entities, key=lambda e: (e.offset, -e.length))

def _markdown(text):
    """Parse delimiters recursively; never interpret markers inside code spans."""
    parts, index = [], 0
    markers = [('**', 'b'), ('__', 'u'), ('~~', 's'), ('||', 'spoiler'), ('*', 'b'), ('_', 'i'), ('~', 's')]
    while index < len(text):
        if text[index] == '\\' and index + 1 < len(text):
            parts.append(escape(text[index + 1]));index += 2;continue
        if text.startswith('```', index):
            end = text.find('```', index + 3)
            if end != -1:
                body = text[index + 3:end];language = ''
                if '\n' in body:
                    first, rest = body.split('\n', 1)
                    if re.fullmatch(r'[\w+-]*', first): language, body = first, rest
                parts.append('<pre language="' + escape(language, quote=True) + '">' + escape(body) + '</pre>')
                index = end + 3;continue
        if text[index] == '`':
            end = text.find('`', index + 1)
            if end != -1:
                parts.append('<code>' + escape(text[index + 1:end]) + '</code>');index = end + 1;continue
        link = re.match(r'(!?)\[([^\]\n]+)\]\(([^)\n]+)\)', text[index:])
        if link:
            image, label, url = link.groups()
            emoji = re.fullmatch(r'tg://emoji\?id=(\d+)', url) if image else None
            if emoji: parts.append('<emoji id="' + emoji[1] + '">' + escape(label) + '</emoji>')
            else: parts.append('<a href="' + escape(url, quote=True) + '">' + _markdown(label) + '</a>')
            index += link.end();continue
        matched = False
        for marker, tag in markers:
            if text.startswith(marker, index):
                end = text.find(marker, index + len(marker))
                if end > index + len(marker):
                    parts.append('<' + tag + '>' + _markdown(text[index + len(marker):end]) + '</' + tag + '>')
                    index = end + len(marker);matched = True;break
        if matched: continue
        if (index == 0 or text[index - 1] == '\n') and text.startswith('> ', index):
            end = text.find('\n', index)
            if end < 0: end = len(text)
            parts.append('<blockquote>' + _markdown(text[index + 2:end]) + '</blockquote>');index = end;continue
        parts.append(escape(text[index]));index += 1
    return ''.join(parts)

def parse_text(text, parse_mode='HTML', is_caption=False):
    if not isinstance(text, str): raise TypeError('Expected text')
    mode = (parse_mode or '').lower()
    if mode not in {'', 'html', 'markdown'}: raise ValueError('Use HTML or Markdown parse_mode')
    if mode:
        parser = _HTML();parser.feed(_markdown(text) if mode == 'markdown' else text);parser.close()
        plain, entities = parser.result()
    else: plain, entities = text, []
    from aftergram_tl import JavaList
    return {'caption' if is_caption else 'message': plain, 'entities': JavaList(tl_entity(entity) for entity in entities)}

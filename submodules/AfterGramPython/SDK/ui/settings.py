"""Declarative settings mapped to native iOS controls."""
class Setting:
    def __init__(self, *args, **kwargs):
        fields = {'Header': ['text'], 'Divider': ['text'], 'Switch': ['key', 'text', 'default'], 'Selector': ['key', 'text', 'default', 'items'], 'Input': ['key', 'text', 'default'], 'Text': ['text'], 'EditText': ['key', 'hint']}.get(type(self).__name__, [])
        if len(args) > len(fields): raise TypeError('Too many setting arguments')
        for key, value in zip(fields, args):
            if key in kwargs: raise TypeError('Duplicate setting argument: ' + key)
            kwargs[key] = value
        self.__dict__.update(kwargs)
        self.kind = type(self).__name__
        self.key = kwargs.get('key')
        self.text = kwargs.get('text', kwargs.get('hint', ''))
        self.subtext = kwargs.get('subtext', '')
        self.default = kwargs.get('default')
        self.on_change = kwargs.get('on_change')
        self.on_click = kwargs.get('on_click')
        self.create_sub_fragment = kwargs.get('create_sub_fragment')
    def as_json(self, plugin, index):
        return {'kind': self.kind, 'key': self.key, 'text': self.text, 'subtext': self.subtext,
                'value': plugin.get_setting(self.key, self.default) if self.key else None,
                'items': getattr(self, 'items', []), 'index': index, 'subpage': callable(self.create_sub_fragment)}
class Header(Setting): pass
class Divider(Setting): pass
class Switch(Setting): pass
class Selector(Setting): pass
class Input(Setting): pass
class EditText(Setting): pass
class Text(Setting): pass
class Custom(Setting):
    def __init__(self, **kwargs): raise NotImplementedError('Android Custom views need manual adaptation')

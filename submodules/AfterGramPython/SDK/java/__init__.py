"""Explicit Java API adapters, without a JVM or arbitrary reflection."""
from aftergram_tl import JavaList

def jarray(element):
    def create(values):
        if isinstance(values, int): return JavaList([None] * values)
        return JavaList(values)
    return create

def jclass(name):
    from aftergram_tl import TLRPC
    import aftergram_java
    import aftergram_android
    import aftergram_ui
    if name == 'org.telegram.tgnet.TLRPC': return TLRPC
    if name.startswith('org.telegram.tgnet.TLRPC$'): return getattr(TLRPC, name.split('$', 1)[1])
    if name in {'java.util.ArrayList','java.util.List'}: return JavaList
    if name.startswith('java.lang.') and name.split('.')[-1] in {'Integer','Long','String','Object','Boolean','Double'}:
        return getattr(aftergram_java, name.split('.')[-1])
    if name in {'org.telegram.messenger.AndroidUtilities','org.telegram.messenger.UserConfig','org.telegram.messenger.MessagesController','org.telegram.messenger.ConnectionsManager','org.telegram.messenger.ApplicationLoader'}:
        return getattr(aftergram_android, name.split('.')[-1])
    if name.startswith('android.widget.') and name.split('.')[-1] in {'TextView','EditText','Button','LinearLayout','FrameLayout'}: return getattr(aftergram_ui, name.split('.')[-1])
    if name in {'android.view.View','android.view.Gravity','android.text.InputType','org.telegram.ui.Components.LayoutHelper'}: return getattr(aftergram_ui, name.split('.')[-1])
    raise NotImplementedError('No iOS implementation for Java class: ' + name)

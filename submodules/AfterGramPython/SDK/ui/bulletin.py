from aftergram_host import emit
class BulletinHelper:
    @staticmethod
    def show_info(text, *args, **kwargs): emit({'type': 'notice', 'text': str(text)})
    show_error = show_info
    show_success = show_info

def parse_markdown(value):
    from extera_utils.text_formatting import parse_text
    parsed = parse_text(str(value or ''), 'markdown')
    return parsed['message'], parsed['entities']

import re


def resolve(value, settings):
    if isinstance(value, list):
        return [resolve(item, settings) for item in value]
    if isinstance(value, dict):
        return {name: resolve(item, settings) for name, item in value.items()}
    if isinstance(value, str):
        return re.sub(r'\$\(([^)]+)\)', lambda match: settings[match[1]], value)
    return value
